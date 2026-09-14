import { Effect, Encoding, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const fail = (code: string) => new AgentError({ code });

const Response = Schema.fromJsonString(Schema.Struct({
  result: Schema.Union([
    Schema.Struct({ output: Schema.Uint8ArrayFromBase64 }),
    Schema.Struct({ error: Schema.String }),
  ]),
}));
const decodeResponse = Schema.decodeUnknownEffect(Response, {
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
}

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
}

export const make = Effect.fnUntraced(function* (options: AgentOptions) {
  const executable = options.executable ?? "agent";
  if (
    !executable || !options.sourceDir || !options.entryModule ||
    (options.memoryBytes !== undefined &&
      (!Number.isSafeInteger(options.memoryBytes) ||
        options.memoryBytes <= 0)) ||
    (options.instructions !== undefined &&
      (options.instructions <= 0n ||
        options.instructions > 0xffff_ffff_ffff_ffffn))
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
    const request = yield* Effect.try({
      try: () =>
        new TextEncoder().encode(
          JSON.stringify(encode(agent, input, config, imports)),
        ),
      catch: () => fail("InvalidImport"),
    });
    const handle = yield* ChildProcess.make(agent.spec.executable, ["call"], {
      stdin: Stream.make(request),
      stderr: "inherit",
      forceKillAfter: "1 second",
    });
    const response = yield* handle.stdout.pipe(
      Stream.decodeText(),
      Stream.mkString,
    );
    if ((yield* handle.exitCode) !== ChildProcessSpawner.ExitCode(0)) {
      return yield* fail("ProcessFailure");
    }
    const result = yield* decodeResponse(response).pipe(
      Effect.mapError(() => fail("InvalidProtocol")),
    );
    if ("error" in result.result) {
      return yield* fail(result.result.error || "AgentFailure");
    }
    return result.result.output;
  },
  Effect.scoped,
  Effect.mapError((error) =>
    error instanceof AgentError ? error : fail("ProcessFailure")
  ),
);

function encode(
  root: Agent,
  input: Uint8Array,
  config: Uint8Array,
  values: readonly Import[],
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
  const names = new Set<string>();
  const imports = values.map((value) => {
    if (
      !value.name || value.name === "pa" || value.agent === root ||
      names.has(value.name)
    ) {
      throw new Error("invalid import");
    }
    names.add(value.name);
    return {
      name: value.name,
      agent: add(value.agent),
      config: Encoding.encodeBase64(value.config),
    };
  });
  return {
    version: 4,
    agents,
    imports,
    input: Encoding.encodeBase64(input),
    config: Encoding.encodeBase64(config),
  };
}
