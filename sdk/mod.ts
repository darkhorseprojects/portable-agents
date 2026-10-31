export interface ForeignImport {
  readonly command: readonly string[];
  readonly exports: Readonly<Record<string, string>>;
  readonly timeoutSeconds?: number;
}

export interface Program {
  readonly sourceDir: string;
  readonly entryModule: string;
  readonly entry: string;
  readonly dependencies?: Readonly<Record<string, string>>;
  readonly imports?: Readonly<Record<string, ForeignImport>>;
}

export type Event =
  & { readonly version: 1 }
  & (
    | { readonly type: "ready" }
    | { readonly type: "stdout" | "result"; readonly output: Uint8Array }
  );

export class AgentError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly detail?: string,
    readonly context?: Readonly<Record<string, unknown>>,
  ) {
    super(message);
    this.name = "AgentError";
  }
}

export function encodeRequest(
  program: Program,
  input: Uint8Array,
  config: Uint8Array,
  frameBytes: number,
): Uint8Array {
  if (!Number.isInteger(frameBytes) || frameBytes < 1 || frameBytes > 0x7fffffff) {
    throw new AgentError("InvalidLimits", "Invalid frameBytes");
  }
  if (input.length + config.length > frameBytes) throw new AgentError("TransportLimit", "Request exceeds frameBytes");
  const request = new TextEncoder().encode(
    JSON.stringify({ version: 1, program, input: input.toBase64(), config: config.toBase64() }) + "\n",
  );
  if (request.length > frameBytes) throw new AgentError("TransportLimit", "Request exceeds frameBytes");
  return request;
}

export class LineDecoder {
  readonly #buffer: ArrayBuffer;
  readonly #decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

  constructor(maximumBytes: number) {
    if (!Number.isInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 0x7fffffff) {
      throw new AgentError("InvalidLimits", "Invalid frameBytes");
    }
    this.#buffer = new ArrayBuffer(0, { maxByteLength: maximumBytes });
  }

  *push(chunk: Uint8Array): Generator<string> {
    for (let offset = 0; offset < chunk.length;) {
      const newline = chunk.indexOf(10, offset);
      const part = chunk.subarray(offset, newline < 0 ? chunk.length : newline);
      const position = this.#buffer.byteLength;
      const size = position + part.length;
      if (size >= this.#buffer.maxByteLength) throw new AgentError("TransportLimit", "Frame exceeds frameBytes");
      this.#buffer.resize(size);
      new Uint8Array(this.#buffer).set(part, position);
      offset = newline < 0 ? chunk.length : newline + 1;
      if (newline < 0) break;
      const line = this.#decoder.decode(this.#buffer);
      this.#buffer.resize(0);
      yield line;
    }
  }

  finish(): void {
    if (this.#buffer.byteLength) throw new AgentError("InvalidProtocol", "Partial frame");
  }
}

export async function serveImport(
  readable: ReadableStream<Uint8Array>,
  writable: WritableStream<Uint8Array>,
  frameBytes: number,
  invoke: (name: string, args: unknown[], operation?: string) => Promise<unknown>,
): Promise<void> {
  const encoder = new TextEncoder();
  const writer = writable.getWriter();
  try {
    let bytes: Uint8Array;
    try {
      const lines = new LineDecoder(frameBytes);
      let request;
      for await (const chunk of readable) {
        for (const line of lines.push(chunk)) {
          if (request !== undefined) throw new AgentError("InvalidProtocol", "Trailing import request");
          request = JSON.parse(line);
        }
      }
      lines.finish();
      if (
        request?.version !== 1 || typeof request.export !== "string" || !request.export.isWellFormed() ||
        !Array.isArray(request.arguments) || request.operation !== undefined &&
          (typeof request.operation !== "string" || !request.operation.isWellFormed())
      ) throw new AgentError("InvalidProtocol", "Invalid import request");
      bytes = encoder.encode(
        JSON.stringify({
          version: 1,
          type: "result",
          value: await invoke(request.export, request.arguments, request.operation),
        }) + "\n",
      );
      if (bytes.length > frameBytes) {
        throw new AgentError("TransportLimit", "Import outcome exceeds frameBytes; effects may have happened");
      }
    } catch (error) {
      bytes = encoder.encode(
        JSON.stringify({
          version: 1,
          type: "error",
          code: error instanceof AgentError ? error.code : "ImportError",
          message: error instanceof Error ? error.message : String(error),
          detail: error instanceof AgentError ? error.detail : error instanceof Error ? error.stack : undefined,
          context: error instanceof AgentError ? error.context : undefined,
        }) + "\n",
      );
    }
    if (bytes.length > frameBytes) throw new AgentError("TransportLimit", "Import outcome exceeds frameBytes");
    await writer.write(bytes);
    await writer.close();
  } finally {
    writer.releaseLock();
  }
}

export async function* decodeOutput(
  readable: ReadableStream<Uint8Array>,
  frameBytes: number,
  signal?: AbortSignal,
): AsyncGenerator<Event> {
  const lines = new LineDecoder(frameBytes);
  const fields: Record<string, readonly string[]> = {
    ready: [],
    stdout: ["output"],
    result: ["output"],
    error: ["code", "message"],
  };
  let ready = false;
  let terminal: Event | AgentError | undefined;
  for await (
    const chunk of readable.pipeThrough(new TransformStream<Uint8Array, Uint8Array>(), { signal })
  ) {
    for (const line of lines.push(chunk)) {
      if (terminal) throw new AgentError("InvalidProtocol", "Trailing terminal bytes");
      const raw = JSON.parse(line);
      const required = Object.hasOwn(fields, raw?.type) && fields[raw.type];
      if (
        raw?.version !== 1 || !required ||
        required.some((key) => typeof raw[key] !== "string" || !raw[key].isWellFormed()) ||
        raw.detail !== undefined && (typeof raw.detail !== "string" || !raw.detail.isWellFormed()) ||
        raw.context !== undefined && (!raw.context || typeof raw.context !== "object" || Array.isArray(raw.context))
      ) throw new AgentError("InvalidProtocol", "Invalid frame fields");
      if (raw.type === "ready") {
        if (ready) throw new AgentError("InvalidProtocol", "Duplicate readiness");
        ready = true;
        yield raw;
      } else if (raw.type === "error") {
        terminal = new AgentError(raw.code, raw.message, raw.detail, raw.context);
      } else {
        if (raw.type === "result" && !ready) throw new AgentError("InvalidProtocol", "Missing readiness");
        raw.output = Uint8Array.fromBase64(raw.output);
        if (raw.type === "result") terminal = raw;
        else yield raw;
      }
    }
  }
  lines.finish();
  if (!terminal) throw new AgentError("InvalidProtocol", "Missing terminal");
  if (terminal instanceof AgentError) throw terminal;
  yield terminal;
}
