/** Opaque-byte programs over Portable Agents protocol 1. @module */
import { spawn as spawnProcess } from "node:child_process";
import process from "node:process";

/** A selected package and its explicit @name dependency roots. */
export interface Program {
  readonly sourceDir: string;
  readonly entryModule: string;
  readonly entry: string;
  readonly dependencies?: Readonly<Record<string, string>>;
  readonly command?: readonly string[];
}

/** Invocation, process settings, and invoker-selected boundary bounds. */
export interface Options {
  readonly program: Program;
  readonly limits: Readonly<Record<"frameBytes" | "depth" | "admissionSeconds", number>>;
  readonly command?: readonly string[];
  readonly cwd?: string;
  readonly environment?: Readonly<Record<string, string>>;
  readonly signal?: AbortSignal;
}

/** Ordered complete events; failures throw AgentError. */
export type Event =
  & { readonly version: 1 }
  & (
    | { readonly type: "emit"; readonly output: Uint8Array }
    | { readonly type: "result"; readonly output: Uint8Array }
    | { readonly type: "log"; readonly stage: string }
    | { readonly type: "traceback"; readonly message: string }
  );

/** Typed protocol, process, and program failures. */
export class AgentError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "AgentError";
  }
}

const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=|[A-Za-z0-9+/][AQgw]==)?(?![\s\S])/;

/** Observe a detached execution; terminal output requires EOF and successful exit. */
export async function* spawn(
  options: Options,
  input: Uint8Array,
  config: Uint8Array,
): AsyncGenerator<Event, void, void> {
  if (options.signal?.aborted) throw new AgentError("ObservationCancelled", String(options.signal.reason));
  const limits = { ...options.limits };
  let request: Uint8Array;
  try {
    if (
      Object.keys(limits).length !== 3 || limits.depth < 2 ||
      !Number.isFinite(limits.admissionSeconds) || limits.admissionSeconds <= 0 ||
      [limits.frameBytes, limits.depth].some((n) => !Number.isInteger(n) || n <= 0 || n > 0x7fffffff)
    ) throw new Error("Invalid boundary limits");
    if ((input.length + config.length) * 4 / 3 > limits.frameBytes) throw new Error("Request exceeds bound");
    request = new TextEncoder().encode(
      JSON.stringify({
        version: 1,
        program: options.program,
        input: input.toBase64(),
        config: config.toBase64(),
      }) + "\n",
    );
    if (request.length > limits.frameBytes) throw new Error("Request exceeds bound");
  } catch (cause) {
    throw new AgentError("InvalidProtocol", String(cause));
  }

  const [command, ...args] = options.command ?? ["agent"];
  let child: ReturnType<typeof spawnProcess>;
  try {
    child = spawnProcess(command, [
      ...args,
      "execute",
      ...[limits.frameBytes, limits.depth, limits.admissionSeconds].map(String),
    ], {
      cwd: options.cwd,
      env: { ...process.env, ...options.environment },
      detached: true,
      stdio: ["pipe", "pipe", "inherit"],
    });
  } catch (cause) {
    throw new AgentError("ProcessFailure", String(cause));
  }
  const exited = Promise.withResolvers<number | AgentError>();
  child.once("error", (cause) => {
    const error = new AgentError("ProcessFailure", String(cause));
    exited.resolve(error);
    child.stdout!.destroy(error);
  });
  child.once("close", (code) => exited.resolve(code ?? -1));
  child.stdin!.on("error", (cause) => {
    const error = new AgentError("ProcessFailure", String(cause));
    exited.resolve(error);
    child.stdout!.destroy(error);
  });
  const abort = () => {
    const error = new AgentError("ObservationCancelled", String(options.signal!.reason));
    exited.resolve(error);
    child.stdout!.destroy(error);
  };
  const admission = setTimeout(() => {
    const error = new AgentError("AdmissionTimeout", "Execution may have accepted the request");
    exited.resolve(error);
    child.stdout!.destroy(error);
  }, limits.admissionSeconds * 1000);
  options.signal?.addEventListener("abort", abort, { once: true });
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  const pending = new Uint8Array(new ArrayBuffer(0, { maxByteLength: limits.frameBytes - 1 }));
  let used = 0;
  let terminal: Event | AgentError | undefined;
  let admitted = false;
  try {
    if (options.signal?.aborted) abort();
    child.stdin!.end(request);
    for await (const chunk of child.stdout! as AsyncIterable<Uint8Array>) {
      try {
        for (let offset = 0; offset < chunk.length;) {
          if (terminal) throw new Error("Trailing terminal bytes");
          const index = chunk.indexOf(10, offset);
          const end = index === -1 ? chunk.length : index;
          const size = used + end - offset;
          if (size >= limits.frameBytes) throw new Error("Frame exceeds bound");
          let bytes: Uint8Array;
          if (!used && index !== -1) bytes = chunk.subarray(offset, end);
          else {
            if (size > pending.length) {
              pending.buffer.resize(Math.min(limits.frameBytes - 1, Math.max(size, pending.length * 2)));
            }
            pending.set(chunk.subarray(offset, end), used);
            used = size;
            if (index === -1) break;
            bytes = pending.subarray(0, used);
          }
          used = 0;
          offset = end + 1;
          const line = decoder.decode(bytes);
          if (!line) throw new Error("Empty frame");
          const raw = JSON.parse(line);
          const keys = new Set<string>();
          let objects = 0;
          for (const match of line.matchAll(/"(?:[^"\\]|\\.)*"|[{}\[\]]/g)) {
            const token = match[0];
            if (token === "{" && ++objects !== 1 || token === "[" || token === "]") {
              throw new Error("Nonflat frame");
            }
            if (token.startsWith('"') && /^[ \t\r]*:/.test(line.slice(match.index + token.length))) {
              const key: string = JSON.parse(token);
              if (keys.has(key)) throw new Error("Duplicate object key");
              keys.add(key);
            }
          }
          const fields = raw?.type === "ready"
            ? []
            : raw?.type === "error"
            ? ["code", "message"]
            : raw?.type === "log"
            ? ["stage"]
            : raw?.type === "traceback"
            ? ["message"]
            : ["output"];
          if (
            raw?.version !== 1 || !["ready", "emit", "result", "log", "traceback", "error"].includes(raw?.type) ||
            keys.size !== fields.length + 2 || !keys.has("version") || !keys.has("type") ||
            fields.some((key) => !keys.has(key) || typeof raw[key] !== "string" || !raw[key].isWellFormed())
          ) throw new Error("Invalid frame fields");
          if (raw.type === "ready") {
            if (admitted) throw new Error("Duplicate admission");
            admitted = true;
            clearTimeout(admission);
          } else {
            if (!admitted && !["log", "traceback", "error"].includes(raw.type)) throw new Error("Missing admission");
            if ("output" in raw) {
              if (!base64.test(raw.output)) throw new Error("Noncanonical Base64");
              raw.output = Uint8Array.fromBase64(raw.output);
            }
            if (raw.type === "error") terminal = new AgentError(raw.code, raw.message);
            else if (raw.type === "result") terminal = raw;
            else yield raw;
          }
        }
      } catch (cause) {
        throw cause instanceof AgentError ? cause : new AgentError("InvalidProtocol", String(cause));
      }
    }
    if (used || !terminal) throw new AgentError("InvalidProtocol", "Missing or partial terminal");
    const code = await exited.promise;
    if (code instanceof AgentError) throw code;
    if (code !== 0) throw new AgentError("ProcessFailure", `agent exited ${code}`);
    if (terminal instanceof AgentError) throw terminal;
    yield terminal;
  } catch (cause) {
    throw cause instanceof AgentError ? cause : new AgentError("ProcessFailure", String(cause));
  } finally {
    clearTimeout(admission);
    options.signal?.removeEventListener("abort", abort);
    child.unref();
    child.stdin!.destroy();
    child.stdout!.destroy();
  }
}
