![portable-agents](https://chaosdiscovery.s-ul.eu/Gtamrmmy)

[![Zig version](https://img.shields.io/badge/%20-0.16.0-black?style=flat-square&logo=zig&logoColor=black&labelColor=F7A41D)](https://github.com/darkhorseprojects/portable-agents/releases/latest)
[![JSR](https://img.shields.io/jsr/v/%40darkhorseprojects%2Fportable-agents?style=flat-square&label=%20&labelColor=F7DF1E&color=083344&logo=jsr&logoColor=083344)](https://jsr.io/@darkhorseprojects/portable-agents)

# Portable Agents

Portable Agents (PA) runs Lua and Markdown packages in isolated Lua 5.5 states.
Call packages through the `agent` CLI, Zig library, or Effect TypeScript SDK.
Packages define their own behavior and byte formats; PA does not supply a model.

## Requirements

Install `agent` and an architecture-compatible Lua 5.5 shared library:

| Platform | Library |
| --- | --- |
| Linux | `liblua5.5.so.0` |
| macOS | `@rpath/liblua.5.5.dylib` |
| Windows | `lua55.dll` |

Release archives do not include Lua. The SDK requires Deno or a compatible
TypeScript host with Effect 4.

## Run a package

Save this as `package/entry.lua`:

```lua
return setmetatable({}, {
    __call = function(_, input, config)
        return input
    end,
    __metatable = false,
})
```

Check it:

```sh
agent check package entry
```

Call it:

```sh
printf '%s\n' '{"version":2,"emits":false,"agents":[{"sourceDir":"package","entryModule":"entry"}],"input":"aGVsbG8=","config":"e30="}' | agent call
```

The terminal result contains `aGVsbG8=`, the base64 encoding of `hello`.
Input, config, and output are bytes. Your package defines their format.

## Write or embed packages

- [Package language](https://github.com/darkhorseprojects/portable-agents/wiki/Package-Language): Lua and Markdown modules
- [Embedding](https://github.com/darkhorseprojects/portable-agents/wiki/Embedding): CLI, Zig, and complete SDK examples
- [Host operations](https://github.com/darkhorseprojects/portable-agents/wiki/Host-Operations): filesystem, HTTP, and processes
- [Eval and Imports](https://github.com/darkhorseprojects/portable-agents/wiki/Eval-and-Imports): selected functions and agent grants
- [Runtime and authority](https://github.com/darkhorseprojects/portable-agents/wiki/Runtime-and-Authority): limits, ownership, and cancellation

Trusted package code and native modules have host authority. Restricted Eval
states do not make a malicious package safe.

## Build from source

Install Zig 0.16.x and Lua 5.5 development headers. Ensure `pkg-config` can find
`lua5.5`, then run:

```sh
zig build -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/agent`. See [Development](https://github.com/darkhorseprojects/portable-agents/wiki/Development)
for checks and cross-build settings.

License: [AGPL-3.0-only](LICENSE).
