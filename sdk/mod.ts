export type Message =
  | {
    readonly type: "call";
    readonly id: string;
    readonly caller: string;
    readonly method: string;
    readonly params: unknown;
  }
  | { readonly type: "ready"; readonly handle: string }
  | { readonly type: "result"; readonly id: string; readonly value: unknown }
  | {
    readonly type: "error";
    readonly id: string;
    readonly error: {
      readonly code: string;
      readonly message: string;
      readonly detail?: string;
      readonly context?: Readonly<Record<string, unknown>>;
    };
  };

export type Call = Extract<Message, { type: "call" }>;
export type Diagnostic = Extract<Message, { type: "error" }>["error"];
export type Dispatch = (call: Call, signal: AbortSignal) => Promise<unknown>;

export class RemoteError extends Error {
  constructor(readonly diagnostic: Diagnostic) {
    super(diagnostic.message);
    this.name = diagnostic.code;
  }
}

export function diagnostic(error: unknown): Diagnostic {
  if (error instanceof RemoteError) return error.diagnostic;
  return {
    code: error instanceof Error ? error.name : "ExecutionFailed",
    message: String(error),
    ...(error instanceof Error && error.stack ? { detail: error.stack } : {}),
  };
}

function message(value: unknown): Message {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid protocol message");
  const raw = value as Record<string, unknown>;
  const fields: Record<string, readonly string[]> = {
    call: ["id", "caller", "method", "params"],
    ready: ["handle"],
    result: ["id", "value"],
    error: ["id", "error"],
  };
  const required = typeof raw.type === "string" && Object.hasOwn(fields, raw.type) && fields[raw.type];
  if (
    !required || required.some((key) => !Object.hasOwn(raw, key)) ||
    Object.keys(raw).some((key) => !["type", ...required].includes(key))
  ) throw new Error("Invalid protocol envelope");
  for (const key of ["id", "caller", "method", "handle"]) {
    const text = raw[key];
    if (required.includes(key) && (typeof text !== "string" || !text || !text.isWellFormed())) {
      throw new Error(`Invalid ${key}`);
    }
  }
  if (raw.type === "error") {
    const error = raw.error as Record<string, unknown> | null;
    if (
      !error || typeof error !== "object" || Array.isArray(error) ||
      typeof error.code !== "string" || !error.code.isWellFormed() ||
      typeof error.message !== "string" || !error.message.isWellFormed() ||
      error.detail !== undefined && (typeof error.detail !== "string" || !error.detail.isWellFormed()) ||
      error.context !== undefined &&
        (!error.context || typeof error.context !== "object" || Array.isArray(error.context)) ||
      Object.keys(error).some((key) => !["code", "message", "detail", "context"].includes(key))
    ) throw new Error("Invalid diagnostic");
  }
  return value as Message;
}

export function encode(value: Message, maximumBytes: number): Uint8Array {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 0x7fffffff) {
    throw new Error("Invalid frame limit");
  }
  const json = JSON.stringify(value);
  message(JSON.parse(json));
  const bytes = new TextEncoder().encode(json + "\n");
  if (bytes.length > maximumBytes) throw new Error("Frame exceeds byte limit");
  return bytes;
}

export async function* decode(
  readable: ReadableStream<Uint8Array>,
  maximumBytes: number,
): AsyncGenerator<Message> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 0x7fffffff) {
    throw new Error("Invalid frame limit");
  }
  const buffer = new ArrayBuffer(0, { maxByteLength: maximumBytes });
  const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  for await (const chunk of readable) {
    for (let offset = 0; offset < chunk.length;) {
      const newline = chunk.indexOf(10, offset);
      const part = chunk.subarray(offset, newline < 0 ? chunk.length : newline);
      const position = buffer.byteLength;
      if (position + part.length >= maximumBytes) throw new Error("Frame exceeds byte limit");
      buffer.resize(position + part.length);
      new Uint8Array(buffer).set(part, position);
      offset = newline < 0 ? chunk.length : newline + 1;
      if (newline < 0) break;
      const value = message(JSON.parse(utf8.decode(buffer)));
      buffer.resize(0);
      yield value;
    }
  }
  if (buffer.byteLength) throw new Error("Partial frame");
}

export class Connection {
  readonly #writer: WritableStreamDefaultWriter<Uint8Array>;
  readonly #pending = new Map<
    string,
    { response: PromiseWithResolvers<unknown>; dispatch: Dispatch; signal: AbortSignal }
  >();
  readonly #incoming = new Set<string>();
  readonly #stop = new AbortController();
  readonly #ready = Promise.withResolvers<void>();
  readonly closed: Promise<void>;
  readonly ready: Promise<void> = this.#ready.promise;
  #sequence = 0;

  constructor(
    readable: ReadableStream<Uint8Array>,
    writable: WritableStream<Uint8Array>,
    readonly peer: string,
    readonly maximumBytes: number,
  ) {
    const writer = writable.getWriter();
    this.#writer = writer;
    void this.ready.catch(() => {});
    this.closed = (async () => {
      let loaded = false;
      try {
        for await (
          const message of decode(
            readable.pipeThrough(new TransformStream(), { signal: this.#stop.signal }),
            maximumBytes,
          )
        ) {
          if (message.type === "ready") {
            if (loaded || message.handle !== peer) throw new Error("Invalid peer readiness");
            loaded = true;
            this.#ready.resolve();
          } else {
            if (!loaded) throw new Error("Missing peer readiness");
            if (message.type === "call") {
              if (message.caller !== peer || this.#incoming.has(message.id)) throw new Error("Invalid incoming call");
              const invocation = this.#pending.get(message.id.split("/", 1)[0]);
              if (!invocation) throw new Error("Unknown invocation");
              this.#incoming.add(message.id);
              void (async () => {
                let response: Message;
                try {
                  invocation.signal.throwIfAborted();
                  response = {
                    type: "result",
                    id: message.id,
                    value: await invocation.dispatch(message, AbortSignal.any([invocation.signal, this.#stop.signal])),
                  };
                } catch (error) {
                  response = { type: "error", id: message.id, error: diagnostic(error) };
                }
                const bytes = encode(response, maximumBytes);
                this.#incoming.delete(message.id);
                await writer.write(bytes);
              })().catch((error) => this.#stop.abort(error));
            } else {
              const invocation = this.#pending.get(message.id);
              if (!invocation || [...this.#incoming].some((id) => id.startsWith(message.id + "/"))) {
                throw new Error("Unexpected response or outstanding imported call");
              }
              this.#pending.delete(message.id);
              if (message.type === "result") invocation.response.resolve(message.value);
              else invocation.response.reject(new RemoteError(message.error));
            }
          }
        }
      } catch (error) {
        this.#stop.abort(error);
      } finally {
        this.#stop.abort(new Error("Connection closed"));
        this.#ready.reject(this.#stop.signal.reason);
        for (const { response } of this.#pending.values()) response.reject(this.#stop.signal.reason);
        this.#pending.clear();
      }
    })();
  }

  async call(
    caller: string,
    method: string,
    params: unknown,
    dispatch: Dispatch,
    signal: AbortSignal,
  ): Promise<unknown> {
    await this.ready;
    signal.throwIfAborted();
    this.#stop.signal.throwIfAborted();
    const id = "h" + ++this.#sequence;
    const response = Promise.withResolvers<unknown>();
    this.#pending.set(id, { response, dispatch, signal });
    const abort = () => response.reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    try {
      try {
        await this.#writer.write(encode({ type: "call", id, caller, method, params }, this.maximumBytes));
      } catch (error) {
        this.#pending.delete(id);
        response.reject(error);
      }
      return await response.promise;
    } finally {
      signal.removeEventListener("abort", abort);
    }
  }

  async close() {
    if (!this.#stop.signal.aborted) await this.#writer.close();
  }
}
