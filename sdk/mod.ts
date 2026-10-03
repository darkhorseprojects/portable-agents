import { type Cause, Effect, Encoding, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const fail = (code: string, message = code) =>
  new AgentError({ code, message });

const Frame = Schema.fromJsonString(Schema.Union([
  Schema.Struct({ emit: Schema.Uint8ArrayFromBase64 }),
  Schema.Struct({ append: Schema.Uint8ArrayFromBase64 }),
  Schema.Struct({ log: Schema.String, atUs: Schema.optional(Schema.Number) }),
  Schema.Struct({
    result: Schema.Union([
      Schema.Struct({ output: Schema.Uint8ArrayFromBase64 }),
      Schema.Struct({
        error: Schema.Struct({
          code: Schema.String,
          message: Schema.String,
          detail: Schema.NullOr(Schema.String),
        }),
      }),
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

export interface CallOptions {
  readonly imports?: readonly Import[];
  readonly member?: string;
  readonly profile?: boolean;
}

export type AgentEvent =
  | { readonly type: "emit"; readonly output: Uint8Array }
  | { readonly type: "append"; readonly output: Uint8Array }
  | { readonly type: "log"; readonly stage: string; readonly atUs?: number }
  | { readonly type: "result"; readonly output: Uint8Array };

export interface AgentError extends Cause.YieldableError {
  readonly _tag: "AgentError";
  readonly code: string;
  readonly message: string;
  readonly detail?: string;
}

export const AgentError: new (
  fields: Pick<AgentError, "code" | "message" | "detail">,
) => AgentError = Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
  message: Schema.String,
  detail: Schema.optional(Schema.String),
});

export class Agent {
  constructor(
    readonly spec: AgentOptions & { readonly executable: string },
  ) {}

  call(
    input: Uint8Array,
    config: Uint8Array,
    options: CallOptions = {},
  ): Effect.Effect<
    Uint8Array,
    AgentError,
    ChildProcessSpawner.ChildProcessSpawner
  > {
    return Effect.gen({ self: this }, function* () {
      const result = yield* events(this, input, config, options, false).pipe(
        Stream.runFold(
          () => undefined as Uint8Array | undefined,
          (previous, event: AgentEvent) =>
            event.type === "result" ? event.output : previous,
        ),
      );
      if (result === undefined) return yield* fail("InvalidProtocol");
      return result;
    }).pipe(Effect.withSpan("Agent.call"));
  }

  stream(
    input: Uint8Array,
    config: Uint8Array,
    options: CallOptions = {},
  ): Stream.Stream<
    AgentEvent,
    AgentError,
    ChildProcessSpawner.ChildProcessSpawner
  > {
    return events(this, input, config, options, true);
  }
}

export const make: (options: AgentOptions) => Effect.Effect<Agent, AgentError> =
  Effect.fnUntraced(function* (options: AgentOptions) {
    const executable = options.executable ?? "agent";
    if (
      !executable || executable.includes("\0") ||
      !options.sourceDir || options.sourceDir.includes("\0") ||
      !options.entryModule || options.entryModule.includes("\0") ||
      (options.instructions !== undefined &&
        (options.instructions <= 0n ||
          options.instructions > 0xffffffffffffffffn)) ||
      (options.memoryBytes !== undefined &&
        (!Number.isSafeInteger(options.memoryBytes) ||
          options.memoryBytes <= 0))
    ) return yield* fail("InvalidOptions");
    return new Agent({ ...options, executable });
  });

function events(
  agent: Agent,
  input: Uint8Array,
  config: Uint8Array,
  options: CallOptions,
  emits: boolean,
) {
  return Stream.unwrap(Effect.gen(function* () {
    const request = yield* Effect.try({
      try: () =>
        new TextEncoder().encode(
          JSON.stringify(encode(agent, input, config, options, emits)),
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
          if ("append" in frame) {
            return { type: "append", output: frame.append } as const;
          }
          if ("log" in frame) {
            return { type: "log", stage: frame.log, atUs: frame.atUs } as const;
          }
          terminal = true;
          if ("error" in frame.result) {
            return yield* new AgentError({
              code: frame.result.error.code,
              message: frame.result.error.message,
              detail: frame.result.error.detail ?? undefined,
            });
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
      error instanceof AgentError
        ? error
        : fail("ProcessFailure", String(error))
    ),
  );
}

function encode(
  root: Agent,
  input: Uint8Array,
  config: Uint8Array,
  options: CallOptions,
  emits: boolean,
) {
  const indices = new Map<Agent, number>([[root, 0]]);
  for (const { agent } of options.imports ?? []) {
    if (!indices.has(agent)) indices.set(agent, indices.size);
  }
  const imports = (options.imports ?? []).map((value) => ({
    name: value.name,
    agent: indices.get(value.agent)!,
    config: Encoding.encodeBase64(value.config),
  }));
  return {
    version: 2,
    emits,
    profile: options.profile ?? false,
    member: options.member,
    agents: Array.from(indices.keys(), ({ spec }) => ({
      sourceDir: spec.sourceDir,
      entryModule: spec.entryModule,
      limits: {
        memoryBytes: spec.memoryBytes,
        instructions: spec.instructions?.toString(),
      },
    })),
    imports,
    input: Encoding.encodeBase64(input),
    config: Encoding.encodeBase64(config),
  };
}
