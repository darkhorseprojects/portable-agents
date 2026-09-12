import {
  Crypto,
  Effect,
  Encoding,
  Exit,
  Queue,
  Result,
  Schema,
  Stream,
} from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const maxRecordBytes = 64 * 1024 * 1024;
const encoder = new TextEncoder();
const fail = (code: string) => new AgentError({ code });
const base64 = (value: string) =>
  Result.getOrThrow(Encoding.decodeBase64(value));
const line = (value: unknown) => {
  const bytes = encoder.encode(`${JSON.stringify(value)}\n`);
  if (bytes.length > maxRecordBytes) throw new Error("record too large");
  return bytes;
};

type AgentEffect<A> = Effect.Effect<
  A,
  AgentError,
  ChildProcessSpawner.ChildProcessSpawner
>;
type Call = (input: Uint8Array) => AgentEffect<Uint8Array>;
export type AgentId = Uint8Array;
export type Target = Readonly<{ module: string; path?: readonly string[] }>;
export type Capability = Readonly<{ agentId: AgentId; call: Call }>;
export type Grant = Readonly<{ name: string; capability: Capability }>;

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
    target: Target,
    input: Uint8Array,
    grants?: readonly Grant[],
  ) => AgentEffect<Uint8Array>;
  readonly bind: (target: Target, grants?: readonly Grant[]) => Capability;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = Required<AgentOptions>;
type Message =
  | { tag: "output"; value: Uint8Array }
  | { tag: "failure"; code: string }
  | { tag: "grant"; id: number; name: string; input: Uint8Array };

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
  const config: Config = {
    binary,
    source: options.source,
    agentId,
    luaBytes,
    luaSteps,
  };
  const callAgent = (
    target: Target,
    input: Uint8Array,
    grants: readonly Grant[] = [],
  ) => call(config, target, input, grants);
  return {
    agentId: agentId.slice(),
    call: callAgent,
    bind: (target, grants = []) => {
      const boundTarget = {
        module: target.module,
        path: [...(target.path ?? [])],
      };
      const boundGrants = grants.map(({ name, capability }) => ({
        name,
        capability: {
          agentId: capability.agentId.slice(),
          call: capability.call,
        },
      }));
      return {
        agentId: agentId.slice(),
        call: (input) => callAgent(boundTarget, input, boundGrants),
      };
    },
  } satisfies Agent;
});

const call = Effect.fn("Agent.call")(
  function* (
    config: Config,
    target: Target,
    input: Uint8Array,
    grants: readonly Grant[],
  ) {
    const targets = new Map<string, Call>();
    const wireGrants: Array<{ name: string; agentId: string }> = [];
    for (const grant of grants) {
      const { name, capability } = grant;
      if (targets.has(name) || capability.agentId.length !== 32) {
        return yield* fail("InvalidGrant");
      }
      targets.set(name, capability.call);
      wireGrants.push({
        name,
        agentId: Encoding.encodeBase64(capability.agentId),
      });
    }
    const request = yield* Effect.try({
      try: () =>
        line({
          version: 1,
          agentId: Encoding.encodeBase64(config.agentId),
          luaBytes: config.luaBytes,
          luaSteps: config.luaSteps.toString(),
          grants: wireGrants,
          target: { module: target.module, path: [...(target.path ?? [])] },
          input: Encoding.encodeBase64(input),
        }),
      catch: () => fail("RecordTooLarge"),
    });
    const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
    const handle = yield* spawner.spawn(ChildProcess.make(
      config.binary,
      ["call", config.source],
      { stderr: "inherit" },
    ));
    const outbound = yield* Queue.unbounded<Uint8Array>();
    yield* Stream.fromQueue(outbound).pipe(
      Stream.run(handle.stdin),
      Effect.forkScoped,
    );
    yield* Queue.offer(outbound, request);
    let final: Exclude<Message, { tag: "grant" }> | undefined;
    yield* handle.stdout.pipe(
      Stream.decodeText(),
      Stream.splitLines,
      Stream.runForEach((text) =>
        Effect.gen(function* () {
          const message = yield* Effect.try({
            try: () => decodeMessage(text),
            catch: () => fail("InvalidProtocol"),
          });
          if (final) return yield* fail("InvalidProtocol");
          if (message.tag !== "grant") {
            final = message;
            return;
          }
          const target = targets.get(message.name);
          if (!target) return yield* fail("InvalidProtocol");
          yield* Effect.gen(function* () {
            const result = yield* Effect.exit(target(message.input));
            const reply = yield* Effect.try({
              try: () =>
                line({
                  reply: Exit.isSuccess(result)
                    ? {
                      id: message.id,
                      output: Encoding.encodeBase64(result.value),
                    }
                    : { id: message.id, error: "AgentFailure" },
                }),
              catch: () =>
                line({ reply: { id: message.id, error: "AgentFailure" } }),
            });
            yield* Queue.offer(outbound, reply);
          }).pipe(Effect.forkScoped);
        })
      ),
    );
    if ((yield* handle.exitCode) !== ChildProcessSpawner.ExitCode(0)) {
      return yield* fail("ProcessFailure");
    }
    if (!final) return yield* fail("MissingResult");
    if (final.tag === "failure") {
      return yield* fail(final.code || "AgentFailure");
    }
    return final.value;
  },
  Effect.scoped,
  Effect.mapError((error) =>
    error instanceof AgentError ? error : fail("ProcessFailure")
  ),
);

function decodeMessage(text: string): Message {
  const value = JSON.parse(text);
  if (Object.keys(value).length !== 1) throw new Error("invalid message");
  const { result, grant } = value;
  if (result && Object.keys(result).length !== 1) throw new Error("protocol");
  if (result && typeof result.output === "string") {
    return { tag: "output", value: base64(result.output) };
  }
  if (result && typeof result.error === "string") {
    return { tag: "failure", code: result.error };
  }
  if (
    !grant || Object.keys(grant).length !== 3 ||
    !Number.isSafeInteger(grant.id) || grant.id <= 0 ||
    grant.id > 0xffff_ffff || typeof grant.name !== "string" ||
    typeof grant.input !== "string"
  ) throw new Error("invalid message");
  return {
    tag: "grant",
    id: grant.id,
    name: grant.name,
    input: base64(grant.input),
  };
}
