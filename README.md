# Portable Agents

PA 0.2.0 spawns ordinary Janet programs across an executable boundary. Input and configuration are opaque bytes.
Programs own state and durable outcomes; PA owns loading, transport and observation.

There are no sockets, local servers, remote tool protocols, application-specific `self`, capability catalogs, resident
interpreters or execution queues in PA.

## Build and install

Use Janet 1.42+, Jpm and a C compiler. Deno 2.9.7 is needed only for SDK checks:

```sh
deno task check
jpm deps
jpm install
```

The CI workflow also exports the pinned Janet/Jpm toolchain through `workflow_call` with `toolchain: REVISION`. Each
`janet-toolchain-TARGET` artifact includes the matching native PA executable and Janet sources for Linux, macOS or
Windows on x86-64 or ARM64. Consumers activate their matching artifact rather than maintaining another bootstrap.

Jpm builds and installs the native `agent` executable and Janet SDK sources. `deno task compile` also builds
`build/agent` (`agent.exe` on Windows). The normal executor embeds Janet and its loader; it needs neither Deno nor an
external Janet interpreter. An explicit `program.command` still requires that trusted interpreter and installed PA
sources. Set `JANET_PATH` explicitly when using a nonstandard module tree.

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

for await (
  const event of spawn(
    {
      program: { sourceDir: "/runtime/example", entryModule: "main.janet", entry: "answer" },
      limits: { frameBytes: 1048576, admissionSeconds: 5 },
    },
    new Uint8Array(),
    new Uint8Array(),
  )
) {
  console.log(event);
}
```

`spawn` is an async generator: consuming it starts execution. Events are complete emitted segments, structured
diagnostics and a terminal result. Failures throw `AgentError` with a stable `code`. Breaking iteration closes
observation; an optional `signal` also interrupts blocked reads or exit waits without terminating accepted execution.
`pa/emit` takes one byte value. There are no framework dependencies, factories or second `call`/`stream` APIs.

Optional settings are the agent executable command, working directory, environment and abort signal. This host SDK uses
standard Node process APIs and runs in Node-compatible hosts including Deno.

The trusted Janet SDK exposes `pa/spawn` and `pa/await`:

```janet
(import portable-agents/src/pa)
(def handle
  (pa/spawn program "input" "configuration"
            {:limits {"frameBytes" 1048576 "admissionSeconds" 5}}))
(pa/await handle)
```

Spawn waits for acceptance. Completion collection starts immediately and caches the outcome; repeated awaits do not
consume it. Closing observation does not terminate accepted execution. The native bootstrap supplies its executable path
to nested spawns; there is no external `setsid` launcher contract.

PA does not inject spawn into generated REPL environments. Applications decide what those environments can call.

## Process lifetime

```text
SDK observer -> detached native executor
CLI observer -> native bootstrap -> detached native executor
    X                              |
                            finish application work
                            commit application outcome
                            attempt terminal delivery
```

POSIX executions detach into their own session; Windows executions detach from the console. SDK iterator cleanup closes
pipes and unreferences its bootstrap; it does not kill a process tree. Cancelling observation cancels its stdout reader
without waiting for another program frame. Workers tolerate broken observation pipes. Janet spawns continuously drain
intermediate frames without retaining them, even when the caller does not await the handle. Programs emit complete
segments rather than transport fragments. PA duplicates protocol stdout into a private non-inheritable descriptor and
redirects ordinary process stdout to stderr; generated evaluators do not receive the protocol descriptor. Native stderr
is bounded and retained as a diagnostic, not interleaved with protocol bytes.

Programs must commit before returning. An acknowledgment can be lost after acceptance; lost observation is not proof
that no work ran. Application operation keys and idempotency belong to the application.

This is not recovery from a dead executor, OS job/cgroup termination or machine failure. The invoker owns confinement
and aggregate CPU/memory/process limits. PA is not a sandbox. Trusted programs must keep native subprocess stdout out of
protocol stdout; ordinary Janet output is routed to stderr.

## Wire contract

```sh
agent spawn FRAME-BYTES ADMISSION-SECONDS
```

Stdin is one LF-terminated JSON request followed by EOF:

```json
{
  "version": 3,
  "program": { "sourceDir": "/runtime/example", "entryModule": "main.janet", "entry": "answer" },
  "input": "",
  "config": ""
}
```

Byte fields use Base64. Bounds are explicit: complete frame bytes and bootstrap acceptance time. Output reserves CRLF
room. Diagnostics retain `code`, `message`, optional `detail` and `context`. Their levels are `debug`, `info` and
`warn`; terminal errors use the same fields. A diagnostic exceeding the frame limit reports `DiagnosticTooLarge` and its
original size rather than silently shortening it. Capacity bounds do not limit application computation. Native JSON
codecs own syntax and nesting limits; PA validates the fields it consumes, not canonical encodings or unknown fields.

Stdout uses the same NDJSON framing. A `ready` record acknowledges acceptance and is consumed internally by SDKs. Other
records are `emit`, `result`, `diagnostic` or terminal `error`. Exactly one result/error, EOF and successful process
exit are required. Terminal bytes are withheld until validated. `AgentError` preserves detail/context; Janet spawns can
forward diagnostics through `:diagnostic` alongside their `:emit` observer.

UTF-8, consumed fields, Base64 and duplicate/trailing terminals are checked. Duplicate JSON keys use the codec's
last-value behavior; noncanonical Base64 is accepted. Janet uses native Spork JSON syntax, while TypeScript uses
JSON.parse. There is no second socket or length-header protocol. Version 3 requires matching native binaries and SDKs.
Package version 0.2.0 is independent of the wire version.

## Native codec license

The executable embeds Spork's JSON, UTF-8 and Base64 codecs, Copyright (c) 2024 Janet contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Further contracts: [wiki](https://github.com/darkhorseprojects/portable-agents/wiki).
