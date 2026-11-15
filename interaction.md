# Application interaction

Optional application payloads over PA. Applications own work, authorization and history; hosts own connections and
delivery. Work references, navigation state and cursors are opaque JSON values.

## Discovery and calls

The owner calls `app/open` with `settings` and optional `initialize`. Settings contain full named `profiles`, a default
`profile`, and binding documentation under `imports[profile]`. Opening may recover work. The result maps profiles to
`inputs` (`text`, `code`), a `history` batch limit, `parameters`, and `commands`.

Parameters declare `name`, `description`, `type` (`string`, `integer`, `number`, `boolean`), and optional `default`,
`minimum`, `maximum`, `choices`, `autocomplete`. Commands declare a name, description and parameters. Autocomplete names
a command receiving `arguments.query`. Documentation never grants authority.

Calls carry `profile`:

- `app/submit`: `request`, `input`, optional `options`, `state`, `context`; returns `work` and optional replacement
  `state`.
- `app/read`: `work`, optional `wait`; returns a terminal result or null.
- `app/cancel`: `work`; requests cancellation, never rollback.
- `app/append`: `records`, `state`; adds evidence without executing it.
- `app/command`: `command`, `arguments`, optional `state`, `options`; returns optional `value`, replacement `state`,
  `format`, `language`, `footer`. Completion requests return `choices` of string name/value pairs.
- `app/observe`: optional stream-to-cursor map `cursors`; starts replay followed by live observation. Without cursors it
  starts live; missing streams start at the beginning and unknown positions fail. Hosts never compare application
  cursors numerically.

Input has exactly one of `text` or Janet `code`, optional `at`, `records`, `images`, and application selectors. Records
contain `key`, `author`, `at`, `text`; images contain MIME `type` and base64 `data`. Request identities deduplicate
work, not PA calls.

Commands inspect data or replace RAM navigation; they never admit work. They may resolve approximate human references if
they report the resolved reference. Execution selectors remain application-defined. Prompt-free settings update a RAM
overlay; inquiry fields override it without consuming it. Reset clears navigation and overrides, not history or work.

`app/open` and `app/observe` are owner-only. Invocation context is opaque: applications save and echo it on output and
imported PA calls. Hosts authenticate its scope and recheck current grants; context is never a destination supplied by
model code.

## Notifications

Every `event.value` has `kind`, `stream`, `work`, and optional `context`:

| Kind      | Additional fields                    | Meaning                                       |
| --------- | ------------------------------------ | --------------------------------------------- |
| `delta`   | `item`, `output`                     | Volatile text fragment; no historical cursor  |
| `message` | `cursor`, `output`, optional `state` | One committed, immutable completed item       |
| `busy`    | boolean `value`                      | Work activity, suitable for typing indicators |

Output contains `type` (`response`, `reasoning`, `tool-call`, `tool-result`), `format` (`markdown`, `quote`, `code`,
`json`), `text`, and optional `language`. Completed output also has a stable `id`, optional `reply`, and optional
single-line `footer` of at most 1,000 characters. Delta `item` identifies that eventual completed output. A preview is
not a committed answer.

Hosts send at item completion, inquiry termination, or safe destination-size overflow. There is no timer-based content
flush. Formatting and footer overhead count toward limits; indivisible oversized content becomes an attachment. Footers
appear once at application loop/result boundaries, on the final fragment. Splitting and deltas do not create historical
events.

Deduplicate completed message IDs. Only exact admitted work may replace selected navigation; recursive work may inherit
routing without taking over navigation. Ending observation does not cancel work. Buffers, overlays, cursors and delivery
tracking are RAM-only; restart promises no delivery recovery. Attempts without receipts must not be automatically
repeated.
