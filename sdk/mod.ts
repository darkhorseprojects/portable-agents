import { Effect, Encoding, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const fail = (code: string) => new AgentError({ code });

const Frame = Schema.fromJsonString(Schema.Union([
  Schema.Struct({ emit: Schema.Uint8ArrayFromBase64 }),
  Schema.Struct({
    result: Schema.Union([
      Schema.Struct({ output: Schema.Uint8ArrayFromBase64 }),
      Schema.Struct({ error: Schema.String }),
    ]),
  }),
]));
const decodeFrame = Schema.decodeUnknownEffect(Frame, {
  onExcessProperty: "error",
});

export interface Import {
  readonly name: string;
  readonly agent: Agent;
  readonly config: Uint8Array;
}

export interface AgentOptions {
  readonly executable?: string;
  readonly sourceDir: string;
  readonly entryModule: string;
  readonly memoryBytes?: number;
  readonly instructions?: bigint;
  readonly cwd?: string;
  readonly environment?: Readonly<Record<string, string>>;
}

export type AgentEvent =
  | { readonly type: "emit"; readonly output: Uint8Array }
  | { readonly type: "result"; readonly output: Uint8Array };

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

export class Agent {
  constructor(
    readonly spec: AgentOptions & { readonly executable: string },
  ) {}

  call(
    input: Uint8Array,
    config: Uint8Array,
    imports: readonly Import[] = [],
  ) {
    return call(this, input, config, imports);
  }

  stream(
    input: Uint8Array,
    config: Uint8Array,
    imports: readonly Import[] = [],
  ) {
    return events(this, input, config, imports, true);
  }
}

export const make = Effect.fnUntraced(function* (options: AgentOptions) {
  const executable = options.executable ?? "agent";
  if (
    !executable ||
    (options.memoryBytes !== undefined &&
      (!Number.isSafeInteger(options.memoryBytes) || options.memoryBytes <= 0))
  ) return yield* fail("InvalidOptions");
  return new Agent({ ...options, executable });
});

const call = Effect.fn("Agent.call")(
  function* (
    agent: Agent,
    input: Uint8Array,
    config: Uint8Array,
    imports: readonly Import[],
  ) {
    const result = yield* events(agent, input, config, imports, false).pipe(
      Stream.runFold(
        () => undefined as Uint8Array | undefined,
        (_, event: AgentEvent) =>
          event.type === "result" ? event.output : undefined,
      ),
    );
    if (result === undefined) return yield* fail("InvalidProtocol");
    return result;
  },
  Effect.mapError((error) =>
    error instanceof AgentError ? error : fail("ProcessFailure")
  ),
);

function events(
  agent: Agent,
  input: Uint8Array,
  config: Uint8Array,
  imports: readonly Import[],
  emits: boolean,
) {
  return Stream.unwrap(Effect.gen(function* () {
    const request = yield* Effect.try({
      try: () =>
        new TextEncoder().encode(
          JSON.stringify(encode(agent, input, config, imports, emits)),
        ),
      catch: () => fail("InvalidImport"),
    });
    const handle = yield* ChildProcess.make(agent.spec.executable, ["call"], {
      cwd: agent.spec.cwd,
      env: agent.spec.environment ? { ...agent.spec.environment } : undefined,
      stdin: Stream.make(request),
      stderr: "inherit",
      forceKillAfter: "1 second",
    });
    let terminal = false;
    const frames = handle.stdout.pipe(
      Stream.decodeText(),
      Stream.splitLines,
      Stream.filter((line) => line.length > 0),
      Stream.mapEffect((line) =>
        Effect.gen(function* () {
          if (terminal) return yield* fail("InvalidProtocol");
          const frame = yield* decodeFrame(line).pipe(
            Effect.mapError(() => fail("InvalidProtocol")),
          );
          if ("emit" in frame) {
            return { type: "emit", output: frame.emit } as const;
          }
          terminal = true;
          if ("error" in frame.result) {
            return yield* fail(frame.result.error || "AgentFailure");
          }
          return { type: "result", output: frame.result.output } as const;
        })
      ),
    );
    const completed = Stream.fromEffect(Effect.gen(function* () {
      if ((yield* handle.exitCode) !== ChildProcessSpawner.ExitCode(0)) {
        return yield* fail("ProcessFailure");
      }
      if (!terminal) return yield* fail("InvalidProtocol");
    })).pipe(Stream.drain);
    return frames.pipe(Stream.concat(completed));
  })).pipe(
    Stream.mapError((error) =>
      error instanceof AgentError ? error : fail("ProcessFailure")
    ),
  );
}

function encode(
  root: Agent,
  input: Uint8Array,
  config: Uint8Array,
  values: readonly Import[],
  emits: boolean,
) {
  const agents: Array<{
    sourceDir: string;
    entryModule: string;
    limits: { memoryBytes?: number; instructions?: string };
  }> = [];
  const indices = new Map<Agent, number>();
  const add = (agent: Agent) => {
    const existing = indices.get(agent);
    if (existing !== undefined) return existing;
    const index = agents.length;
    const spec = agent.spec;
    indices.set(agent, index);
    agents.push({
      sourceDir: spec.sourceDir,
      entryModule: spec.entryModule,
      limits: {
        memoryBytes: spec.memoryBytes,
        instructions: spec.instructions?.toString(),
      },
    });
    return index;
  };
  add(root);
  const imports = values.map((value) => ({
    name: value.name,
    agent: add(value.agent),
    config: Encoding.encodeBase64(value.config),
  }));
  return {
    version: 1,
    emits,
    agents,
    imports,
    input: Encoding.encodeBase64(input),
    config: Encoding.encodeBase64(config),
  };
}
