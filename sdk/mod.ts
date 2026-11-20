/** Bounded JSON frames and correlated calls over a pair of byte streams.
 * @module
 */

/** A piece of a published item. A single-piece item has `final: true`. */
export type Chunk = { type: string; data: Uint8Array; final: boolean; id?: string; reply?: string };

/** An error received across the connection. */
export type Diagnostic = Readonly<{
  code: string;
  message: string;
  detail?: string;
  context?: Readonly<Record<string, unknown>>;
}>;

/** A call with a transport ID and a caller asserted by its sender. */
export type Call = Readonly<{ type: "call"; id: string; caller: string; method: string; params: unknown }>;

/** One protocol envelope, before byte encoding or after byte decoding. */
export type Frame =
  | Call
  | Readonly<{ type: "ready"; handle: string }>
  | Readonly<{ type: "result"; id: string; value: unknown }>
  | Readonly<{ type: "error"; id: string; error: Diagnostic }>;

/** Handles a reverse call. For `invoke`, `chunk` parameters have decoded bytes. */
export type Dispatch = (call: Call, signal: AbortSignal) => Promise<unknown>;

/** A remote failure with its original diagnostic intact. */
export class RemoteError extends Error {
  /** The original diagnostic from the peer. */
  readonly diagnostic: Diagnostic;

  /** Wraps a received diagnostic without changing it. */
  constructor(diagnostic: Diagnostic) {
    super(diagnostic.message);
    this.name = diagnostic.code;
    this.diagnostic = diagnostic;
  }
}

/** Preserves remote diagnostics and describes local failures. */
export function diagnostic(error: unknown): Diagnostic {
  if (error instanceof RemoteError) return error.diagnostic;
  return error instanceof Error
    ? { code: error.name, message: error.message, ...(error.stack ? { detail: error.stack } : {}) }
    : { code: "ExecutionFailed", message: String(error) };
}

const fields = {
  ready: ["handle"],
  call: ["id", "caller", "method", "params"],
  result: ["id", "value"],
  error: ["id", "error"],
};

function frame(value: unknown): Frame {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid protocol frame");
  const raw = value as Record<string, unknown>;
  const keys = typeof raw.type === "string" && Object.hasOwn(fields, raw.type) &&
    fields[raw.type as keyof typeof fields];
  if (!keys || Object.keys(raw).length !== keys.length + 1 || keys.some((key) => !Object.hasOwn(raw, key))) {
    throw new Error("Invalid protocol envelope");
  }
  for (const key of keys) {
    if (key === "params" || key === "value" || key === "error") continue;
    const text = raw[key];
    if (typeof text !== "string" || !text || !text.isWellFormed()) throw new Error(`Invalid ${key}`);
  }
  if (raw.type === "error") {
    if (!raw.error || typeof raw.error !== "object" || Array.isArray(raw.error)) throw new Error("Invalid diagnostic");
    const { code, message, detail, context, ...rest } = raw.error as Record<string, unknown>;
    if (
      typeof code !== "string" || !code.isWellFormed() || typeof message !== "string" || !message.isWellFormed() ||
      detail !== undefined && (typeof detail !== "string" || !detail.isWellFormed()) ||
      context !== undefined && (!context || typeof context !== "object" || Array.isArray(context)) ||
      Object.keys(rest).length
    ) throw new Error("Invalid diagnostic");
  }
  return value as Frame;
}

class FrameTooLarge extends Error {}

/** Encodes one frame. The limit includes the newline. */
export function encode(value: Frame, maximumBytes: number): Uint8Array {
  if (!(maximumBytes > 0 && maximumBytes === (maximumBytes | 0))) throw new Error("Invalid frame limit");
  const json = JSON.stringify(value);
  frame(JSON.parse(json));
  const bytes = new TextEncoder().encode(json + "\n");
  if (bytes.length > maximumBytes) throw new FrameTooLarge("Frame exceeds byte limit");
  return bytes;
}

/** Reads complete frames without waiting for EOF. A partial frame is an error. */
export async function* decode(readable: ReadableStream<Uint8Array>, maximumBytes: number): AsyncGenerator<Frame> {
  if (!(maximumBytes > 0 && maximumBytes === (maximumBytes | 0))) throw new Error("Invalid frame limit");
  const buffer = new ArrayBuffer(0, { maxByteLength: maximumBytes });
  const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  for await (const bytes of readable) {
    for (let offset = 0; offset < bytes.length;) {
      const newline = bytes.indexOf(10, offset);
      const part = bytes.subarray(offset, newline < 0 ? bytes.length : newline);
      const position = buffer.byteLength;
      if (position + part.length >= maximumBytes) throw new FrameTooLarge("Frame exceeds byte limit");
      buffer.resize(position + part.length);
      new Uint8Array(buffer).set(part, position);
      if (newline < 0) break;
      offset = newline + 1;
      const value = frame(JSON.parse(utf8.decode(buffer)));
      buffer.resize(0);
      yield value;
    }
  }
  if (buffer.byteLength) throw new Error("Partial frame");
}

/** The calling side of a connection. The owner supplies the streams and expected peer handle. */
export class Connection {
  readonly #writer: WritableStreamDefaultWriter<Uint8Array>;
  readonly #maximumBytes: number;
  readonly #pending = new Map<
    string,
    { response: PromiseWithResolvers<unknown>; dispatch: Dispatch; signal: AbortSignal; incoming: Set<string> }
  >();
  readonly #stop = new AbortController();
  #sequence = 0;

  /** Resolves when the expected peer sends readiness; rejects if the connection ends first. */
  readonly ready: Promise<void>;
  /** Settles after the read loop ends and outstanding calls have been failed. */
  readonly closed: Promise<void>;

  /** Starts reading the supplied streams and checks the peer's readiness. */
  constructor(
    readable: ReadableStream<Uint8Array>,
    writable: WritableStream<Uint8Array>,
    peer: string,
    maximumBytes: number,
  ) {
    const ready = Promise.withResolvers<void>();
    this.ready = ready.promise;
    void this.ready.catch(() => {});
    this.#maximumBytes = maximumBytes;
    const writer = writable.getWriter();
    this.#writer = writer;
    this.closed = (async () => {
      let loaded = false;
      const stream = readable.pipeThrough(new TransformStream(), { signal: this.#stop.signal });
      for await (const msg of decode(stream, maximumBytes)) {
        if (msg.type === "ready") {
          if (loaded || msg.handle !== peer) throw new Error("Invalid peer readiness");
          loaded = true;
          ready.resolve();
          continue;
        }
        if (!loaded) throw new Error("Missing peer readiness");
        if (msg.type !== "call") {
          const pending = this.#pending.get(msg.id);
          if (!pending || pending.incoming.size) throw new Error("Unexpected response or outstanding reverse call");
          this.#pending.delete(msg.id);
          if (msg.type === "result") pending.response.resolve(msg.value);
          else pending.response.reject(new RemoteError(msg.error));
          continue;
        }
        const slash = msg.id.indexOf("/");
        const pending = this.#pending.get(msg.id.slice(0, slash));
        if (slash < 1 || msg.caller !== peer || !pending || pending.incoming.has(msg.id)) {
          throw new Error("Invalid reverse call");
        }
        pending.incoming.add(msg.id);
        void (async () => {
          let response: Frame;
          try {
            const signal = AbortSignal.any([pending.signal, this.#stop.signal]);
            signal.throwIfAborted();
            response = { type: "result", id: msg.id, value: await pending.dispatch(msg, signal) };
          } catch (error) {
            response = { type: "error", id: msg.id, error: diagnostic(error) };
          }
          let bytes: Uint8Array;
          try {
            bytes = encode(response, maximumBytes);
          } catch (error) {
            if (!(error instanceof FrameTooLarge)) throw error;
            bytes = encode({
              type: "error",
              id: msg.id,
              error: {
                code: "TransportLimit",
                message: "Import response exceeds the frame limit; effects may have happened",
              },
            }, maximumBytes);
          }
          pending.incoming.delete(msg.id);
          await writer.write(bytes);
        })().catch((error) => this.#stop.abort(error));
      }
    })().catch((error) => this.#stop.abort(error)).finally(() => {
      this.#stop.abort(new Error("Connection closed"));
      ready.reject(this.#stop.signal.reason);
      for (const { response } of this.#pending.values()) response.reject(this.#stop.signal.reason);
      this.#pending.clear();
    });
  }

  /** Calls an application method with opaque JSON parameters. */
  async call(caller: string, method: string, params: unknown, handle: Dispatch, signal: AbortSignal): Promise<unknown> {
    await this.ready;
    signal.throwIfAborted();
    this.#stop.signal.throwIfAborted();
    const id = "h" + ++this.#sequence;
    const bytes = encode({ type: "call", id, caller, method, params }, this.#maximumBytes);
    const response = Promise.withResolvers<unknown>();
    this.#pending.set(id, { response, dispatch: handle, signal, incoming: new Set() });
    const abort = () => response.reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    try {
      void this.#writer.write(bytes).catch((error) => this.#stop.abort(error));
      return await response.promise;
    } finally {
      signal.removeEventListener("abort", abort);
    }
  }

  /** Invokes an agent with byte input, opaque config, and documented imports. */
  async invoke(
    caller: string,
    input: Uint8Array,
    config: unknown,
    imports: Record<string, string>,
    dispatch: Dispatch,
    signal: AbortSignal,
  ): Promise<unknown> {
    let item: string | undefined;
    let writing = false;
    const offered = Object.hasOwn(imports, "chunk");
    const result = await this.call(caller, "invoke", [input.toBase64(), config, imports], async (call, active) => {
      if (call.method !== "chunk") return await dispatch(call, active);
      if (!offered) throw new Error("Chunk import is not offered");
      if (!call.params || typeof call.params !== "object" || Array.isArray(call.params)) {
        throw new Error("Invalid chunk");
      }
      const { type, data, final, id, reply, ...rest } = call.params as Record<string, unknown>;
      if (
        typeof type !== "string" || !/^[\w!#$%&'*+.^`|~-]+\/[\w!#$%&'*+.^`|~-]+(?:[ \t]*;[^\r\n]+)?$/.test(type) ||
        typeof data !== "string" || typeof final !== "boolean" ||
        id !== undefined && typeof id !== "string" || reply !== undefined && typeof reply !== "string" ||
        Object.keys(rest).length
      ) throw new Error("Invalid chunk");
      const bytes = Uint8Array.fromBase64(data, { lastChunkHandling: "strict" });
      if (bytes.toBase64() !== data) throw new Error("Invalid chunk encoding");
      const identity = JSON.stringify([type, id, reply]);
      if (writing || item !== undefined && item !== identity) throw new Error("Overlapping items");
      item = identity;
      writing = true;
      try {
        const params: Chunk = { type, data: bytes, final, id, reply };
        const ack = await dispatch({ ...call, params }, active);
        if (final) item = undefined;
        return ack;
      } finally {
        writing = false;
      }
    }, signal);
    if (item !== undefined) throw new Error("Partial item");
    return result;
  }

  /** Closes the write side; the process owner controls shutdown deadlines. */
  async close(): Promise<void> {
    if (!this.#stop.signal.aborted) await this.#writer.close();
  }
}
