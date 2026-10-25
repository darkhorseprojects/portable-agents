export interface Program {
  readonly sourceDir: string;
  readonly entryModule: string;
  readonly entry: string;
  readonly dependencies?: Readonly<Record<string, string>>;
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

export async function* decodeOutput(
  readable: ReadableStream<Uint8Array>,
  frameBytes: number,
  signal?: AbortSignal,
): AsyncGenerator<Event> {
  if (!Number.isInteger(frameBytes) || frameBytes < 1 || frameBytes > 0x7fffffff) {
    throw new AgentError("InvalidLimits", "Invalid frameBytes");
  }
  const encoder = new TextEncoder();
  const fields: Record<string, readonly string[]> = {
    ready: [],
    stdout: ["output"],
    result: ["output"],
    error: ["code", "message"],
  };
  let pending = "";
  let bytes = 0;
  let ready = false;
  let terminal: Event | AgentError | undefined;
  for await (
    const chunk of readable.pipeThrough(new TextDecoderStream("utf-8", { fatal: true, ignoreBOM: true }), { signal })
  ) {
    for (let offset = 0; offset < chunk.length;) {
      if (terminal) throw new AgentError("InvalidProtocol", "Trailing terminal bytes");
      const newline = chunk.indexOf("\n", offset);
      const part = chunk.slice(offset, newline < 0 ? chunk.length : newline);
      bytes += encoder.encode(part).length;
      if (bytes >= frameBytes) throw new AgentError("TransportLimit", "Frame exceeds frameBytes");
      pending += part;
      offset = newline < 0 ? chunk.length : newline + 1;
      if (newline < 0) break;
      const raw = JSON.parse(pending);
      pending = "";
      bytes = 0;
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
  if (pending || !terminal) throw new AgentError("InvalidProtocol", "Missing or partial terminal");
  if (terminal instanceof AgentError) throw terminal;
  yield terminal;
}
