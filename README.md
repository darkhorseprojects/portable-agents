# Portable Agents

PA is a small execution boundary for ordinary Janet programs: opaque byte calls, named process-crossing tool grants,
streamed output and diagnostics, and independent executions with ephemeral completion handles. It provides a Janet
package, CLI, and Effect 4 SDK.

PA owns communication, not application state or execution policy. Programs own durable results and idempotency; the
invoker owns OS isolation, resources, and termination. PA is not an agent framework, sandbox, job queue, scheduler, or
database. Each invocation starts a process; a resident application such as Zinc runs its own evaluator and connects
through explicit service grants. PA does not retain a REPL or application environment between calls.

## Install

Use system Janet 1.42+ and Jpm:

```sh
jpm install
```

This installs `agent`. PA has no Janet runtime dependencies, custom FFI, embedded runtime, or native build. Operations
require Janet's event loop, subprocess support, and loopback networking; PA has no blanket platform ban or alternative
transport. Independent raw output uses the OS null device. Static checks do not certify cross-platform runtime behavior.

## Programs and loading

```janet
(defn call [input config]
  (pa/log "computing…")
  (pa/emit input)
  input)

(defn describe [input config] "opaque metadata")
```

`call` is the default entry. Named public callables use the same invocation path. Each receives input bytes and
configuration bytes last, and returns bytes. Strings/buffers are opaque bytes, not necessarily UTF-8. Macros and private
definitions are not callable exports.

A program descriptor has `sourceDir`, `entryModule`, and optional `dependencies`. PA sets Janet's `syspath` to the
package root and exposes dependency names as standard `@name` paths:

```json
{
  "sourceDir": "/snapshots/example",
  "entryModule": "main.janet",
  "dependencies": { "vendor": "/snapshots/vendor" }
}
```

Inside that package, `(import ./helper)` and `(import @vendor/tools)` use Janet's ordinary loader. Janet owns module
resolution, cache, circular-dependency detection, and import semantics. PA adds only a Markdown loader hook. There is no
source inventory, custom namespace confinement, symlink ban, or revision label. Specify an extension when files would
otherwise be ambiguous under Janet's lookup order.

Ordinary Janet can use explicit paths and its normal facilities. Loader settings are not a sandbox or authorization
system. The invoker supplies the trusted filesystem view, source snapshots, credentials, confinement, deadlines,
resource ceilings, and service lifetimes.

## Janet API

```janet
(import portable-agents/src/pa)
(def program {"sourceDir" "/snapshots/example" "entryModule" "main.janet"})
(def options {:limits {"frameBytes" 1048576 "depth" 32 "inFlight" 8 "handles" 8 "admissionSeconds" 5}})
(pa/invoke program "input" "config" options)
```

The three invocation operations are `pa/invoke`, `pa/spawn`, and `pa/await`. Options require `:limits`; optional keys
are `:imports`, `:member`, `:spawn`, and `:sink`. Import records require `"name"`, `"program"`, raw-byte `"config"`, and
an explicit `"members"` list; optional `"imports"` and `"spawn"` narrow delegation. A sink receives protocol frames.
Controller/worker entry functions are internal CLI plumbing, not additional invocation modes.

Inside programs:

- `pa/imports` lists supplied proxy names.
- `(pa/import "tool")` returns a proxy called as `(proxy input :member "describe")`.
- `pa/emit bytes` emits discrete data or streaming chunks; consumers decide their meaning.
- `pa/log text` emits a UTF-8 stage string without identifier or character-count restrictions.

The controller retains grant descriptors and private configurations. Requesting an unknown name cannot manufacture a
grant. Imported programs execute in separate processes with their grant's configuration and no further grants by
default. This does not prevent arbitrary Janet from using OS facilities; confinement belongs to the invoker.

### Spawn and lifetime

```janet
(def handle
  (pa/spawn program "input" "config"
            {:limits {"frameBytes" 1048576 "depth" 32 "inFlight" 8 "handles" 8 "admissionSeconds" 5}
             :spawn ["setsid" "--" "janet"]}))
(pa/await handle)
```

Independent Spawn requires an invoker-supplied launcher command. PA appends
`MAIN-SCRIPT independent FRAME-BYTES DEPTH IN-FLIGHT HANDLES ADMISSION-SECONDS`. The launcher must exec Janet or wait
for its completion, not enqueue work and return. `setsid` is a Linux example, not a PA dependency or default. Session
separation does not escape cgroups or other confinement.

Programs may use `(pa/spawn "self" input config :member "compute" :imports ["tool"])`. Targets are `"self"` or existing
proxy names. Named targets retain the grant's configuration. `:imports` delegates an explicit subset of existing grants;
omission delegates none. `:spawn true` forwards the existing launcher permission, never a new command.

Spawn returns after its independent controller accepts the complete request, including configuration and delegated
grants. The admission acknowledgment is internal, not an SDK event. Delegated children have fresh controllers and do not
call back into the original controller; their tool calls also belong to those controllers.

Handles are ephemeral and awaiting is optional. Collection and process waiting start immediately, even for ignored
handles. Each completion has one publisher and caches immutable decoded bytes or a failure; repeated/concurrent awaits
neither decode again nor consume the outcome. Pending collectors retain their handles until completion. Completed
handles can be collected when no longer referenced; there is no durable handle lookup or transport cleanup.

A program's proxy handle starts one remote completion transfer immediately. The controller reserves its slot through
launch and transfer, then releases it after the reply attempt. Repeated program awaits use the local cached outcome;
ignored handles do not accumulate completed results in the controller. Closing the invocation clears its registry
without terminating independent work.

Losing the original invoker drops observation, not independent execution. The child must perform its durable completion
write before returning. Independent raw stdout/stderr, including delegated tools' output, goes to the OS null device.
Independent emits, logs, and tracebacks are unobserved and are not forwarded; only admission and terminal completion
travel over inherited private pipes. A slow observer therefore cannot backpressure running events before the program's
commit. Ordinary calls retain streamed events and route raw output to the controller's stderr, separate from protocol
stdout.

**PA does not terminate programs.** All processes PA launches use Janet `:d`, preventing GC termination and joining.
There is no cancel API, implicit process killing, or termination on protocol failure. This is not OS detachment: the
invoker owns signals, process groups/jobs, descendant cleanup, and actual survival. A worker whose own controller is
lost gets an error on outstanding proxy calls. Death of the executing child, its controller, or its OS scope is not
recoverable through PA.

Active workers and pending proxy work are not forcibly stopped or joined when a caller returns or fails. The invoker
owns unfinished work and reaping if its process dies before PA's waiter completes. PA has no daemon, retries, durable
queue, scheduler, or recoverable task IDs.

### Durable, idempotent completion

A spawned program receives its operation key in ordinary input bytes and commits its result to an application-owned
store, either directly or through an explicitly delegated store tool. The store's configuration belongs to that grant,
not to the original caller's live process.

The program finishes the work, atomically commits by the stable operation key, then returns bytes. The store defines
what repeated keys mean and rejects conflicting reuse. PA does not interpret operation keys, deduplicate executions,
append results, or retry work.

A lost admission acknowledgment is ambiguous: the child may already own the work. Resubmitting the same logical
operation must therefore be safe. Duplicate computation is possible; deduplicating the final commit does not make other
external effects exactly-once. Those effects need their own idempotency contract.

## Markdown

Markdown integrates with Janet's standard module loader. The full document is parsed before exact `janet` fences execute
sequentially in one module scope, using Janet's standard evaluator. Executable fences are omitted from displayed
content. `pa/document` returns the completed immutable tree; the module also exports `document`.

The root is `{:content [...]}`. Heading nodes are `{:name "Title" :content [...]}`, nested by levels 1–6 in source
order. Repeated headings remain distinct. Content contains paragraphs preserving newlines, list tuples, table tuples of
row structs, and ordinary fences as `{:language ... :text ...}`. Malformed tables and unclosed fences fail. This is not
CommonMark.

Pure Markdown is an ordinary module exporting document data: `(import ./notes.md)` exposes `notes/document`. `require`
returns a module environment, as usual. Byte invocation still requires a callable entry; there is no implicit document
serialization.

## Effect 4 SDK

The SDK exports two operations, `call` and `stream`. It uses stable Effect 4.0.2 and the consumer's
`ChildProcessSpawner`; it neither imports a platform layer nor interprets Janet.

```ts
import { call, type Options } from "jsr:@darkhorseprojects/portable-agents";
import { Effect } from "npm:effect@4.0.2";
import { NodeServices } from "npm:@effect/platform-node@4.0.2";

const options: Options = {
  program: { sourceDir: "/snapshots/example", entryModule: "main.janet" },
  limits: { frameBytes: 1048576, depth: 32, inFlight: 8, handles: 8, admissionSeconds: 5 },
};
const output = await Effect.runPromise(
  call(options, new Uint8Array(), new Uint8Array()).pipe(Effect.provide(NodeServices.layer)),
);
```

- `call(options, input, config, imports?)`: Effect of terminal bytes.
- `stream(options, input, config, imports?)`: typed emit, log, traceback, and terminal result events.

`Options` requires `program` and `limits`; optional settings are `member`, `command`, `cwd`, `environment`, and a
`spawn` launcher grant. The command defaults to `["agent"]`; from a checkout use
`["janet", "/absolute/path/to/src/main.janet"]`.

`Program`, `Import`, `Options`, and `Event` describe the boundary; `AgentError` supplies typed `code`/`message`
failures. Outgoing programs are validated by Janet, not a duplicate SDK schema. Received frames use strict flat
validation; `AgentError` extends `Error`; failures use Effect's failure channel.

Use Effect's existing `Effect.forkScoped`, Fiber operations, Scope, and deadlines directly. There is no Agent object,
factory, SDK Spawn wrapper, or custom handle. Process interruption and termination follow the consumer's process layer
and OS scope; PA supplies no competing lifetime policy.

## Protocol 6

The invoker supplies all boundary bounds before input is parsed:

```sh
agent call 1048576 32 8 8 5
```

These are examples, not defaults. Limits contain exactly:

| Field              | Bound                                                                                                             |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `frameBytes`       | Complete NDJSON request/frame, including its terminator, and each internal frame, including its nine-byte header. |
| `depth`            | JSON container nesting.                                                                                           |
| `inFlight`         | Active import/spawn RPC handlers per controller, and unauthenticated peer candidates per worker launch.           |
| `handles`          | Proxy completion reservations per controller, including launches and pending transfers.                           |
| `admissionSeconds` | Post-spawn bootstrap delivery and acknowledgment deadline, in seconds.                                            |

The first four are positive signed 32-bit integers, with depth at least 2; admission seconds must be positive and finite
and may be fractional. Output reserves room for CRLF. Bounds must accommodate the request, bootstrap, RPC correlation
fields, and terminal framing; PA does not enlarge incompatible bounds. Independent children inherit them.

Work exceeding controller capacity fails with `ResourceLimit`, without a PA queue or retry. Completion transfers use
reserved handle slots, not import/spawn slots, so waiting for a child does not consume its parent's tool-call capacity.
These are local communication bounds, not global process, memory, CPU, or execution-time ceilings. Direct library
handles are not a controller registry; delegated controllers have their own bounds. The invoker still owns aggregate OS
quotas, execution deadlines, and termination.

Stdin contains exactly one LF-terminated JSON object followed by EOF:

```json
{
  "version": 6,
  "program": { "sourceDir": "/snapshots/example", "entryModule": "main.janet" },
  "input": "",
  "config": ""
}
```

Optional fields: `imports`, `member`, `spawn`. Wire bytes, including grant configurations, use canonical Base64. Each
stdout frame has `version: 6` and `type`. Earlier protocol versions are rejected; JSON object key order is not a
contract.

| Type                       | Payload                     |
| -------------------------- | --------------------------- |
| `emit`, `append`, `result` | Base64 `output`.            |
| `log`                      | UTF-8 `stage`.              |
| `traceback`                | UTF-8 `message`.            |
| `error`                    | UTF-8 `code` and `message`. |

There is no public admission frame. `(pa/emit bytes :append)` emits an `append` frame for incremental byte streams.
Diagnostic sizes are governed by the frame bound, not separate application limits; generated diagnostics are truncated
at valid UTF-8 boundaries to fit it.

Exactly one terminal result/error is required, followed by EOF and successful process status. The SDK withholds terminal
output until those checks pass. Strict decoding rejects malformed UTF-8/Unicode, duplicate/excess keys, noncanonical
Base64, and trailing/duplicate terminals. Protocol/program failures normally return an error terminal and exit zero;
crashes/nonzero status or bounds too small to frame an error are process failures.

The controller owns protocol stdout. Program stdout/stderr, including inherited subprocess output, use separate OS
descriptors. Independent-controller bootstrap and completion use inherited stdin/stdout pipes. Worker RPC uses a
per-launch loopback listener: the request, port, and random nonce arrive through private stdin; the worker sends its
nonce on TCP and must then receive private-pipe confirmation matching its socket's local endpoint before executing. A
rebound port alone cannot impersonate the controller. Worker and controller must share a loopback namespace.

Invalid peer greetings are discarded, peer candidates are bounded, and admission has a deadline. Unauthenticated local
flooding can still deny admission; this is not a denial-of-service guarantee. The listener and unclaimed connections
close after admission. PA creates no transport files, socket paths, or persistent listeners.

Internal frames are UTF-8 JSON preceded by eight lowercase hexadecimal length digits and a colon, with no newline. ASCII
headers and escaped JSON control characters preserve framing through Windows text-mode stdio. The Janet protocol JSON
decoder represents null as `:json-null`; the encoder accepts that marker and nil as JSON null. The CLI installs a POSIX
`SIGPIPE` handler so broken pipes become IO errors; Janet library embedders must arrange their own signal handling.
Closed independent observation pipes do not cancel accepted execution.

Internal RPC IDs are monotonic decimal strings correlating concurrent requests and replies. They and proxy-handle tokens
are controller-local, not application operation keys. Stream EOF wakes outstanding proxy calls with an error; truncated
or oversized frames fail without polling. Independent completion collection requires one terminal, EOF, and successful
process status just as the SDK does.

Protect PA and tool sources with a read-only trusted view, scrub ambient credentials, and use invoker-owned OS scopes
and quotas. A tool grant exposes that module's public callables: keep unintended operations private. Escape diagnostics
when presenting them in a terminal, HTML, or another interpreted surface. Arbitrary Janet can allocate memory, create
processes, and access its OS-visible resources; PA's RPC limits do not sandbox those facilities.

Loopback authentication and process separation are not a sandbox or a confidentiality guarantee against arbitrary
same-user programs. Protect the controller, credentials, and communication with OS confinement.

## Development

```sh
deno task format
deno task check
deno publish --dry-run --allow-dirty
```

Checks cover formatting, lint/types, and Janet source loading. There are no downloaded development tools. CI uses
checksum-verified prebuilt Janet on Linux/macOS/Windows for the same checks and a JSR dry-run. These static checks do
not certify runtime or lifecycle guarantees.

Further contracts: [wiki](https://github.com/darkhorseprojects/portable-agents/wiki).
