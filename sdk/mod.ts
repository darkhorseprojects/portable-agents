/** Opaque-byte programs over Portable Agents protocol 3. @module */
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
  readonly limits: Readonly<Record<"frameBytes" | "admissionSeconds", number>>;
  readonly command?: readonly string[];
  readonly cwd?: string;
  readonly environment?: Readonly<Record<string, string>>;
  readonly signal?: AbortSignal;
}

export interface Diagnostic {
  readonly code: string;
  readonly message: string;
  readonly detail?: string;
  readonly context?: Readonly<Record<string, unknown>>;
}

export type Event =
  & { readonly version: 3 }
  & (
    | { readonly type: "emit"; readonly output: Uint8Array }
    | { readonly type: "result"; readonly output: Uint8Array }
    | ({ readonly type: "diagnostic"; readonly level: "debug" | "info" | "warn" } & Diagnostic)
  );

/** Typed protocol, process, and program failures. */
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

const fields = new Map<string, readonly string[]>([
  ["ready", []],
  ["emit", ["output"]],
  ["result", ["output"]],
  ["diagnostic", ["level", "code", "message"]],
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
      !Number.isFinite(limits.admissionSeconds) || limits.admissionSeconds <= 0 ||
      !Number.isInteger(limits.frameBytes) || limits.frameBytes <= 0 || limits.frameBytes > 0x7fffffff
    ) throw new Error("Invalid boundary limits");
    if ((input.length + config.length) * 4 / 3 > limits.frameBytes) throw new Error("Request exceeds bound");
    request = new TextEncoder().encode(
      JSON.stringify({
        version: 3,
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
      ...[limits.frameBytes, limits.admissionSeconds].map(String),
    ], {
      cwd: options.cwd,
      env: { ...process.env, ...options.environment },
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
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
  addAbortSignal(signal, child.stderr!);
  let stderr = "";
  const diagnostics = (async () => {
    const text = new TextDecoder();
    let bytes = 0;
    for await (const chunk of child.stderr! as AsyncIterable<Uint8Array>) {
      bytes += chunk.length;
      if (bytes > limits.frameBytes) throw new AgentError("DiagnosticTooLarge", "Native stderr exceeds frameBytes");
      stderr += text.decode(chunk, { stream: true });
    }
    stderr += text.decode();
  })().catch((cause) => {
    if (!signal.aborted) failure.abort(cause);
  });
  const admission = setTimeout(() =>
    failure.abort(
      new AgentError("AdmissionTimeout", "Execution may have accepted the request"),
    ), limits.admissionSeconds * 1000);
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  let pending = "";
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
          used += end - offset;
          if (used >= limits.frameBytes) throw new Error("Frame exceeds bound");
          pending += decoder.decode(chunk.subarray(offset, end), { stream: index === -1 });
          offset = end + 1;
          if (index === -1) break;
          const raw = JSON.parse(pending);
          pending = "";
          used = 0;
          const required = fields.get(raw?.type);
          if (
            raw?.version !== 3 || !required ||
            required.some((key) => typeof raw[key] !== "string" || !raw[key].isWellFormed()) ||
            raw.detail !== undefined && (typeof raw.detail !== "string" || !raw.detail.isWellFormed()) ||
            raw.context !== undefined &&
              (!raw.context || typeof raw.context !== "object" || Array.isArray(raw.context)) ||
            raw.type === "diagnostic" && !["debug", "info", "warn"].includes(raw.level)
          ) throw new Error("Invalid frame fields");
          if (raw.type === "ready") {
            if (admitted) throw new Error("Duplicate admission");
            admitted = true;
            clearTimeout(admission);
          } else {
            if (!admitted && !["diagnostic", "error"].includes(raw.type)) throw new Error("Missing admission");
            if ("output" in raw) {
              raw.output = Uint8Array.fromBase64(raw.output);
            }
            if (raw.type === "error") terminal = new AgentError(raw.code, raw.message, raw.detail, raw.context);
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
    await diagnostics;
    signal.throwIfAborted();
    if (code !== 0) throw new AgentError("ProcessFailure", `agent exited ${code}`);
    if (terminal instanceof AgentError) throw terminal;
    if (stderr) yield { version: 3, type: "diagnostic", level: "debug", code: "NativeStderr", message: stderr };
    yield terminal;
  } catch (cause) {
    if (signal.aborted) {
      throw signal.reason instanceof AgentError
        ? signal.reason
        : new AgentError("ObservationCancelled", String(signal.reason));
    }
    if (cause instanceof AgentError) {
      throw new AgentError(
        cause.code,
        cause.message,
        [cause.detail, stderr].filter(Boolean).join("\n") || undefined,
        cause.context,
      );
    }
    throw new AgentError("ProcessFailure", String(cause), stderr);
  } finally {
    clearTimeout(admission);
    child.unref();
    child.stdin!.destroy();
    child.stdout!.destroy();
    child.stderr!.destroy();
  }
}
