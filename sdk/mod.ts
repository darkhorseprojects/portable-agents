/** Opaque-byte programs over Portable Agents protocol 1. @module */
import { Effect, Stream } from "effect";
import { ChildProcess, ChildProcessSpawner } from "effect/process";

/** A selected package and its explicit @name dependency roots. */
export interface Program {
  readonly sourceDir: string;
  readonly entryModule: string;
  readonly dependencies?: Readonly<Record<string, string>>;
  readonly command?: readonly string[];
}

/** A named proxy grant with invoker-owned configuration. */
export interface Import {
  readonly name: string;
  readonly program: Program;
  readonly config: Uint8Array;
  readonly members: readonly string[];
  readonly imports?: readonly string[];
  readonly spawn?: boolean;
}

/** Invocation, process settings, and mandatory invoker-selected boundary bounds. */
export interface Options {
  readonly program: Program;
  readonly limits: Readonly<Record<"frameBytes" | "depth" | "inFlight" | "handles" | "admissionSeconds", number>>;
  readonly member?: string;
  readonly command?: readonly string[];
  readonly cwd?: string;
  readonly environment?: Readonly<Record<string, string>>;
  readonly spawn?: readonly string[];
}

/** Ordered byte and diagnostic events; errors use the stream's failure channel. */
export type Event =
  & { readonly version: 1 }
  & (
    | { readonly type: "emit" | "append" | "result"; readonly output: Uint8Array }
    | { readonly type: "log"; readonly stage: string }
    | { readonly type: "traceback"; readonly message: string }
  );

/** Typed protocol, process, and program failures. */
export class AgentError extends Error {
  readonly code: string;

  constructor({ code, message }: { readonly code: string; readonly message: string }) {
    super(message);
    this.name = "AgentError";
    this.code = code;
  }
}

const encoder = new TextEncoder();
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=|[A-Za-z0-9+/][AQgw]==)?(?![\s\S])/;

/** Collect the terminal bytes from an invocation. */
export function call(
  options: Options,
  input: Uint8Array,
  config: Uint8Array,
  imports: readonly Import[] = [],
): Effect.Effect<Uint8Array, AgentError, ChildProcessSpawner.ChildProcessSpawner> {
  return Stream.runFold(
    stream(options, input, config, imports),
    (): Uint8Array => new Uint8Array(),
    (output, event) => event.type === "result" ? event.output : output,
  );
}

/** Invoke through the consumer's process service; publish terminal output only after successful exit. */
export function stream(
  options: Options,
  input: Uint8Array,
  config: Uint8Array,
  imports: readonly Import[] = [],
): Stream.Stream<Event, AgentError, ChildProcessSpawner.ChildProcessSpawner> {
  return Stream.unwrap(Effect.gen(function* () {
    const { request, limits } = yield* Effect.try({
      try: () => {
        const limits = { ...options.limits };
        if (
          Object.keys(limits).length !== 5 || limits.depth < 2 ||
          !Number.isFinite(limits.admissionSeconds) || limits.admissionSeconds <= 0 ||
          [limits.frameBytes, limits.depth, limits.inFlight, limits.handles].some((n) =>
            !Number.isInteger(n) || n <= 0 || n > 0x7fffffff
          )
        ) throw new Error("Invalid boundary limits");
        let bytes = input.length + config.length;
        for (const grant of imports) bytes += grant.config.length;
        if (bytes * 4 / 3 > limits.frameBytes) throw new Error("Request exceeds bound");

        const request = encoder.encode(
          JSON.stringify({
            version: 1,
            program: options.program,
            input: input.toBase64(),
            config: config.toBase64(),
            member: options.member,
            imports: imports.map((grant) => ({ ...grant, config: grant.config.toBase64() })),
            spawn: options.spawn,
          }) + "\n",
        );
        if (request.length > limits.frameBytes) throw new Error("Request exceeds bound");
        return { request, limits };
      },
      catch: (cause) => new AgentError({ code: "InvalidProtocol", message: String(cause) }),
    });

    const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
    const [command, ...args] = options.command ?? ["agent"];
    const child = yield* spawner.spawn(ChildProcess.make(
      command,
      [
        ...args,
        "call",
        ...[limits.frameBytes, limits.depth, limits.inFlight, limits.handles, limits.admissionSeconds].map(String),
      ],
      { cwd: options.cwd, env: options.environment, stdin: Stream.make(request), stdout: "pipe", stderr: "inherit" },
    )).pipe(Effect.mapError((cause) => new AgentError({ code: "ProcessFailure", message: String(cause) })));

    const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
    const pending = new Uint8Array(new ArrayBuffer(0, { maxByteLength: limits.frameBytes - 1 }));
    let used = 0;
    let terminal: Event | AgentError | undefined;

    const events = child.stdout.pipe(
      Stream.mapError((cause) => new AgentError({ code: "ProcessFailure", message: String(cause) })),
      Stream.mapEffect((chunk) =>
        Effect.try({
          try: () => {
            const events: Event[] = [];
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

              const keys = new Set<string>();
              const token = /"(?:[^"\\]|\\.)*"/y;
              let depth = 0;
              for (let i = 0; i < line.length; i++) {
                if (line[i] === '"') {
                  token.lastIndex = i;
                  const match = token.exec(line);
                  if (!match) throw new Error("Invalid string");
                  i = token.lastIndex - 1;
                  let next = token.lastIndex;
                  while (line[next] === " " || line[next] === "\t" || line[next] === "\r") ++next;
                  if (line[next] === ":") {
                    const text: string = JSON.parse(match[0]);
                    if (keys.has(text)) throw new Error("Duplicate object key");
                    keys.add(text);
                  }
                } else if (line[i] === "{") {
                  if (++depth !== 1) throw new Error("Nonflat frame");
                } else if (line[i] === "}") --depth;
                else if (line[i] === "[" || line[i] === "]") throw new Error("Nonflat frame");
              }
              const raw = JSON.parse(line);
              const fields = raw?.type === "error"
                ? ["code", "message"]
                : raw?.type === "log"
                ? ["stage"]
                : raw?.type === "traceback"
                ? ["message"]
                : ["output"];
              if (
                raw?.version !== 1 || !["emit", "append", "result", "log", "traceback", "error"].includes(raw?.type) ||
                keys.size !== fields.length + 2 || !keys.has("version") || !keys.has("type") ||
                fields.some((key) => !keys.has(key) || typeof raw[key] !== "string" || !raw[key].isWellFormed())
              ) throw new Error("Invalid frame fields");
              if ("output" in raw) {
                if (!base64.test(raw.output)) throw new Error("Noncanonical Base64");
                raw.output = Uint8Array.fromBase64(raw.output);
              }
              if (raw.type === "error") terminal = new AgentError({ code: raw.code, message: raw.message });
              else if (raw.type === "result") terminal = raw;
              else events.push(raw);
            }
            return events;
          },
          catch: (cause) => new AgentError({ code: "InvalidProtocol", message: String(cause) }),
        })
      ),
      Stream.flatMap(Stream.fromIterable),
    );

    const finish = Stream.fromEffect(Effect.gen(function* () {
      if (used || !terminal) {
        return yield* Effect.fail(new AgentError({ code: "InvalidProtocol", message: "Missing or partial terminal" }));
      }
      const code = yield* child.exitCode.pipe(
        Effect.mapError((cause) => new AgentError({ code: "ProcessFailure", message: String(cause) })),
      );
      if (code !== 0) {
        return yield* Effect.fail(new AgentError({ code: "ProcessFailure", message: `agent exited ${code}` }));
      }
      if (terminal instanceof AgentError) return yield* Effect.fail(terminal);
      return terminal;
    }));

    return events.pipe(Stream.concat(finish));
  }));
}
