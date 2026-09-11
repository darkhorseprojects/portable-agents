import { Crypto, Effect, Encoding, Exit, Queue, Result, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const encoder = new TextEncoder();
export type Identity = Uint8Array;

export interface Entry {
  readonly module: string;
  readonly members?: readonly string[];
}

export interface Interface {
  readonly identity: Identity;
  readonly call: (
    input: Uint8Array,
  ) => Effect.Effect<Uint8Array, AgentError, ChildProcessSpawner.ChildProcessSpawner>;
}

export interface Mount {
  readonly name: string;
  readonly interface: Interface;
}

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
  ) => Effect.Effect<Uint8Array, AgentError, ChildProcessSpawner.ChildProcessSpawner>;
  readonly interface: (entry: Entry) => Interface;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = Readonly<{
  binary: string;
  source: string;
  identity: Uint8Array;
  luaBytes: number;
  luaSteps: bigint;
}>;

type Message =
  | { tag: "result"; output?: Uint8Array; error?: string }
  | { tag: "mount"; id: number; name: string; input: Uint8Array };

export const make = Effect.fn("Agent.make")(function* (options: AgentOptions) {
  const crypto = yield* Crypto.Crypto;
  const luaBytes = options.luaBytes ?? 16 * 1024 * 1024;
  const luaSteps = options.luaSteps ?? 2_000_000n;
  if (!(options.binary ?? "agent") || !options.source || !Number.isSafeInteger(luaBytes) || luaBytes < 0 ||
    luaSteps < 0n || luaSteps > 0xffff_ffff_ffff_ffffn) {
    return yield* new AgentError({ code: "InvalidOptions" });
  }
  const identity = options.identity
    ? new Uint8Array(options.identity)
    : yield* crypto.randomBytes(32).pipe(
      Effect.mapError(() => new AgentError({ code: "IdentityGenerationFailed" })),
    );
  if (identity.length !== 32) return yield* new AgentError({ code: "InvalidIdentity" });
  const config: Config = {
    binary: options.binary ?? "agent",
    source: options.source,
    identity,
    luaBytes,
    luaSteps,
  };
  const callAgent = (entry: Entry, input: Uint8Array, mounts: readonly Mount[] = []) =>
    call(config, entry, input, mounts);
  return {
    identity: identity.slice(),
    call: callAgent,
    interface: (entry) => ({ identity: identity.slice(), call: (input) => callAgent(entry, input) }),
  } satisfies Agent;
});

const callUnscoped = Effect.fn("Agent.call")(function* (
  config: Config,
  entry: Entry,
  input: Uint8Array,
  mounts: readonly Mount[],
) {
  const names = new Map<string, Interface>();
  for (const mount of mounts) {
    if (names.has(mount.name) || mount.interface.identity.length !== 32) {
      return yield* new AgentError({ code: "InvalidMount" });
    }
    names.set(mount.name, mount.interface);
  }
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const handle = yield* spawner.spawn(ChildProcess.make(
    config.binary,
    ["call", config.source],
    { stderr: "inherit" },
  )).pipe(Effect.mapError(() => new AgentError({ code: "ProcessFailure" })));
  const outbound = yield* Queue.unbounded<Uint8Array>();
  yield* Stream.fromQueue(outbound).pipe(Stream.run(handle.stdin), Effect.forkScoped);
  yield* Queue.offer(outbound, line({
    version: 1,
    identity: Encoding.encodeBase64(config.identity),
    luaBytes: config.luaBytes,
    luaSteps: config.luaSteps.toString(),
    mounts: mounts.map((mount) => ({
      name: mount.name,
      identity: Encoding.encodeBase64(mount.interface.identity),
    })),
    entry: { module: entry.module, members: entry.members ?? [] },
    input: Encoding.encodeBase64(input),
  }));
  let final: Message | undefined;
  yield* handle.stdout.pipe(
    Stream.decodeText(),
    Stream.splitLines,
    Stream.runForEach((text) => Effect.gen(function* () {
      const message = yield* Effect.try({
        try: () => decodeMessage(text),
        catch: () => new AgentError({ code: "InvalidProtocol" }),
      });
      if (message.tag === "result") {
        if (final) return yield* new AgentError({ code: "InvalidProtocol" });
        final = message;
        return;
      }
      const target = names.get(message.name);
      if (!target) return yield* new AgentError({ code: "InvalidProtocol" });
      yield* Effect.gen(function* () {
        const result = yield* Effect.exit(target.call(message.input));
        yield* Queue.offer(outbound, line({
          reply: Exit.isSuccess(result)
            ? { id: message.id, output: Encoding.encodeBase64(result.value) }
            : { id: message.id, error: "AgentFailure" },
        }));
      }).pipe(Effect.forkScoped);
    })),
    Effect.mapError((error) => error instanceof AgentError
      ? error
      : new AgentError({ code: "ProcessFailure" })),
  );
  const status = yield* handle.exitCode.pipe(
    Effect.mapError(() => new AgentError({ code: "ProcessFailure" })),
  );
  if (status !== ChildProcessSpawner.ExitCode(0)) return yield* new AgentError({ code: "ProcessFailure" });
  if (!final) return yield* new AgentError({ code: "MissingResult" });
  if (final.tag !== "result") return yield* new AgentError({ code: "InvalidProtocol" });
  if (final.error !== undefined) return yield* new AgentError({ code: final.error || "AgentFailure" });
  if (!final.output) return yield* new AgentError({ code: "InvalidProtocol" });
  return final.output;
});

const call = (config: Config, entry: Entry, input: Uint8Array, mounts: readonly Mount[]) =>
  callUnscoped(config, entry, input, mounts).pipe(Effect.scoped);

function line(value: unknown): Uint8Array {
  return encoder.encode(`${JSON.stringify(value)}\n`);
}

function decodeMessage(text: string): Message {
  const value: unknown = JSON.parse(text);
  if (!record(value)) throw new Error("invalid message");
  if (Object.keys(value).length !== 1) throw new Error("invalid message");
  if (record(value.result)) {
    const output = optionalString(value.result.output);
    const error = optionalString(value.result.error);
    if (Object.keys(value.result).length !== 1 || (output === undefined) === (error === undefined)) {
      throw new Error("invalid result");
    }
    return { tag: "result", output: output === undefined ? undefined : base64(output), error };
  }
  if (record(value.mount) && Object.keys(value.mount).length === 3 && Number.isSafeInteger(value.mount.id) &&
    (value.mount.id as number) > 0 && (value.mount.id as number) <= 0xffff_ffff &&
    typeof value.mount.name === "string" && typeof value.mount.input === "string") {
    return { tag: "mount", id: value.mount.id as number, name: value.mount.name, input: base64(value.mount.input) };
  }
  throw new Error("invalid message");
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error("expected string");
  return value;
}

function base64(value: string): Uint8Array {
  const decoded = Encoding.decodeBase64(value);
  if (Result.isFailure(decoded)) throw decoded.failure;
  return decoded.success;
}
