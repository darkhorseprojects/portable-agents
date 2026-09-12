import { Crypto, Effect, Encoding, Result, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const fail = (code: string) => new AgentError({ code });

type AgentEffect<A> = Effect.Effect<
  A,
  AgentError,
  ChildProcessSpawner.ChildProcessSpawner
>;
export type AgentId = Uint8Array;
export interface Import {
  readonly name: string;
  readonly agent: Agent;
  readonly entry: string;
}

export interface AgentOptions {
  readonly binary?: string;
  readonly source: string;
  readonly agentId?: AgentId;
  readonly luaBytes?: number;
  readonly luaSteps?: bigint;
}

export interface Agent {
  readonly agentId: AgentId;
  readonly call: (
    entry: string,
    input: Uint8Array,
    imports?: readonly Import[],
  ) => AgentEffect<Uint8Array>;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = Required<AgentOptions>;
type WireImport = {
  name: string;
  source: string;
  agentId: string;
  luaBytes: number;
  luaSteps: string;
  entry: string;
};

class AgentImpl implements Agent {
  readonly agentId: AgentId;

  constructor(readonly config: Config) {
    this.agentId = config.agentId.slice();
  }

  readonly call = (
    entry: string,
    input: Uint8Array,
    imports: readonly Import[] = [],
  ) => call(this.config, entry, input, imports);
}

export const make = Effect.fn("Agent.make")(function* (options: AgentOptions) {
  const binary = options.binary ?? "agent";
  const luaBytes = options.luaBytes ?? 16 * 1024 * 1024;
  const luaSteps = options.luaSteps ?? 2_000_000n;
  if (
    !binary || !options.source || !Number.isSafeInteger(luaBytes) ||
    luaBytes < 0 || typeof luaSteps !== "bigint" || luaSteps < 0n ||
    luaSteps > 0xffff_ffff_ffff_ffffn
  ) return yield* fail("InvalidOptions");
  const agentId = options.agentId
    ? new Uint8Array(options.agentId)
    : yield* Crypto.Crypto.pipe(
      Effect.flatMap((crypto) => crypto.randomBytes(32)),
      Effect.mapError(() => fail("AgentIdGenerationFailed")),
    );
  if (agentId.length !== 32) return yield* fail("InvalidAgentId");
  return new AgentImpl({
    binary,
    source: options.source,
    agentId,
    luaBytes,
    luaSteps,
  });
});

const call = Effect.fn("Agent.call")(
  function* (
    config: Config,
    entry: string,
    input: Uint8Array,
    imports: readonly Import[],
  ) {
    const request = yield* Effect.try({
      try: () =>
        new TextEncoder().encode(JSON.stringify({
          version: 2,
          agentId: Encoding.encodeBase64(config.agentId),
          luaBytes: config.luaBytes,
          luaSteps: config.luaSteps.toString(),
          imports: encodeImports(imports),
          entry,
          input: Encoding.encodeBase64(input),
        })),
      catch: () => fail("InvalidImport"),
    });
    const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
    const handle = yield* spawner.spawn(ChildProcess.make(
      config.binary,
      ["call", config.source],
      { stderr: "inherit" },
    ));
    yield* Stream.make(request).pipe(Stream.run(handle.stdin));
    const response = Array.from(
      yield* handle.stdout.pipe(Stream.decodeText(), Stream.runCollect),
    ).join("");
    if ((yield* handle.exitCode) !== ChildProcessSpawner.ExitCode(0)) {
      return yield* fail("ProcessFailure");
    }
    const result = yield* Effect.try({
      try: () => decodeResult(response),
      catch: () => fail("InvalidProtocol"),
    });
    if ("error" in result) return yield* fail(result.error || "AgentFailure");
    return result.output;
  },
  Effect.scoped,
  Effect.mapError((error) =>
    error instanceof AgentError ? error : fail("ProcessFailure")
  ),
);

function encodeImports(imports: readonly Import[]): WireImport[] {
  return imports.map((value) => {
    if (!(value.agent instanceof AgentImpl)) throw new Error("invalid import");
    const config = value.agent.config;
    return {
      name: value.name,
      source: config.source,
      agentId: Encoding.encodeBase64(config.agentId),
      luaBytes: config.luaBytes,
      luaSteps: config.luaSteps.toString(),
      entry: value.entry,
    };
  });
}

function decodeResult(
  text: string,
): { output: Uint8Array } | { error: string } {
  const result = JSON.parse(text)?.result;
  if (typeof result?.output === "string") {
    return {
      output: Result.getOrThrow(Encoding.decodeBase64(result.output)),
    };
  }
  if (typeof result.error === "string") return { error: result.error };
  throw new Error("invalid protocol");
}
