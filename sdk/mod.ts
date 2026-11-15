export type Message =
  | {
    readonly type: "call";
    readonly id: string;
    readonly caller: string;
    readonly method: string;
    readonly params: unknown;
    readonly imports?: Readonly<Record<string, string>>;
    readonly context?: string | null;
  }
  | { readonly type: "ready"; readonly handle: string }
  | { readonly type: "event"; readonly value: unknown }
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

function message(value: unknown): Message {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid protocol message");
  const raw = value as Record<string, unknown>;
  const fields: Record<string, readonly string[]> = {
    call: ["id", "caller", "method", "params"],
    ready: ["handle"],
    event: ["value"],
    result: ["id", "value"],
    error: ["id", "error"],
  };
  const required = typeof raw.type === "string" && Object.hasOwn(fields, raw.type) && fields[raw.type];
  const optional = raw.type === "call" ? ["imports", "context"] : [];
  if (
    !required || required.some((key) => !Object.hasOwn(raw, key)) ||
    Object.keys(raw).some((key) => !["type", ...required, ...optional].includes(key))
  ) throw new Error("Invalid protocol envelope");
  for (const key of ["id", "caller", "method", "handle"]) {
    const text = raw[key];
    if (required.includes(key) && (typeof text !== "string" || !text || !text.isWellFormed())) {
      throw new Error(`Invalid ${key}`);
    }
  }
  if (raw.context != null && (typeof raw.context !== "string" || !raw.context || !raw.context.isWellFormed())) {
    throw new Error("Invalid invocation context");
  }
  if (Object.hasOwn(raw, "imports")) {
    const imports = raw.imports;
    if (
      !imports || typeof imports !== "object" || Array.isArray(imports) ||
      Object.entries(imports).some(([name, documentation]) =>
        !name || !name.isWellFormed() || typeof documentation !== "string" || !documentation.isWellFormed()
      )
    ) throw new Error("Invalid imports");
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
