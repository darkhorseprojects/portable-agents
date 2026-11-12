# Portable Agents protocol

## Boundary

PA is a fixed, unversioned, bidirectional connection. A process reads stdin until EOF and writes stdout. Diagnostics
outside the protocol go to stderr. Calls may overlap in either direction.

Each message is a UTF-8 JSON object terminated by one newline. The configured byte limit includes that newline. Invalid
UTF-8, incomplete frames, unknown fields and oversized frames are errors. Complete frames are yielded immediately,
without waiting for EOF. The SDK validates framing and envelopes; applications own authentication and dispatch.

## Messages

Every message has a `type`. Only these fields are accepted:

- `ready`: `handle`, a nonempty author string identifying the loaded process.
- `call`: nonempty strings `id`, `caller` and `method`, an argument value `params`, and optional `imports`.
- `result`: the call's `id` and its `value`.
- `error`: the call's `id` and an `error` object with string `code` and `message`, optional string `detail`, and
  optional diagnostic object `context`.
- `event`: an application-defined `value`.

`imports` is a flat object mapping nonempty binding names to documentation strings. Only PA codecs validate its shape.
Documentation neither grants authority nor supplies routing instructions. Applications register and authorize bindings
separately. `method` names the binding and `params` is its argument value, not an invocation wrapper.

The process sends readiness once before other messages. Its connection owner verifies the handle. Both sides may then
send calls, events and responses. Each side chooses distinct outstanding call IDs; opposite directions have independent
ID spaces. Each accepted call receives one result or error with the same ID. Responses may arrive in any order. Reading
must continue while incoming calls execute. Events are publications, not partial terminal responses.

Forwarders preserve originating callers and diagnostics. Transport IDs correlate requests and responses only: they are
not author identities, work identities, persistent deduplication keys or cancellation references.

## Authors and authority

`handle` and `caller` use the same nonempty string representation. No prefix is required. The connection owner supplies
the agent's authoritative handle and verifies that readiness advertises it. Handles must remain stable when persisted
authorship is retained. Importers must not replace a target's handle. Handle provisioning, persistence and configuration
formats are outside this protocol. Users retain authenticated provider identities. Newly authored agent actions use the
agent's handle; forwarding an existing call preserves its caller.

A handle identifies an author; possession of its text does not authenticate anyone. Connection owners authenticate the
source and decide which callers it may assert. Renames, moves and credential changes do not change authorship or
ownership, but do not preserve permissions automatically. Credentials, locations, revisions and work references remain
separate. PA supplies no identity registry or authorization mechanism.

## Lifetime and ownership

EOF ends the connection. A partial frame is invalid. The connection owner fails unresolved calls on disconnect. Ending
an observation does not cancel work; applications define explicit cancellation and work references separately.

Admission does not imply completion. Root outcomes, descendant execution, settlement, delivery and world publication may
have different boundaries. Applications own their ordering, execution and persistence.

The host owns and stops its process. PA promises neither detached execution nor cross-process durability. Explicitly
persistent work may survive according to the application; temporary sessions disappear with their host. A failed call or
disconnected process does not prove that external effects did not occur. Never infer safe replay from transport IDs.

Use Janet `pa/read` and `pa/write`, or TypeScript `Message`, `encode` and `decode`. PA owns no scheduler, database,
installer, invocation helper or capability transport.
