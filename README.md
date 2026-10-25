# Portable Agents

PA 0.2.0 loads ordinary Janet programs and exposes them through a small native worker and a stream-only TypeScript SDK.
Programs own their behavior, state and durable outcomes. PA owns loading, bounded transport and independent execution.

No servers, sockets, queues, agent classes, model clients, logging framework or process/future abstraction are included.
PA is not a sandbox.

## Build

Use Janet 1.42+, Jpm and a C compiler. Deno 2.9.7 checks the TypeScript SDK:

```sh
jpm deps
jpm install
deno task check
```

Use `jpm --local` for a project-local installation. CI builds Linux, macOS and Windows on x86-64 and ARM64. Its reusable
workflow exports the pinned toolchain through `workflow_call` with `toolchain: REVISION`.

The native worker embeds Janet and Spork's codecs. It needs neither Deno nor an external Janet interpreter. Markdown
lazily loads the pinned Remarkable library from the normal Janet module path; set `JANET_PATH` before loading such a
module. The parser is not embedded in the executable or loaded for plain Janet programs.

## Programs

An entry is an ordinary public function taking input/configuration bytes and returning bytes. There is no required
function name:

```janet
(defn answer [input config]
  (eprint "starting")
  (print "working")
  input)
```

`print`/`prin` supply output, `eprint`/`eprintf` supply stderr, and ordinary errors fail the invocation. There are no
injected `emit` or `diagnostic` functions. Libraries use normal imports, module caching and explicit `@name` dependency
roots.

For trusted literate modules, import `portable-agents/src/markdown` before requiring `.md` files. The worker registers
this loader itself. Remarkable parses CommonMark; only top-level fenced `janet` blocks execute, in order. Incoming
messages and retrieved Markdown are not source modules.

The module's `document` binding contains ordered sections and lists:

```janet
{:content [{:name "Agent" :level 1
            :content [{:name "Rules" :level 2
                       :content [["Be precise." "Ask when unclear."]]}]}]}
```

`(get-in document [:content 0 :content 0 :content 0 0])` reads the first item. Repeated headings retain their order.
Inline formatting becomes plain text, links retain destinations, and nonexecuted code blocks retain language/text.

## Worker and protocol

```sh
agent run FRAME-BYTES ADMISSION-SECONDS
```

Stdin is one LF-terminated JSON request followed by EOF:

```json
{
  "version": 1,
  "program": { "sourceDir": "/runtime/example", "entryModule": "main.janet", "entry": "answer" },
  "input": "",
  "config": ""
}
```

`input`, `config` and output byte fields use Base64. Optional `program.dependencies` maps names to explicit library
roots. `program.command` is not supported.

Protocol schema 1 uses bounded UTF-8 NDJSON: `ready`, `stdout`, terminal `result` or terminal `error`. Output records
contain an `output` byte field; errors contain `code`, `message`, and optional `detail`/`context`. Stderr is an ordinary
separate stream with no PA severity or application schema. Stdout may occur while loading; readiness means the
entrypoint is resolved, not that application admission committed. A successful invocation requires one terminal result,
EOF and successful process exit. Printing is a byte stream, not an application record boundary.

The worker supplies trusted code with `:pa/executable`, `:pa/program` and `:pa/limits` metadata. To launch independent
work use `os/spawn`; use `ev/` and `os/proc-wait` for concurrency and reaping. The Janet protocol library's `output`
reads/forwards stdout and returns terminal bytes; its optional readiness argument stops at `ready`. It does not create,
wait for or control a process.

## TypeScript SDK

The SDK exposes `Program`, `Event`, `AgentError`, `encodeRequest` and `decodeOutput`. The caller owns its process and
streams:

```ts
import { decodeOutput, encodeRequest } from "jsr:@darkhorseprojects/portable-agents";

const child = new Deno.Command("agent", {
  args: ["run", "1048576", "5"],
  stdin: "piped",
  stdout: "piped",
  stderr: "inherit",
}).spawn();
const writer = child.stdin.getWriter();
await writer.write(encodeRequest(program, input, config, 1048576));
await writer.close();
for await (const frame of decodeOutput(child.stdout, 1048576)) {
  console.log(frame);
}
const status = await child.status;
if (!status.success) throw new Error(`agent exited ${status.code}`);
```

The decoder validates framing and EOF, not process exit. An optional abort signal cancels stream observation, never the
process. Consumers must drain stderr as well.

## Lifetime and safety

Accepted execution survives caller death. POSIX workers create a separate session; a terminal process-group leader forks
a worker and waits only to preserve its exit status. Windows workers detach from the console. Protocol stdout is private
and non-inheritable; native stdout is redirected to stderr. Broken output and logging pipes do not abort accepted work.
Closing observation is not application cancellation.

Programs must commit durable outcomes before returning and join any local work whose completion matters. PA does not
recover a dead executor or preserve a REPL heap across machine failure. Lost acknowledgment is not proof that work did
not run. Applications own operation keys, cancellation and safe recovery. Supervisors must not terminate accepted
workers through a containing job/cgroup. The invoker owns OS confinement and aggregate resource limits.

The native codecs are Spork's MIT-licensed JSON, UTF-8 and Base64 implementations, Copyright (c) 2024 Janet
contributors. Spork's path/shell modules are Copyright (c) 2019, 2022 Calvin Rose and contributors, MIT-licensed.
Markdown uses Remarkable, Copyright (c) 2021 Michael Camilleri and Contributors, MIT-licensed. Preserve their upstream
license texts when redistributing their sources or compiled code.

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
