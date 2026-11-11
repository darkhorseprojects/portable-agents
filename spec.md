# Portable Agents protocol

## Boundary

Protocol version is 1. A process connection accepts calls on stdin until EOF and responds on stdout. Diagnostics not
intended as protocol messages go to stderr. Calls may overlap on one connection.

Each message is a UTF-8 JSON object terminated by one newline. The configured byte limit includes that newline. Invalid
UTF-8, incomplete frames, unsupported envelopes and oversized frames are errors. A complete frame is available
immediately; it does not wait for connection EOF.

## Messages

Every message has `version` equal to 1 and a `type`. Other envelope fields are rejected.

- `ready`: no additional fields. The process is loaded, not necessarily configured or durably initialized.
- `call`: nonempty string `id`, nonempty string `method`, and `params`.
- `event`: `value`, containing application-defined identities and committed information.
- `result`: the call's `id` and its `value`.
- `error`: the call's `id` and an `error` object with string `code` and `message`, optional string `detail`, and
  optional object `context`. Other diagnostic fields are rejected.

The process sends readiness once, before events or responses. A caller chooses a distinct ID for every call on that
connection. Each call receives exactly one result or error with the same ID. Responses may arrive in any order. Events
are application publications, not fragments of a call's terminal response. The codec validates framing and envelopes;
the connection owner enforces readiness and call correlation.

Forwarders preserve originating diagnostic fields. An error or process exit is not proof that admitted external effects
did not occur. Transport IDs have no persistent meaning and do not deduplicate work.

## Lifetime and ownership

EOF ends the connection. A partial frame is invalid. The caller fails unresolved calls if the process or connection
ends. Closing an individual call's observation does not request work cancellation. Applications define explicit
cancellation and work identities separately from transport IDs.

Returning an admission does not imply completion. Root outcomes, descendant execution, final settlement and world
publication may have distinct boundaries. The application owns their ordering and concurrency.

The host owns its process and stops it on exit. There is no detached-execution or execution-durability promise in PA.
Applications may retain explicitly persistent work; temporary sessions disappear with their host. Interrupted external
effects may require reconciliation, not automatic replay.

Installation, runtime selection, authority, scheduling and capability transports belong to applications. This connection
lifecycle replaces the former one-call-and-EOF lifecycle; no compatibility mode exists.
