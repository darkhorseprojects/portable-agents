# Portable Agents

Portable Agents supplies bounded process framing and envelopes. Applications own processes, authority, execution,
delivery and persistence. See [the specification](spec.md).

TypeScript exports `Message`, `encode(message, maximumBytes)` and `decode(readable, maximumBytes)` from `sdk/mod.ts`.
Decode yields complete envelopes immediately on a live connection. The connection owner checks readiness and correlates
overlapping calls in both directions by their connection-local IDs. `ready.handle` and `call.caller` identify authors,
not credentials. Calls may carry a flat `imports` documentation map; applications retain routing and authority.

PA is a library, not an installed agent. Install the local Janet checkout with JPM, using its configured system or user
module directory:

```sh
cd /path/to/portable-agents
jpm deps
jpm install
```

JPM installs PA and its declared dependencies. Do not copy PA into an agent or use another application's dependency
tree. Standard JPM module-path configuration applies on Linux, macOS and Windows.

```janet
(import pa)
(def pending @"")
(def call (pa/read stdin pending 1048576))
(pa/write stdout {:type "result" :id (call :id) :value :null} 1048576)
```

`pa/read` accepts a file or readable stream and a connection-local buffer. It returns nil at clean EOF; `pa/write`
accepts a writable file or stream. Both validate envelopes, UTF-8 and frame bounds. Blocking file IO belongs on an IO
thread when an application also runs an event loop.

Neither implementation owns a scheduler, database, installer or process manager. Deno uses its normal package cache for
the TypeScript module; JPM uses its normal installation paths for Janet.

## Filesystem conventions

PA adopts the home-directory `.agents` convention for user agent installations:

| Platform                     | Agent root                                |
| ---------------------------- | ----------------------------------------- |
| Linux and other Unix systems | `~/.agents/`                              |
| macOS                        | `~/.agents/`                              |
| Windows                      | `%USERPROFILE%\.agents\`                  |
| WSL                          | `~/.agents/` in the WSL user's Linux home |

Install each agent in its own named directory, such as `~/.agents/zinc/`. That directory contains the agent's entry
source, supporting modules, resources, configuration and private instance state. Its name does not define its durable
author handle.

The `.agents` location is an emerging cross-tool convention, not an OS-defined directory or a claim of compatibility
with another project's contents. See the [.agents draft](https://dotagentsprotocol.com/) and
[Warp's documented locations](https://docs.warp.dev/terminal/settings/file-locations/).

Only agent installations belong in this root. Shared runtimes, libraries, package caches and host executables remain in
their normal OS or package-manager paths. Do not install Janet, a JPM dependency tree, the PA library or Connector
there.

PA defines no skills format, discovery mechanism or directory hierarchy. Users may add their own conventions; those
conventions are outside PA.

For files outside an agent installation, use the platform's normal locations:

| Purpose                  | Linux                                        | macOS                                            | Windows                                                                                 |
| ------------------------ | -------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------- |
| Configuration            | `$XDG_CONFIG_HOME`, normally `~/.config`     | Application Support or platform preferences APIs | `%APPDATA%` for roaming configuration; `%LOCALAPPDATA%` for machine-local configuration |
| Durable application data | `$XDG_DATA_HOME`, normally `~/.local/share`  | `~/Library/Application Support`                  | `%APPDATA%` or `%LOCALAPPDATA%`, according to portability                               |
| State                    | `$XDG_STATE_HOME`, normally `~/.local/state` | Application Support; logs under `~/Library/Logs` | `%LOCALAPPDATA%`                                                                        |
| Cache                    | `$XDG_CACHE_HOME`, normally `~/.cache`       | `~/Library/Caches`                               | An application-specific cache under `%LOCALAPPDATA%`                                    |

Executables and language libraries use their package manager's configured installation prefix. On Linux, user
executables commonly use `~/.local/bin`. Janet libraries use JPM's configured module directory; PA does not override it.

References: [XDG](https://specifications.freedesktop.org/basedir/latest/),
[macOS Library directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html),
[Windows Known Folders](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid),
[JPM custom trees](https://www.janet-lang.org/jpm/local-install.html).

Run `deno task check` for formatting, lint and TypeScript checks.
