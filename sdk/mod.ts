import { Crypto, Effect, Exit, Queue, Schema, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const maxU32 = 0xffff_ffff;
export type Identity = Uint8Array;

export interface Entry {
  readonly module: string;
  readonly members?: readonly string[];
}

export interface Mount {
  readonly name: string;
  readonly call: (input: Uint8Array) => Effect.Effect<Uint8Array, unknown>;
}

export interface AgentOptions {
  readonly binary?: string;
  readonly source: string;
  readonly identity?: Identity;
  readonly mounts?: readonly Mount[];
  readonly luaBytes?: number;
  readonly luaSteps?: bigint;
}

export interface Agent {
  readonly identity: Identity;
  readonly call: (
    entry: Entry,
    input: Uint8Array,
  ) => Effect.Effect<Uint8Array, AgentError, ChildProcessSpawner.ChildProcessSpawner>;
}

export class AgentError extends Schema.TaggedError<AgentError>()("AgentError", {
  code: Schema.String,
}) {}

type Config = Readonly<{
  binary: string;
  source: string;
  identity: Uint8Array;
  mounts: readonly Mount[];
  mountNames: readonly Uint8Array[];
  luaBytes: bigint;
  luaSteps: bigint;
}>;

type Message =
  | { tag: "success"; bytes: Uint8Array }
  | { tag: "failure"; code: string }
  | { tag: "mount"; id: bigint; mount: number; input: Uint8Array };

export const make = Effect.fn("Agent.make")(function* (options: AgentOptions) {
  const crypto = yield* Crypto.Crypto;
  const luaBytes = options.luaBytes ?? 16 * 1024 * 1024;
  const luaSteps = options.luaSteps ?? 2_000_000n;
  if (!(options.binary ?? "agent") || !options.source ||
    !Number.isSafeInteger(luaBytes) || luaBytes < 0 || luaSteps < 0n || luaSteps > 0xffff_ffff_ffff_ffffn) {
    return yield* new AgentError({ code: "InvalidOptions" });
  }
  const identity = options.identity
    ? new Uint8Array(options.identity)
    : yield* crypto.randomBytes(32).pipe(
      Effect.mapError(() => new AgentError({ code: "IdentityGenerationFailed" })),
    );
  if (identity.length !== 32) return yield* new AgentError({ code: "InvalidIdentity" });
  const mounts = Array.from(options.mounts ?? []);
  const names = new Set<string>();
  for (const mount of mounts) {
    if (names.has(mount.name)) return yield* new AgentError({ code: "DuplicateMount" });
    names.add(mount.name);
  }
  const config: Config = {
    binary: options.binary ?? "agent",
    source: options.source,
    identity,
    mounts,
    mountNames: mounts.map((mount) => encoder.encode(mount.name)),
    luaBytes: BigInt(luaBytes),
    luaSteps,
  };
  return {
    identity: identity.slice(),
    call: (entry, input) => call(config, entry, input),
  } satisfies Agent;
});

const callUnscoped = Effect.fn("Agent.call")(function* (config: Config, entry: Entry, input: Uint8Array) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const handle = yield* spawner.spawn(ChildProcess.make(
    config.binary,
    ["call", config.source],
    { stderr: "inherit" },
  )).pipe(Effect.mapError(() => new AgentError({ code: "ProcessFailure" })));
  const outbound = yield* Queue.unbounded<Uint8Array>();
  yield* Stream.fromQueue(outbound).pipe(Stream.run(handle.stdin), Effect.forkScoped);
  const request = yield* Effect.try({
    try: () => encodeRequest(config, entry, input),
    catch: () => new AgentError({ code: "FrameTooLarge" }),
  });
  yield* Queue.offer(outbound, request);
  const state = { buffer: new Uint8Array(), final: undefined as Message | undefined };
  yield* handle.stdout.pipe(
    Stream.runForEach((chunk) => Effect.gen(function* () {
      for (const frame of decodeFrames(state, chunk)) {
        const message = yield* Effect.try({
          try: () => decodeMessage(frame),
          catch: () => new AgentError({ code: "InvalidProtocol" }),
        });
        if (message.tag !== "mount") {
          if (state.final) return yield* new AgentError({ code: "InvalidProtocol" });
          state.final = message;
          continue;
        }
        const mount = config.mounts[message.mount];
        if (!mount) return yield* new AgentError({ code: "InvalidProtocol" });
        yield* Effect.gen(function* () {
          const result = yield* Effect.exit(mount.call(message.input));
          const reply = Exit.isSuccess(result) && result.value.length <= maxU32 - 13
            ? encodeReply(message.id, result.value)
            : encodeReply(message.id);
          yield* Queue.offer(outbound, reply);
        }).pipe(Effect.forkScoped);
      }
    })),
    Effect.mapError((error) => error instanceof AgentError
      ? error
      : new AgentError({ code: "ProcessFailure" })),
  );
  if (state.buffer.length !== 0) return yield* new AgentError({ code: "InvalidProtocol" });
  const status = yield* handle.exitCode.pipe(
    Effect.mapError(() => new AgentError({ code: "ProcessFailure" })),
  );
  if (status !== ChildProcessSpawner.ExitCode(0)) {
    return yield* new AgentError({ code: "ProcessFailure" });
  }
  if (!state.final) return yield* new AgentError({ code: "MissingResult" });
  if (state.final.tag === "failure") {
    return yield* new AgentError({ code: state.final.code || "AgentFailure" });
  }
  if (state.final.tag !== "success") return yield* new AgentError({ code: "InvalidProtocol" });
  return state.final.bytes;
});

const call = (config: Config, entry: Entry, input: Uint8Array) =>
  callUnscoped(config, entry, input).pipe(Effect.scoped);

function encodeRequest(config: Config, entry: Entry, input: Uint8Array): Uint8Array {
  const module = encoder.encode(entry.module);
  const members = (entry.members ?? []).map((member) => encoder.encode(member));
  const values = [...config.mountNames, module, ...members, input];
  if (values.some((value) => value.length > maxU32)) throw new Error("frame too large");
  const size = 67 + 4 * (config.mountNames.length + members.length) +
    values.reduce((total, value) => total + value.length, 0);
  if (size > maxU32) throw new Error("frame too large");
  const writer = new Writer(size);
  writer.u8(80); writer.u8(65); writer.u8(1);
  writer.u64(config.luaBytes); writer.u64(config.luaSteps); writer.raw(config.identity);
  writer.u32(config.mountNames.length);
  for (const name of config.mountNames) writer.bytes(name);
  writer.bytes(module); writer.u32(members.length);
  for (const member of members) writer.bytes(member);
  writer.bytes(input);
  return writer.data;
}

function encodeReply(id: bigint, output?: Uint8Array): Uint8Array {
  const writer = new Writer(output ? 13 + output.length : 9);
  writer.u8(output ? 3 : 4); writer.u64(id);
  if (output) writer.bytes(output);
  return writer.data;
}

function decodeFrames(state: { buffer: Uint8Array }, chunk: Uint8Array): Uint8Array[] {
  const bytes = new Uint8Array(state.buffer.length + chunk.length);
  bytes.set(state.buffer); bytes.set(chunk, state.buffer.length);
  const frames: Uint8Array[] = [];
  let offset = 0;
  while (bytes.length - offset >= 4) {
    const size = new DataView(bytes.buffer, bytes.byteOffset + offset, 4).getUint32(0, true);
    if (bytes.length - offset - 4 < size) break;
    frames.push(bytes.slice(offset + 4, offset + 4 + size));
    offset += 4 + size;
  }
  state.buffer = bytes.slice(offset);
  return frames;
}

class Writer {
  readonly data: Uint8Array;
  private readonly view: DataView;
  private offset = 4;

  constructor(size: number) {
    this.data = new Uint8Array(size + 4);
    this.view = new DataView(this.data.buffer);
    this.view.setUint32(0, size, true);
  }
  u8(value: number): void { this.view.setUint8(this.offset++, value); }
  u32(value: number): void { this.view.setUint32(this.offset, value, true); this.offset += 4; }
  u64(value: bigint): void { this.view.setBigUint64(this.offset, value, true); this.offset += 8; }
  raw(value: Uint8Array): void { this.data.set(value, this.offset); this.offset += value.length; }
  bytes(value: Uint8Array): void { this.u32(value.length); this.raw(value); }
}

class Reader {
  private readonly view: DataView;
  offset = 0;

  constructor(private readonly data: Uint8Array) {
    this.view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  }
  take(size: number): Uint8Array {
    if (this.offset + size > this.data.length) throw new Error("truncated frame");
    const value = this.data.subarray(this.offset, this.offset + size);
    this.offset += size;
    return value;
  }
  u8(): number { return this.take(1)[0]; }
  u32(): number { const value = this.view.getUint32(this.offset, true); this.take(4); return value; }
  u64(): bigint { const value = this.view.getBigUint64(this.offset, true); this.take(8); return value; }
  bytes(): Uint8Array { return this.take(this.u32()); }
}

function decodeMessage(frame: Uint8Array): Message {
  const reader = new Reader(frame);
  const tag = reader.u8();
  let message: Message;
  if (tag === 0) message = { tag: "success", bytes: reader.bytes() };
  else if (tag === 1) message = { tag: "failure", code: decoder.decode(reader.bytes()) };
  else if (tag === 2) {
    message = { tag: "mount", id: reader.u64(), mount: reader.u32(), input: reader.bytes() };
  } else throw new Error("unknown message");
  if (reader.offset !== frame.length) throw new Error("trailing frame data");
  return message;
}
