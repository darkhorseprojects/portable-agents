import { Crypto, Effect, Encoding, Result, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const fail = (code: string) => new AgentError({ code });

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
  ) => Effect.Effect<
    Uint8Array,
    AgentError,
    ChildProcessSpawner.ChildProcessSpawner
  >;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = {
  readonly binary: string;
  readonly source: string;
  readonly agentId: AgentId;
  readonly luaBytes?: number;
  readonly luaSteps?: bigint;
};
type WireAgent = {
  source: string;
  agentId: string;
  limits: { bytes?: number; steps?: string };
};
type WireImport = { name: string; agent: number; entry: string };

class AgentImpl implements Agent {
  readonly agentId: AgentId;
  readonly #config: Config;

  constructor(config: Config) {
    this.#config = config;
    this.agentId = config.agentId.slice();
  }

  static config(agent: Agent): Config {
    if (!(agent instanceof AgentImpl)) throw new Error("invalid import");
    return agent.#config;
  }

  readonly call = (
    entry: string,
    input: Uint8Array,
    imports: readonly Import[] = [],
  ) => call(this, entry, input, imports);
}

export const make = Effect.fn("Agent.make")(function* (options: AgentOptions) {
  const binary = options.binary ?? "agent";
  if (
    !binary || !options.source ||
    (options.luaBytes !== undefined &&
      (!Number.isSafeInteger(options.luaBytes) || options.luaBytes < 0)) ||
    (options.luaSteps !== undefined &&
      (typeof options.luaSteps !== "bigint" || options.luaSteps < 0n ||
        options.luaSteps > 0xffff_ffff_ffff_ffffn))
  ) return yield* fail("InvalidOptions");
  const agentId = options.agentId
    ? new Uint8Array(options.agentId)
    : yield* Crypto.Crypto.pipe(
      Effect.flatMap((crypto) => crypto.randomBytes(32)),
      Effect.mapError(() => fail("AgentIdGenerationFailed")),
    );
  if (agentId.length !== 32) return yield* fail("InvalidAgentId");
  const agent: Agent = new AgentImpl({
    binary,
    source: options.source,
    agentId,
    luaBytes: options.luaBytes,
    luaSteps: options.luaSteps,
  });
  return agent;
});

const call = Effect.fn("Agent.call")(
  function* (
    agent: AgentImpl,
    entry: string,
    input: Uint8Array,
    imports: readonly Import[],
  ) {
    const config = AgentImpl.config(agent);
    const request = yield* Effect.try({
      try: () => {
        const encoded = encodeAgents(agent, imports);
        return new TextEncoder().encode(JSON.stringify({
          version: 3,
          agents: encoded.agents,
          imports: encoded.imports,
          entry,
          input: Encoding.encodeBase64(input),
        }));
      },
      catch: () => fail("InvalidImport"),
    });
    const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
    const handle = yield* spawner.spawn(ChildProcess.make(
      config.binary,
      ["call"],
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

function encodeAgents(
  root: AgentImpl,
  values: readonly Import[],
): { agents: WireAgent[]; imports: WireImport[] } {
  const agents: WireAgent[] = [];
  const indices = new Map<Agent, number>();
  const add = (agent: Agent) => {
    const existing = indices.get(agent);
    if (existing !== undefined) return existing;
    const config = AgentImpl.config(agent);
    const index = agents.length;
    indices.set(agent, index);
    agents.push({
      source: config.source,
      agentId: Encoding.encodeBase64(config.agentId),
      limits: {
        bytes: config.luaBytes,
        steps: config.luaSteps?.toString(),
      },
    });
    return index;
  };
  add(root);
  const imports = values.map((value) => ({
    name: value.name,
    agent: add(value.agent),
    entry: value.entry,
  }));
  return { agents, imports };
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
