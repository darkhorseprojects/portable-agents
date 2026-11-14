# Protocol

PA is a fixed, unversioned, bidirectional process connection. Deployed applications are Janet programs by convention.
They read stdin until EOF, write protocol frames to stdout, and diagnostics to stderr. The optional
[application contract](interaction.md) does not change the wire protocol.

## Frames

Each frame is one UTF-8 JSON object followed by a newline. The configured byte limit includes the newline. Invalid
UTF-8, unknown fields, incomplete frames, and oversized frames fail. Readers yield complete frames without waiting for
EOF. Codecs validate frames and envelopes; applications authenticate and dispatch calls.

## Envelopes

Only these fields are accepted, alongside `type`:

| Type     | Fields                                                 |
| -------- | ------------------------------------------------------ |
| `ready`  | `handle`                                               |
| `call`   | `id`, `caller`, `method`, `params`, optional `imports` |
| `result` | `id`, `value`                                          |
| `error`  | `id`, `error`                                          |
| `event`  | `value`                                                |

Identities and methods are nonempty strings. `params` and `value` are JSON values. Errors contain string `code` and
`message`, optional string `detail`, and optional object `context`. Imports map nonempty binding names to documentation
strings; documentation grants no authority. `method` names the operation and `params` holds its argument directly.

The process sends readiness once, before other messages. Its owner verifies the handle. Both sides then accept
overlapping calls and choose distinct outstanding IDs independently. Each accepted call receives one matching result or
error; responses may arrive out of order. Continue reading while calls execute. Events are publications, not terminal
responses.

## Authority and lifetime

The connection owner provisions the authoritative handle and authenticates which callers each source may assert. Handles
remain stable with retained authorship. Users keep authenticated provider identities; newly authored agent actions use
the agent's handle. Forwarders preserve originating callers and diagnostics. Possessing a handle does not authenticate
its bearer. Moves, renames, or credential changes do not preserve permissions automatically.

Transport IDs correlate calls only. They are not durable work IDs, cancellation references, credentials, or permission
to retry effects. Admission, completion, delivery, and world publication may have different boundaries.

EOF ends the connection; a partial frame fails. The owner stops its process and fails unresolved calls on disconnect.
Observation does not own work. Applications define cancellation, recovery, and persistence. PA promises neither detached
execution nor durable delivery. A failed call does not prove an external action failed.

The libraries expose only Janet `pa/read`/`pa/write` and TypeScript `Message`/`encode`/`decode`.
