# Connector application interaction

This is an application convention carried over PA, not an extension to PA envelopes. PA codecs do not validate it. The
deployed agents are Janet programs. Connector remains a TypeScript host; it does not interpret their execution state.

## Configuration and discovery

The connection owner calls `app/open` with `settings` and an optional `initialize` boolean. `settings` contains opaque
application `config`, named application `profiles`, and the default `profile` name. Connector expands only its own
`${instance}` and `${directory}` variables. Applications validate settings and own initialization. The PA call's
`imports` map documents separately authorized external bindings.

The result contains `profiles`, mapping each configured name to:

- `inputs`: supported input kinds, `text` and/or `code`. Code is Janet source.
- `retain`: whether Connector should retain this profile's session and delivery metadata.
- `history`: maximum source records accepted in one intake batch.
- `parameters`: user-exposed submission option descriptions.
- `commands`: application commands with `name`, `description`, and `parameters`.

Parameters contain `name`, `description`, `type` (`string`, `integer`, `number`, `boolean`), and optional `default`,
`minimum`, `maximum`, `choices`, and `autocomplete`. An autocomplete value names an application command, not a provider.
Descriptions supply an interface, not authority. Applications revalidate all arguments. Profiles are configurations of
one application, not separate agents.

`app/open` and `app/observe` are owner-only. Opening an initialized application may recover its work immediately;
observation neither starts nor cancels work.

## Calls

Application calls carry the selected `profile`. Work references and navigation `state` are opaque JSON values.

- `app/submit`: `request`, `input`, optional `options`, `state`, and `context`. Input contains exactly one of `text` or
  `code`, optional `at`, `records`, and `images`. Images contain MIME `type` and base64 `data`. Source records contain
  `key`, `author`, `at`, and `text`. Returns `work` and optional replacement `state`.
- `app/append`: `records` and `state`. Adds source information without executing it. Returns optional replacement
  `state`.
- `app/read`: `work` and optional `wait` boolean. Returns the application's opaque terminal result, or null while
  pending. A waiting observation does not own the work's lifetime.
- `app/cancel`: `work`. Requests application-defined cancellation, never rollback of external actions.
- `app/command`: `command`, `arguments`, optional `state`, `options`, and `context`. Returns optional `value`, `work`,
  and replacement `state`. With `completion: true`, returns `choices` containing string `name`/`value` pairs. Connector
  sends the completion query in `arguments.query`.
- `app/observe`: `cursors`, an object mapping opaque stream names to opaque output cursors. Starts ordered replay and
  live observation. Missing streams start at their beginning. Unknown cursors fail explicitly.

`request` is a persistent application deduplication key, not a PA call ID. Reusing it for different input is an error.
The application defines completion, concurrency, durability, and work authorization. These are not inferred by
Connector.

## Output

A PA `event.value` contains:

```text
stream: opaque string
cursor: opaque string
context: optional opaque routing-ticket string
work: opaque JSON work reference
state: optional replacement navigation state
retain: boolean
output:
  id: stable string
  text: string
  reply: optional output ID
  language: optional string
  footer: optional application-authored text
```

An application publishes only committed output. Streams are ordered; cursors are saved and returned unchanged, never
compared numerically. Output IDs deduplicate delivery. Connector stages output before advancing observation. Delivery
attempts without receipts are uncertain and must not be automatically repeated.

Connector issues routing tickets and owns their authenticated source, destination, profile, deployment and expiry.
Applications retain and echo the opaque ticket; they do not authorize Discord destinations. Output without a ticket is
observable but has no Discord destination. A recursive computation may inherit its caller's ticket. Connector changes
selected navigation only for the exact opaque work returned by the corresponding admission, not its descendants.

Connector owns text splitting, attachments, and delivery receipts. Applications own language labels, optional footers,
and their internal presentation meaning. No path, inquiry, round, world, event-ID range, or database schema belongs to
this interaction contract.
