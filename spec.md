# Protocol

PA is a fixed, unversioned, bidirectional connection. Janet agents read stdin until EOF, write protocol frames to
stdout, and diagnostics to stderr. PA supplies codecs and correlated connections, not an agent runner or application
framework.

## Frames

Each frame is one UTF-8 JSON object followed by a newline. The configured byte limit includes the newline. Invalid
UTF-8, unknown fields, incomplete frames, and oversized frames fail. Readers yield complete frames without waiting for
EOF. Codecs validate frames and envelopes; applications authenticate and dispatch calls.

Only these fields are accepted, alongside `type`:

| Type     | Fields                             |
| -------- | ---------------------------------- |
| `ready`  | `handle`                           |
| `call`   | `id`, `caller`, `method`, `params` |
| `result` | `id`, `value`                      |
| `error`  | `id`, `error`                      |

Identities and methods are nonempty strings. `params` and `value` are JSON values. Errors contain string `code` and
`message`, optional string `detail`, and optional object `context`. A received `Diagnostic` keeps these fields when it
crosses another call boundary. It doesn't need an `output` import. Diagnostic context is not invocation authority.

The agent sends readiness once, before other messages. Its owner verifies the handle. Both sides choose distinct
outstanding IDs independently. Each accepted call receives one matching result or error. Continue reading while calls
execute; imported calls may overlap and responses may arrive out of order.

## Agent entry point

The agent exports an ordinary Janet function `invoke(input, config, imports)`: input is a byte string, config is an
agent-owned JSON-compatible value, and imports is a Janet environment of callable bindings and their documentation. The
agent returns a JSON-compatible value or raises an error. PA does not inspect configuration or schedule application
work.

Over the process connection, the host calls method `invoke` with positional `params` containing base64 input, opaque
config, and a map of imported binding names to documentation strings. The agent's process entry point decodes the input
and constructs Janet bindings that make ordinary reverse calls. Documentation grants no authority. Output, if needed, is
another supplied function, not a special protocol publication.

Root IDs contain no slash. Reverse calls use that root followed by a slash and a connection-local sequence, for example
`h17/1`. The host retains a handler for each outstanding root (`h17`, `h18`, ...), so invocations and imported calls can
overlap without a global invocation lock. A root cannot complete with its own reverse calls outstanding. Once it ends,
its imported functions are invalid. IDs select handlers, not grants: each retained handler still authorizes operations.
PA requires no policy name, authority token, application catalogue, or discovery handshake. Agents may expose ordinary
source-owned discovery methods; PA does not interpret their results.

## Identity and lifetime

The owner provisions the authoritative agent handle and authenticates which callers each source may assert. Handles
identify principals, not policies, paths, credentials, or processes. They remain stable across renames, moves, and
credential rotation; permissions are independently authorized. Newly authored agent actions use the agent's handle.
Possessing a handle does not authenticate its bearer.

Call IDs correlate transport responses only. They are not durable work references, cancellation references, credentials,
or permission to retry effects. Applications own work, persistence, and recovery. Retained work does not retain host
imports or delivery authority after disconnect.

EOF ends the connection; a partial frame fails. The owner stops its process and fails unresolved calls on disconnect. A
failed call does not prove an external action failed. PA promises neither detached execution nor durable delivery.

## Optional interaction methods

`describe(config)` returns an `AgentDescription` with `methods`, `commands` (names, descriptions, optional typed
arguments), and optionally `configSchema` (JSON Schema) and `intake` limits. An invoke-only Janet agent gets an empty
description automatically. Discovery does not grant authority. Connector-specific control commands are not agent
methods.

`prepare(config, context, input)` validates the effective config and request. Context contains conversation, request,
scope and optional command. The result contains opaque config, input and a history flag. Optional `position(config)` and
`append(config,batch)` implement history intake; cursor strings are opaque to PA. `activate(config, authority)` supplies
local recovery policy without granting delivery authority. All methods except describe take positional params arrays;
invoke retains its original wire format.

The optional `output` import takes `{type, data, final, id?, reply?}`. `type` is a MIME type. `data` is a Janet byte
string or buffer (`Uint8Array` in the SDK). Each call base64-encodes its own bytes on the wire. Wait for its reply
before sending more. An invocation has at most one open item; other invocations can stream at the same time. Keep
`type`, `id` and `reply` fixed until `final: true`. The final chunk can be empty.

For example, two `text/plain` chunks containing `Hel` and `lo` make one item, `Hello`. `id` names a published item;
`reply` names its parent. Both are opaque stable references, unrelated to frame IDs. Omit `id` for temporary output.
Disconnect before `final` leaves partial output. An acknowledgement confirms the reverse call finished, not that the
recipient stored the bytes or that a person received them.

For local recovery, `context.scope.authority` names the grant supplied to `activate`. Other scope fields identify the
delivery context and are opaque to the agent. Neither a scope nor a saved work reference authenticates its holder.
