# Portable Agents protocol

## Boundary

Protocol version is 1. One process invocation accepts one call on stdin, followed by EOF. It responds on stdout.
Diagnostics not intended as protocol messages go to stderr. No multiplexing or transport request ID is defined.

Each message is a UTF-8 JSON object terminated by one newline. The configured byte limit includes that newline. Invalid
UTF-8, incomplete frames, unsupported envelopes, and trailing bytes are errors.

## Messages

Every message has `version` equal to 1 and a `type`.

A `call` has a nonempty string `method` and a `params` value. The method owner defines its parameters. Capability
transports outside this process boundary are application-defined.

A `ready` has no additional fields. It means the method is loaded, not that work was durably accepted.

An `event` has a `value` and publishes intermediate application information. An observer should publish committed
information, not transport fragments interpreted as execution state.

A `result` has a `value` and ends the invocation. Returning an admission receipt does not imply background work
finished. Applications may publish committed operation outcomes as events before the invocation ends, while independent
work continues. Concurrent operation scheduling, completion order and uncertainty recovery belong to the application;
the framing protocol imposes no sibling-completion barrier.

An `error` has an `error` object with string `code` and `message`, optional string `detail`, and optional object
`context`. It ends the invocation. An error is not proof that previously admitted external effects did not occur.

Forwarders preserve the originating diagnostic's code, message, detail, and context. Additional boundary information
must not replace the originating failure with a generic description. Application-specific outcome and replay
classification belongs to the application; it is not implied by the error envelope or process exit status.

Envelope fields other than those listed are rejected. Operation-specific parameters and values are validated by their
owner.

## Lifecycle

A request is exactly one call followed by EOF.

A response is ready, zero or more events, and exactly one result or error, followed by EOF. Initialization may fail with
an error before readiness. Calls cannot appear in responses; duplicate readiness, missing termination, and trailing data
are errors.

A decoder must consume EOF before accepting a request or terminal response. Closing observation does not request
cancellation. Process supervision, cancellation, timeout policy, and authority are not inferred from the wire lifecycle.

## Durable operations

Applications distinguish admission, execution, committed publication, and observation. Stable application identities
deduplicate work; transport frames do not provide exactly-once execution. Interrupted external operations may need
reconciliation before replay.

Durability is an application property, not a protocol guarantee. Temporary sessions may lose their database, progress,
and outcomes when the owning process is lost.

Installation, runtime selection and capability transports outside this process boundary belong to applications.
