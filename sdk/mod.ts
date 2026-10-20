/** Opaque-byte programs over Portable Agents protocol 1. @module */
import { spawn as spawnProcess } from "node:child_process";
import process from "node:process";
import { once } from "node:events";
import { addAbortSignal } from "node:stream";

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
const fields = new Map<string, readonly string[]>([
  ["ready", []],
  ["emit", ["output"]],
  ["result", ["output"]],
  ["log", ["stage"]],
  ["traceback", ["message"]],
  ["error", ["code", "message"]],
]);

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
  const failure = new AbortController();
  const signal = AbortSignal.any([failure.signal, ...(options.signal ? [options.signal] : [])]);
  const exited = once(child, "close", { signal }).then(([code]) => code ?? -1, (cause) => {
    failure.abort(new AgentError("ProcessFailure", String(cause)));
    return -1;
  });
  child.stdin!.on("error", (cause) => failure.abort(new AgentError("ProcessFailure", String(cause))));
  addAbortSignal(signal, child.stdout!);
  const admission = setTimeout(() =>
    failure.abort(
      new AgentError("AdmissionTimeout", "Execution may have accepted the request"),
    ), limits.admissionSeconds * 1000);
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  const pending = new Uint8Array(new ArrayBuffer(0, { maxByteLength: limits.frameBytes - 1 }));
  let used = 0;
  let terminal: Event | AgentError | undefined;
  let admitted = false;
  try {
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
          const keys = Object.keys(raw ?? {});
          let count = 0;
          for (const match of line.matchAll(/"(?:[^"\\]|\\.)*"([ \t\r]*:)?/g)) if (match[1]) count++;
          if (count !== keys.length) throw new Error("Duplicate object key");
          const required = fields.get(raw?.type);
          if (
            raw?.version !== 1 || !required || keys.length !== required.length + 2 ||
            !keys.includes("version") || !keys.includes("type") ||
            required.some((key) => !keys.includes(key) || typeof raw[key] !== "string" || !raw[key].isWellFormed())
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
    const code = await exited;
    signal.throwIfAborted();
    if (code !== 0) throw new AgentError("ProcessFailure", `agent exited ${code}`);
    if (terminal instanceof AgentError) throw terminal;
    yield terminal;
  } catch (cause) {
    if (signal.aborted) {
      throw signal.reason instanceof AgentError
        ? signal.reason
        : new AgentError("ObservationCancelled", String(signal.reason));
    }
    throw cause instanceof AgentError ? cause : new AgentError("ProcessFailure", String(cause));
  } finally {
    clearTimeout(admission);
    child.unref();
    child.stdin!.destroy();
    child.stdout!.destroy();
  }
}
