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

const encoder = new TextEncoder();
const fail = (code: string) => new AgentError({ code });
const line = (value: unknown) => encoder.encode(`${JSON.stringify(value)}\n`);
const base64 = (value: string) =>
  Result.getOrThrow(Encoding.decodeBase64(value));
export type Identity = Uint8Array;
type AgentEffect<A> = Effect.Effect<
  A,
  AgentError,
  ChildProcessSpawner.ChildProcessSpawner
>;
type Call = (input: Uint8Array) => AgentEffect<Uint8Array>;

export type Entry = Readonly<{ module: string; members?: readonly string[] }>;
export type Interface = Readonly<{ identity: Identity; call: Call }>;
export type Mount = Readonly<{ name: string; interface: Interface }>;

export interface AgentOptions {
  readonly binary?: string;
  readonly source: string;
  readonly identity?: Identity;
  readonly luaBytes?: number;
  readonly luaSteps?: bigint;
}

export interface Agent {
  readonly identity: Identity;
  readonly call: (
    entry: Entry,
    input: Uint8Array,
    mounts?: readonly Mount[],
  ) => AgentEffect<Uint8Array>;
  readonly interface: (entry: Entry) => Interface;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = Required<AgentOptions>;
type Message =
  | { tag: "output"; value: Uint8Array }
  | { tag: "failure"; code: string }
  | { tag: "mount"; id: number; name: string; input: Uint8Array };

export const make = Effect.fn("Agent.make")(function* (options: AgentOptions) {
  const binary = options.binary ?? "agent";
  const luaBytes = options.luaBytes ?? 16 * 1024 * 1024;
  const luaSteps = options.luaSteps ?? 2_000_000n;
  if (
    !binary || !options.source || !Number.isSafeInteger(luaBytes) ||
    luaBytes < 0 || typeof luaSteps !== "bigint" || luaSteps < 0n ||
    luaSteps > 0xffff_ffff_ffff_ffffn
  ) return yield* fail("InvalidOptions");
  const identity = options.identity
    ? new Uint8Array(options.identity)
    : yield* Crypto.Crypto.pipe(
      Effect.flatMap((crypto) => crypto.randomBytes(32)),
      Effect.mapError(() => fail("IdentityGenerationFailed")),
    );
  if (identity.length !== 32) return yield* fail("InvalidIdentity");
  const config: Config = {
    binary,
    source: options.source,
    identity,
    luaBytes,
    luaSteps,
  };
  const callAgent = (
    entry: Entry,
    input: Uint8Array,
    mounts: readonly Mount[] = [],
  ) => call(config, entry, input, mounts);
  return {
    identity: identity.slice(),
    call: callAgent,
    interface: (entry) => ({
      identity: identity.slice(),
      call: (input) => callAgent(entry, input),
    }),
  } satisfies Agent;
});

const callUnscoped = Effect.fn("Agent.call")(function* (
  config: Config,
  entry: Entry,
  input: Uint8Array,
  mounts: readonly Mount[],
) {
  const targets = new Map<string, Call>();
  const wireMounts: Array<{ name: string; identity: string }> = [];
  for (const mount of mounts) {
    const { name, interface: target } = mount;
    if (targets.has(name) || target.identity.length !== 32) {
      return yield* fail("InvalidMount");
    }
    targets.set(name, target.call);
    wireMounts.push({ name, identity: Encoding.encodeBase64(target.identity) });
  }
  const request = line({
    version: 1,
    identity: Encoding.encodeBase64(config.identity),
    luaBytes: config.luaBytes,
    luaSteps: config.luaSteps.toString(),
    mounts: wireMounts,
    entry: { module: entry.module, members: [...(entry.members ?? [])] },
    input: Encoding.encodeBase64(input),
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
  let final: Exclude<Message, { tag: "mount" }> | undefined;
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
        if (message.tag !== "mount") {
          final = message;
          return;
        }
        const target = targets.get(message.name);
        if (!target) return yield* fail("InvalidProtocol");
        yield* Effect.gen(function* () {
          const result = yield* Effect.exit(target(message.input));
          const reply = Exit.isSuccess(result)
            ? { id: message.id, output: Encoding.encodeBase64(result.value) }
            : { id: message.id, error: "AgentFailure" };
          yield* Queue.offer(outbound, line({ reply }));
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
});

const call = (...args: Parameters<typeof callUnscoped>) =>
  callUnscoped(...args).pipe(
    Effect.scoped,
    Effect.mapError((error) =>
      error instanceof AgentError ? error : fail("ProcessFailure")
    ),
  );

function decodeMessage(text: string): Message {
  const value = JSON.parse(text);
  if (Object.keys(value).length !== 1) throw new Error("invalid message");
  const { result, mount } = value;
  if (result && Object.keys(result).length !== 1) throw new Error("protocol");
  if (result && typeof result.output === "string") {
    return { tag: "output", value: base64(result.output) };
  }
  if (result && typeof result.error === "string") {
    return { tag: "failure", code: result.error };
  }
  if (
    !mount || Object.keys(mount).length !== 3 ||
    !Number.isSafeInteger(mount.id) || mount.id <= 0 ||
    mount.id > 0xffff_ffff || typeof mount.name !== "string" ||
    typeof mount.input !== "string"
  ) throw new Error("invalid message");
  return {
    tag: "mount",
    id: mount.id,
    name: mount.name,
    input: base64(mount.input),
  };
}
