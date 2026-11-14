# Application interaction

Optional payloads over PA. Applications own durable work, authorization, and public output. Hosts own connections,
routing, and delivery. Codecs validate envelopes, not this contract.

## Discovery

The owner calls `app/open` with `settings` and optional `initialize`. Settings contain opaque `config`, named
`profiles`, and default `profile`. Call-level `imports` documents separately authorized bindings. Opening may recover
work.

The result maps `profiles` to `inputs` (`text` and/or Janet `code`), `history` (maximum evidence batch), `parameters`,
and `commands`. Commands declare `name`, `description`, and `parameters`. Parameters declare `name`, `description`,
`type` (`string`, `integer`, `number`, `boolean`), and optional `default`, `minimum`, `maximum`, `choices`,
`autocomplete`. Autocomplete names a command receiving `arguments.query`. Discovery grants no authority; applications
revalidate input.

## Calls

Calls carry `profile`. Work, navigation `state`, and cursors are opaque JSON values returned unchanged by hosts.

- `app/submit`: `request`, `input`, optional `options`, `state`, `context`; returns `work` and optional replacement
  `state`.
- `app/append`: `records`, `state`; adds evidence without execution and returns optional replacement `state`.
- `app/read`: `work`, optional `wait`; returns a terminal result or null.
- `app/cancel`: `work`; requests cancellation, never rollback.
- `app/command`: `command`, `arguments`, optional `state`, `options`; returns optional `value`, replacement `state`,
  `format`, and `language`.
- `app/observe`: optional `cursors` mapping streams to cursors; starts ordered replay followed by live output.

Input has exactly one of `text` or `code`, optional `at`, `records`, `images`, and application-defined selectors.
Records contain `key`, `author`, `at`, `text`; images contain MIME `type` and base64 `data`. `request` persistently
deduplicates work; reuse with different input fails. PA call IDs do not identify work.

Commands only read data or replace RAM navigation, never admit work or mutate durable state. `format` uses the content
formats below; `language` labels code. With `completion: true`, return `choices` of string `name`/`value` pairs.

Prompt-free configuration updates a RAM overlay without execution. Inquiry fields override it for one submission without
consuming it. Reset discards overrides and navigation, not history or running work.

`app/open` and `app/observe` are owner-only. Observation without cursors starts live. Explicit cursors replay after
those positions; missing streams start at the beginning and unknown cursors fail. Hosts do not numerically compare
cursors.

## Output

Each `event.value` contains `stream`, `cursor`, `work`, `output`, optional routing-ticket `context`, and optional
replacement navigation `state`. Streams are ordered. Content updates contain:

```text
id: stable message ID within the stream
revision: consecutive integer starting at zero
type: response | reasoning | tool-call | tool-result
format: markdown | quote | code | json
text: appended text
done: whether this message is complete
language: optional code language
reply: optional message ID in the same stream
```

Metadata contains only `id`, `revision`, `type: metadata`, and a single-line `text` footer of at most 1,000 characters.
It replaces an open message's footer before closure, once per application loop/result boundary, not per token or split.

Type, format, language, reply, work, and context cannot change. Closed messages cannot be updated. Ignore applied
revisions on replay; reject gaps. Messages may interleave. Applications publish only committed updates. Presentation
completion does not imply work completion.

Hosts buffer until completion or destination-size splits, including formatting/footer overhead. Split at safe
boundaries; attach indivisible oversized content. Parse JSON only when complete. Timers and paragraphs alone do not
trigger sends.

## Delivery

Hosts bind routing tickets to authenticated sources, destinations, profiles, deployments, and expiry. Applications echo
tickets, not destinations. Children may inherit tickets; only exact admitted work may update selected navigation.
Unknown tickets have no destination.

Routing, buffers, cursors, and delivery tracking are connection-local. Host restart promises no delivery recovery.
Attempts without receipts are uncertain and must not be automatically repeated. Applications supply content and footer
wording; hosts handle formatting and order. Ending observation does not cancel work.
