export type Message =
  | { readonly version: 1; readonly type: "call"; readonly method: string; readonly params: unknown }
  | { readonly version: 1; readonly type: "ready" }
  | { readonly version: 1; readonly type: "event" | "result"; readonly value: unknown }
  | {
    readonly version: 1;
    readonly type: "error";
    readonly error: {
      readonly code: string;
      readonly message: string;
      readonly detail?: string;
      readonly context?: Readonly<Record<string, unknown>>;
    };
  };

function message(value: unknown): Message {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid protocol message");
  const raw = value as Record<string, unknown>;
  const fields: Record<string, readonly string[]> = {
    call: ["method", "params"],
    ready: [],
    event: ["value"],
    result: ["value"],
    error: ["error"],
  };
  const required = typeof raw.type === "string" && Object.hasOwn(fields, raw.type) && fields[raw.type];
  if (
    raw.version !== 1 || !required || required.some((key) => !Object.hasOwn(raw, key)) ||
    Object.keys(raw).some((key) => !["version", "type", ...required].includes(key))
  ) throw new Error("Invalid protocol envelope");
  if (raw.type === "call" && (typeof raw.method !== "string" || !raw.method || !raw.method.isWellFormed())) {
    throw new Error("Invalid method");
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
  let ready = false;
  let terminal: Message | undefined;
  for await (const chunk of readable) {
    for (let offset = 0; offset < chunk.length;) {
      if (terminal) throw new Error("Trailing terminal bytes");
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
      switch (value.type) {
        case "call":
          if (ready) throw new Error("Call in response stream");
          terminal = value;
          break;
        case "ready":
          if (ready) throw new Error("Duplicate readiness");
          ready = true;
          yield value;
          break;
        case "event":
          if (!ready) throw new Error("Missing readiness");
          yield value;
          break;
        case "result":
          if (!ready) throw new Error("Missing readiness");
          terminal = value;
          break;
        case "error":
          terminal = value;
      }
    }
  }
  if (buffer.byteLength) throw new Error("Partial frame");
  if (!terminal) throw new Error("Missing terminal message");
  yield terminal;
}
