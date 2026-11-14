# Application interaction

An optional application convention over PA. Codecs validate envelopes, not this contract. Applications own execution,
work authorization, recovery, and presentation meaning. Hosts own connections, routing, and delivery.

## Discovery

The owner calls `app/open` with `settings` and optional `initialize`. Settings contain opaque application `config`,
named `profiles`, and the default `profile`. The call's `imports` documents separately authorized bindings.

The result's `profiles` maps each name to:

- `inputs`: supported kinds, `text` and/or `code` (Janet source).
- `retain`: whether the host persists session and delivery metadata.
- `history`: maximum source records per intake batch.
- `parameters`: submission option descriptions.
- `commands`: declarations with `name`, `description`, and `parameters`.

Parameters have `name`, `description`, `type` (`string`, `integer`, `number`, `boolean`), and optional `default`,
`minimum`, `maximum`, `choices`, and `autocomplete`. Autocomplete names an application command; the query is sent in
`arguments.query`. Applications revalidate arguments. Descriptions grant no authority.

`app/open` and `app/observe` are owner-only. Opening may recover work immediately. Observation never starts or cancels
it.

## Calls

Calls carry `profile`. Work references and navigation `state` are opaque JSON values, compared structurally, not parsed.

- `app/submit`: `request`, `input`, optional `options`, `state`, `context`. Input has exactly one of `text` or `code`,
  optional `at`, `records`, `images`. Records have `key`, `author`, `at`, `text`; images have MIME `type` and base64
  `data`. Returns `work` and optional replacement `state`.
- `app/append`: `records`, `state`. Adds evidence without executing it; returns optional replacement `state`.
- `app/read`: `work`, optional `wait`. Returns an opaque terminal result, or null while pending.
- `app/cancel`: `work`. Requests cancellation, never rollback.
- `app/command`: `command`, `arguments`, optional `state`, `options`, `context`. Returns optional `value`, `work`,
  `state`. With `completion: true`, returns `choices` of string `name`/`value` pairs.
- `app/observe`: `cursors`, mapping stream names to opaque cursors. Replaces observation with ordered replay and live
  output after each cursor. Missing streams start at the beginning. Unknown cursors fail.

`request` is a persistent deduplication key, not a PA call ID. Reuse with different input fails. Waiting does not own
work.

## Presentation stream

Each `event.value` has `stream`, `cursor`, `work`, `retain`, optional routing-ticket `context`, optional replacement
navigation `state`, and `output`. Streams are ordered. Cursors are saved and returned unchanged, never compared
numerically.

Content updates contain:

```text
id: stable message ID within the stream
revision: integer, starting at zero and increasing by one per update
type: response | reasoning | tool-call | tool-result
format: markdown | quote | code | json
text: appended text, not a cumulative snapshot
done: whether this presentation message is complete
language: optional code language label
reply: optional message ID in the same stream
```

Metadata updates contain only `id`, `revision`, `type: metadata`, and `text`, an application-authored single-line footer
of at most 1,000 characters. They replace the footer, not content. Metadata requires an open message and precedes its
closing update. It is published once per application loop boundary or tool/effect-result boundary, never per token or
transport split. Coincident boundaries may share one footer.

A message's content type, format, language, reply, work, context, and retention cannot change. Closed messages cannot be
updated. A nonstreaming message is one content update with `done: true`. Already-applied revisions are ignored on
replay; revision gaps fail. Distinct messages may interleave. Applications publish only committed updates.

A host saves unfinished buffers, delivery parts, and their cursors in the same durable snapshot. Unsaved deltas replay
from the previous saved cursor after restart. It sends only at explicit message completion, application loop termination
(expressed by closing its messages), or destination-size splits. There are no timer or paragraph-triggered sends. Split
at safe paragraph, line, or word boundaries; include all formatting and footer overhead. Unfinished syntax stays
buffered. Indivisible oversized constructs become attachments, not broken markup. JSON is parsed only when complete.
Message completion does not imply work completion.

## Routing and delivery

Hosts issue opaque routing tickets and own their authenticated source, destination, profile, deployment, and expiry.
Applications echo tickets; they do not authorize destinations. Child work may inherit a ticket. Output without one is
observable but has no delivery destination. Only the exact admitted work may update selected navigation, not
descendants.

Hosts own splitting, attachments, ordering, and delivery receipts. Attempts without receipts are uncertain and must not
be automatically repeated. Applications own public content, language labels, and footer wording; hosts do not interpret
internal execution references, loop labels, or status text. Ending observation does not cancel work.
