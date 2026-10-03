/**
 * Effect-based calls and streaming events for Portable Agents protocol 2.
 * Calls start an `agent call` process and require a ChildProcessSpawner service.
 * Input, config, and output are opaque bytes; packages define their formats.
 *
 * @example
 * ```ts
 * import { Effect } from "effect";
 * import { make } from "@darkhorseprojects/portable-agents";
 *
 * const encoder = new TextEncoder();
 * const invocation = Effect.gen(function* () {
 *   const agent = yield* make({ sourceDir: "./package", entryModule: "assistant" });
 *   return yield* agent.call(encoder.encode("Hello"), encoder.encode("{}"));
 * });
 * ```
 *
 * @module
 */
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

/** A caller-granted module available through Lua `require(name)`. */
export interface Import {
  /** Module name; must be unique within the invocation and cannot be `pa`. */
  readonly name: string;
  /** Imported agent; cannot be the invocation's root agent. */
  readonly agent: Agent;
  /** Private config passed to the imported agent, not exposed as a Lua field. */
  readonly config: Uint8Array;
}

/** Package location, process settings, and Lua resource ceilings for an agent. */
export interface AgentOptions {
  /** Runtime executable or path; defaults to `agent` on PATH. */
  readonly executable?: string;
  /** Package source directory containing the entry module and dependencies. */
  readonly sourceDir: string;
  /** Lua module name of the callable package entry. */
  readonly entryModule: string;
  /** Positive Lua-state allocation ceiling in bytes; omitted uses the runtime default. */
  readonly memoryBytes?: number;
  /** Positive Lua instruction ceiling, up to an unsigned 64-bit integer. */
  readonly instructions?: bigint;
  /** Working directory for the child process. */
  readonly cwd?: string;
  /** Environment entries supplied to the child-process spawner. */
  readonly environment?: Readonly<Record<string, string>>;
}

/** Per-invocation imports, named-member selection, and profiling. */
export interface CallOptions {
  /** Explicit module grants; omitted grants no imported agents. */
  readonly imports?: readonly Import[];
  /** Direct entry member to invoke; omitted invokes the root callable entry. */
  readonly member?: string;
  /** Include child-relative profiling timestamps; defaults to false. */
  readonly profile?: boolean;
}

/** Events exposed by {@link Agent.stream}; terminal failures fail the stream. */
export type AgentEvent =
  | {
    /** A complete opaque emission. */
    readonly type: "emit";
    /** Emitted bytes. */
    readonly output: Uint8Array;
  }
  | {
    /** An incremental opaque output fragment. */
    readonly type: "append";
    /** Fragment bytes; text may span UTF-8 boundaries between events. */
    readonly output: Uint8Array;
  }
  | {
    /** A diagnostic stage marker. */
    readonly type: "log";
    /** Runtime or package stage name. */
    readonly stage: string;
    /** Microseconds since child protocol processing began; present when profiling. */
    readonly atUs?: number;
  }
  | {
    /** The successful terminal result. */
    readonly type: "result";
    /** Result bytes returned by the package. */
    readonly output: Uint8Array;
  };

/** Structured runtime, protocol, process, or SDK validation failure. */
export interface AgentError extends Cause.YieldableError {
  /** Effect error discriminator. */
  readonly _tag: "AgentError";
  /** Machine-readable failure code. */
  readonly code: string;
  /** Human-readable failure message. */
  readonly message: string;
  /** Optional bounded diagnostic detail; may contain sensitive agent data. */
  readonly detail?: string;
}

/** Construct a structured, yieldable {@link AgentError}. */
export const AgentError: new (
  fields: Pick<AgentError, "code" | "message" | "detail">,
) => AgentError = Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
  message: Schema.String,
  detail: Schema.optional(Schema.String),
});

/** A configured package handle; each invocation starts a separate runtime process. */
export class Agent {
  /** Construct directly from resolved settings; {@link make} also validates them. */
  constructor(
    /** Resolved package and process settings. */
    readonly spec: AgentOptions & { readonly executable: string },
  ) {}

  /**
   * Invoke the package and return its terminal bytes without public emissions.
   *
   * @param input Package-defined request bytes.
   * @param config Private package-defined config bytes.
   * @param options Imports, optional entry member, and profiling settings.
   * @returns An Effect requiring ChildProcessSpawner and failing with AgentError.
   */
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

  /**
   * Invoke the package with emissions enabled and expose protocol events in order.
   *
   * @param input Package-defined request bytes.
   * @param config Private package-defined config bytes.
   * @param options Imports, optional entry member, and profiling settings.
   * @returns A Stream requiring ChildProcessSpawner and failing with AgentError.
   */
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

/**
 * Validate settings and create an {@link Agent} without starting a process.
 * Package loading and entry validation happen when the agent is invoked.
 *
 * @param options Package location, optional ceilings, and process settings.
 * @returns An Effect yielding the handle or an InvalidOptions AgentError.
 */
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
