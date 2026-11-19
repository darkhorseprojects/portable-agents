import { stripVTControlCharacters } from "node:util";
import { z } from "zod";

type Setting = { type: "string" | "integer" | "boolean"; description: string; minimum?: number; maximum?: number };
export type Discovery = {
  methods: string[];
  schema: Record<string, Setting>;
  commands: { name: string; description: string; options?: (Setting & { name: string })[] }[];
  intake?: { max_records: number; image_bytes: number };
};
export type Output = {
  type: "reasoning" | "response" | "tool-call" | "tool-result" | "diagnostic" | "metadata" | "activity";
  text: string;
  id?: string;
  reply?: string | null;
  language?: string;
  footer?: string;
  active?: boolean;
};

const Field = z.strictObject({
  type: z.enum(["string", "integer", "boolean"]),
  description: z.string().min(1),
  minimum: z.number().optional(),
  maximum: z.number().optional(),
});
export const Discovery: z.ZodType<Discovery> = z.strictObject({
  methods: z.array(z.string()),
  schema: z.record(z.string(), Field),
  commands: z.array(
    z.strictObject({
      name: z.string(),
      description: z.string(),
      options: z.array(Field.extend({ name: z.string() })).optional(),
    }),
  ),
  intake: z.strictObject({ max_records: z.number().int().positive(), image_bytes: z.number().int().nonnegative() })
    .optional(),
});
export const Prepared: z.ZodType<
  { config: unknown; input: unknown; options: Record<string, unknown>; history: boolean }
> = z.strictObject({
  config: z.json(),
  input: z.json(),
  options: z.record(z.string(), z.json()),
  history: z.boolean(),
});
export const Position: z.ZodType<{ config: unknown; through: string | null }> = z.strictObject({
  config: z.json(),
  through: z.string().nullable(),
});
export const Output: z.ZodType<Output> = z.object({
  type: z.enum(["reasoning", "response", "tool-call", "tool-result", "diagnostic", "metadata", "activity"]),
  text: z.string().refine((text) => text.isWellFormed()).default(""),
  id: z.string().optional(),
  reply: z.string().nullable().optional(),
  language: z.string().regex(/^[a-z0-9_+-]*$/i).optional(),
  footer: z.string().optional(),
  active: z.boolean().optional(),
});

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

class FrameTooLarge extends Error {}

export function encode(value: Message, maximumBytes: number): Uint8Array {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 0x7fffffff) {
    throw new Error("Invalid frame limit");
  }
  const json = JSON.stringify(value);
  message(JSON.parse(json));
  const bytes = new TextEncoder().encode(json + "\n");
  if (bytes.length > maximumBytes) throw new FrameTooLarge("Frame exceeds byte limit");
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
    { response: PromiseWithResolvers<unknown>; dispatch: Dispatch; signal: AbortSignal; incoming: Set<string> }
  >();
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
              if (message.caller !== peer) throw new Error("Invalid incoming call");
              const invocation = this.#pending.get(message.id.split("/", 1)[0]);
              if (!invocation) throw new Error("Unknown invocation");
              if (invocation.incoming.has(message.id)) throw new Error("Duplicate incoming call");
              invocation.incoming.add(message.id);
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
                let bytes: Uint8Array;
                try {
                  bytes = encode(response, maximumBytes);
                } catch (error) {
                  if (!(error instanceof FrameTooLarge)) throw error;
                  bytes = encode({
                    type: "error",
                    id: message.id,
                    error: {
                      code: "TransportLimit",
                      message: "Import response exceeds the frame limit; effects may have happened",
                    },
                  }, maximumBytes);
                }
                invocation.incoming.delete(message.id);
                await writer.write(bytes);
              })().catch((error) => this.#stop.abort(error));
            } else {
              const invocation = this.#pending.get(message.id);
              if (!invocation || invocation.incoming.size) {
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
    this.#pending.set(id, { response, dispatch, signal, incoming: new Set() });
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

  invoke(
    caller: string,
    input: Uint8Array,
    config: unknown,
    imports: Record<string, string>,
    dispatch: Dispatch,
    signal: AbortSignal,
  ): Promise<unknown> {
    return this.call(caller, "invoke", [input.toBase64(), config, imports], dispatch, signal);
  }

  async close() {
    if (!this.#stop.signal.aborted) await this.#writer.close();
  }
}

export type LiveAgent = Pick<Connection, "ready" | "call" | "invoke" | "closed"> & {
  close(milliseconds: number): Promise<void>;
};

export function openAgent(
  handle: string,
  runtime: {
    module: string;
    directory: string;
    environment?: Record<string, string>;
    transport: { "frame-bytes": number; "admission-seconds": number };
  },
): LiveAgent {
  const child = new Deno.Command("janet", {
    args: ["-t", runtime.module],
    cwd: runtime.directory,
    env: {
      ...runtime.environment,
      PA_FRAME_BYTES: String(runtime.transport["frame-bytes"]),
      PA_HANDLE: handle,
    },
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const connection = new Connection(child.stdout, child.stdin, handle, runtime.transport["frame-bytes"]);
  const kill = () => {
    try {
      child.kill("SIGKILL");
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) console.error(error);
    }
  };
  const timeout = setTimeout(kill, runtime.transport["admission-seconds"] * 1000);
  void connection.ready.finally(() => clearTimeout(timeout)).catch(() => {});
  const logs = (async () => {
    for await (const text of child.stderr.pipeThrough(new TextDecoderStream())) {
      Deno.stderr.writeSync(new TextEncoder().encode(stripVTControlCharacters(text)));
    }
  })();
  const closed = (async () => {
    await connection.closed;
    kill();
    await child.status;
    await logs;
  })();
  return {
    ready: connection.ready,
    closed,
    call: connection.call.bind(connection),
    invoke: connection.invoke.bind(connection),
    async close(milliseconds: number) {
      const timer = setTimeout(kill, milliseconds);
      try {
        await connection.close();
        await closed;
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
