# Portable Agents

PA spawns ordinary Janet programs across an executable boundary. Input and configuration are opaque bytes. Programs own
state and durable outcomes; PA owns loading, transport and observation.

There are no sockets, local servers, remote tool protocols, application-specific `self`, capability catalogs, resident
interpreters or execution queues in PA.

## Build and install

Use Janet 1.42+, Jpm and Deno 2.9.7:

```sh
jpm install
deno task check
deno task compile
```

Jpm installs the Janet sources. Install `dist/agent` (`agent.exe` on Windows) on PATH. The compiled executable needs
Janet and the installed PA sources, but not a Deno installation. Set `JANET_PATH` explicitly when using a nonstandard
module tree.

## Program

A descriptor selects an ordinary public function:

```json
{
  "sourceDir": "/runtime/example",
  "entryModule": "main.janet",
  "entry": "answer",
  "dependencies": { "vendor": "/runtime/vendor" }
}
```

```janet
(defn answer [input config]
  (pa/emit "working")
  input)
```

Functions receive input and configuration bytes and return bytes. PA has no default function name. Zinc declares `self`;
other programs declare their own interfaces. `command`, when supplied in a descriptor, is the trusted Janet launcher
argument vector, not a shell command.

`import`, `require`, module caches and `@name` dependency roots use Janet's loader. Markdown adds sequential executable
`janet` fences and a document tree available through `pa/document`. Nonexecutable Markdown is an ordinary data module.
Libraries are not separate PA program grants.

## SDKs

The TypeScript SDK has one operation:

```ts
import { spawn } from "jsr:@darkhorseprojects/portable-agents";
import { Effect, Stream } from "npm:effect@4.0.3";

const output = await Effect.runPromise(Stream.runCollect(spawn(
  {
    program: { sourceDir: "/runtime/example", entryModule: "main.janet", entry: "answer" },
    limits: { frameBytes: 1048576, depth: 32, admissionSeconds: 5 },
  },
  new Uint8Array(),
  new Uint8Array(),
)));
```

`spawn` is an Effect stream: consuming it starts execution. Events are emit/append bytes, stage logs, tracebacks and a
terminal result. `AgentError` supplies typed failures. Use Effect's existing stream/fiber operators to collect results
or stop observation. There are no platform-service layers, factories or second `call`/`stream` APIs.

Optional settings are the agent executable command, working directory and environment. This host SDK uses standard Node
process APIs and runs in Node-compatible hosts including Deno.

The trusted Janet SDK exposes `pa/spawn` and `pa/await`:

```janet
(import portable-agents/src/pa)
(def handle
  (pa/spawn program "input" "configuration"
            {:limits {"frameBytes" 1048576 "depth" 32 "admissionSeconds" 5}}))
(pa/await handle)
```

Spawn waits for acceptance. Completion collection starts immediately and caches the outcome; repeated awaits do not
consume it. Closing observation does not terminate accepted execution. The native bootstrap supplies its executable path
to nested spawns; there is no external `setsid` launcher contract.

PA does not inject spawn into generated REPL environments. Applications decide what those environments can call.

## Process lifetime

```text
observer -> agent bootstrap -> detached Janet execution
    X                              |
                            finish application work
                            commit application outcome
                            attempt terminal delivery
```

Executions have their own process group. SDK scope release closes pipes and unreferences its bootstrap; it does not kill
a process tree. Workers tolerate broken observation pipes. Quiet Janet spawns suppress running events, so an ignored
observer cannot backpressure their application commit.

Programs must commit before returning. An acknowledgment can be lost after acceptance; lost observation is not proof
that no work ran. Application operation keys and idempotency belong to the application.

This is not recovery from a dead executor, OS job/cgroup termination or machine failure. The invoker owns confinement
and aggregate CPU/memory/process limits. PA is not a sandbox. Trusted programs must keep native subprocess stdout out of
protocol stdout; ordinary Janet output is routed to stderr.

## Wire contract

```sh
agent spawn FRAME-BYTES DEPTH ADMISSION-SECONDS
```

Stdin is one LF-terminated JSON request followed by EOF:

```json
{
  "version": 1,
  "program": { "sourceDir": "/runtime/example", "entryModule": "main.janet", "entry": "answer" },
  "input": "",
  "config": "",
  "observe": true
}
```

Byte fields use canonical Base64. Bounds are explicit: complete frame bytes, JSON container depth and bootstrap
acceptance time. Output reserves CRLF room. Capacity bounds do not limit application computation.

Stdout uses the same NDJSON framing. A `ready` record acknowledges acceptance and is consumed internally by SDKs. Other
records contain `output` (emit/append/result), `stage` (log), `message` (traceback), or `code`/`message` (error).
Exactly one result/error, EOF and successful process exit are required. Terminal bytes are withheld until validated.

UTF-8, fields, Base64 and duplicate/trailing terminals are checked. Janet also rejects duplicate JSON keys. There is no
second socket or length-header protocol.

## Verification

```sh
python3 tests/runtime.py
deno test --allow-read --allow-write --allow-env --allow-run tests/
```

The native lifecycle probe covers opaque bytes, output separation, repeated awaits, malformed input and execution after
observer death. CI runs it on Linux, macOS and Windows. SDK observation-release tests run with PA; Connector checks the
application boundary.

Further contracts: [wiki](https://github.com/darkhorseprojects/portable-agents/wiki).
