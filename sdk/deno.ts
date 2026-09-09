import { Agent, AgentError, AgentOptions, Entry, Mount } from "./mod.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const word = 8;
const bytesSize = word * 2;
const resultSize = 24;
const defaultLuaBytes = 16 * 1024 * 1024;
const defaultLuaSteps = 2_000_000n;

const notifyDefinition = {
  parameters: ["pointer", "u64", "usize", "pointer", "usize"],
  result: "void",
} as const;

const symbols = {
  pa_agent_open: {
    parameters: [
      "buffer",
      "usize",
      "buffer",
      "buffer",
      "usize",
      "function",
      "pointer",
      "usize",
      "u64",
      "buffer",
    ],
    result: "pointer",
    nonblocking: true,
  },
  pa_agent_identity: {
    parameters: ["pointer", "buffer"],
    result: "void",
  },
  pa_agent_call: {
    parameters: [
      "pointer",
      "buffer",
      "usize",
      "buffer",
      "usize",
      "buffer",
      "usize",
      "buffer",
    ],
    result: "void",
    nonblocking: true,
  },
  pa_result_free: {
    parameters: ["buffer"],
    result: "void",
  },
  pa_mount_reply: {
    parameters: ["pointer", "u64", "u32", "buffer", "usize"],
    result: "u32",
  },
  pa_agent_close: {
    parameters: ["pointer"],
    result: "u32",
    nonblocking: true,
  },
} as const satisfies Deno.ForeignLibraryInterface;

type Library = Deno.DynamicLibrary<typeof symbols>;

export async function openAgent(
  libraryPath: string | URL,
  options: AgentOptions,
): Promise<Agent> {
  const source = encoder.encode(options.source);
  const luaBytes = options.luaBytes ?? defaultLuaBytes;
  const luaSteps = options.luaSteps ?? defaultLuaSteps;
  if (!Number.isSafeInteger(luaBytes) || luaBytes < 0 || luaSteps < 0n) {
    throw new AgentError("InvalidLimits");
  }
  const identity = options.identity ? new Uint8Array(options.identity) : null;
  if (identity && identity.length !== 32) {
    throw new AgentError("InvalidIdentity");
  }
  const mounts = options.mounts ? Array.from(options.mounts) : [];
  const names = mounts.map((mount) => encoder.encode(mount.name));
  const descriptions = packBytes(names);
  const library = Deno.dlopen(libraryPath, symbols);
  let pointer: Deno.PointerValue = null;
  const callback = Deno.UnsafeCallback.threadSafe(
    notifyDefinition,
    (request, requestId, mountIndex, input, length) => {
      const mount = mounts[Number(mountIndex)];
      const bytes = copyPointer(input, length);
      Promise.resolve().then(() => mount.call(bytes)).then(
        (output) =>
          reply(library, pointer, requestId, 0, new Uint8Array(output)),
        (error) =>
          reply(library, pointer, requestId, 1, encoder.encode(String(error))),
      );
      void request;
    },
  );
  const result = new Uint8Array(resultSize);
  try {
    pointer = await library.symbols.pa_agent_open(
      source,
      BigInt(source.length),
      identity,
      descriptions,
      BigInt(mounts.length),
      callback.pointer,
      null,
      BigInt(luaBytes),
      luaSteps,
      result,
    );
    void names;
    const error = takeResult(library, result);
    if (pointer === null) {
      throw new AgentError(decoder.decode(error) || "AgentOpenFailed");
    }
    const identityOutput = new Uint8Array(32);
    library.symbols.pa_agent_identity(pointer, identityOutput);
    return new DenoAgent(library, callback, pointer, identityOutput);
  } catch (error) {
    callback.close();
    library.close();
    throw error;
  }
}

class DenoAgent implements Agent {
  readonly identity: Uint8Array;
  #closing = false;
  #close: Promise<void> | undefined;
  #calls = new Set<Promise<unknown>>();

  constructor(
    private readonly library: Library,
    private readonly callback: Deno.UnsafeCallback<typeof notifyDefinition>,
    private readonly pointer: Deno.PointerObject,
    identity: Uint8Array,
  ) {
    this.identity = identity;
  }

  call(entry: Entry, input: Uint8Array): Promise<Uint8Array> {
    if (this.#closing) return Promise.reject(new AgentError("AgentClosing"));
    const operation = this.callNative(entry, input);
    this.#calls.add(operation);
    void operation.then(
      () => this.#calls.delete(operation),
      () => this.#calls.delete(operation),
    );
    return operation;
  }

  close(): Promise<void> {
    if (this.#close) return this.#close;
    this.#closing = true;
    return this.#close = this.closeNative();
  }

  private async callNative(
    entry: Entry,
    inputValue: Uint8Array,
  ): Promise<Uint8Array> {
    const module = encoder.encode(entry.module);
    const members = (entry.members ?? []).map((member) =>
      encoder.encode(member)
    );
    const descriptions = packBytes(members);
    const input = new Uint8Array(inputValue);
    const result = new Uint8Array(resultSize);
    await this.library.symbols.pa_agent_call(
      this.pointer,
      module,
      BigInt(module.length),
      descriptions,
      BigInt(members.length),
      input,
      BigInt(input.length),
      result,
    );
    void members;
    return takeResult(this.library, result);
  }

  private async closeNative(): Promise<void> {
    await Promise.allSettled(Array.from(this.#calls));
    const status = await this.library.symbols.pa_agent_close(this.pointer);
    if (status !== 0) {
      throw new AgentError(status === 2 ? "AgentBusy" : "AgentCloseFailed");
    }
    this.callback.close();
    this.library.close();
  }
}

function packBytes(values: readonly Uint8Array[]): Uint8Array {
  const output = new Uint8Array(values.length * bytesSize);
  const view = new DataView(output.buffer);
  for (let index = 0; index < values.length; index++) {
    view.setBigUint64(
      index * bytesSize,
      Deno.UnsafePointer.value(Deno.UnsafePointer.of(values[index])),
      true,
    );
    view.setBigUint64(
      index * bytesSize + word,
      BigInt(values[index].length),
      true,
    );
  }
  return output;
}

function takeResult(library: Library, result: Uint8Array): Uint8Array {
  const view = new DataView(
    result.buffer,
    result.byteOffset,
    result.byteLength,
  );
  const address = view.getBigUint64(0, true);
  const length = view.getBigUint64(word, true);
  const status = view.getUint32(word * 2, true);
  let output: Uint8Array;
  try {
    output = address === 0n
      ? new Uint8Array()
      : copyPointer(Deno.UnsafePointer.create(address), length);
  } finally {
    library.symbols.pa_result_free(result);
  }
  if (status !== 0) {
    throw new AgentError(decoder.decode(output) || "NativeFailure");
  }
  return output;
}

function copyPointer(pointer: Deno.PointerValue, length: bigint): Uint8Array {
  if (length === 0n) return new Uint8Array();
  if (pointer === null || length > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new AgentError("InvalidNativeResult");
  }
  return new Uint8Array(
    new Deno.UnsafePointerView(pointer).getArrayBuffer(Number(length)),
  ).slice();
}

function reply(
  library: Library,
  agent: Deno.PointerValue,
  requestId: bigint,
  status: number,
  output: Uint8Array,
): void {
  if (agent === null) return;
  library.symbols.pa_mount_reply(
    agent,
    requestId,
    status,
    output,
    BigInt(output.length),
  );
}
