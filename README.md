# lazy.rex

English | [简体中文](README.zh-CN.md)

A Rex plugin manager inspired by lazy.nvim's configuration model: declarative specs, Lua module imports, and self-installation on first startup.
It does not depend on Neovim or another Rex plugin manager.

**You choose the directory structure.** `config`, `plugins`, and `lua` are not reserved directories.
`import` searches for modules through `package.path`; no plugins are imported when no spec is provided.

The current implementation focuses on configuration organization and the installation lifecycle; **it is not a complete port of lazy.nvim**.
Supported options are listed below. Unsupported options raise an error instead of being silently ignored.

## Requirements

- Rex, providing Lua 5.1, `rex.exec`, `rex.action`, and `rex.log`.
- macOS or Linux, with Git, a POSIX shell, `find`, `mkdir`, `mv`, and `rm`.
- Installation runs on the machine hosting the Rex server, not the remote client.

Rex prohibits `os.execute` and `io.popen`; all external commands at runtime use `rex.exec`.
Standalone test scripts are not subject to this restriction.

## Bootstrapping

The complete bootstrap code is in [`examples/lua/config/lazy.lua`](examples/lua/config/lazy.lua).
Place it in your configuration module and load it from `init.lua`.

If the manager is missing, the bootstrap code clones it with Git, adds it to the Lua search path, and calls `setup`.
Once installed, it does not contact the network or update automatically.

The example uses `https://github.com/taterdoge/lazy.rex.git` as its remote.

### An optional layout

This is only a configuration style, not a directory requirement:

```text
~/.config/rex/
├── init.lua
└── lua/
    ├── config/
    │   └── lazy.lua
    └── plugins/
        └── smart-title.lua
```

The corresponding entry point in [`examples/init.lua`](examples/init.lua):

```lua
-- Rex has already prepended the actual config directory to package.path.
local config = assert(package.path:match("^(.-)%?%.lua;"))
package.path = config .. "lua/?.lua;" .. config .. "lua/?/init.lua;" .. package.path
require("config.lazy")
```

This follows the configuration directory actually loaded by Rex, supports `REX_CONFIG` and `XDG_CONFIG_HOME`,
and also works with `rex config check /other/path/init.lua` without hard-coding `~/.config/rex`.
Keep your existing `rex.bind(...)` calls; do not replace your entire `init.lua` with the example.

You can also put modules in `extensions/` at the configuration root, or use a namespace such as `bundles.terminal`.
As long as the corresponding root directory is in `package.path`, specify the matching `import`.
The bootstrap code can also go directly into `init.lua`; `config.lazy` is not required.

### Local development entry point

To use a local checkout, temporarily replace the bootstrap module contents with the following code. Adjust the development path to match your setup:

```lua
local dev = assert(os.getenv("HOME")) .. "/Project/lazy.rex"
package.path = dev .. "/lua/?.lua;" .. dev .. "/lua/?/init.lua;" .. package.path
require("lazy").setup("plugins")
```

This loads the implementation from the local repository without copying or modifying your configuration.
Here, `plugins` is still only an explicitly specified module name.

## setup

Three forms:

```lua
require("lazy").setup("plugins")
```

```lua
require("lazy").setup({
  { import = "plugins" },
  { import = "bundles.terminal" },
}, {
  install = { missing = true },
})
```

```lua
require("lazy").setup({
  spec = { { import = "plugins" } },
  install = { missing = false }, -- Only load installed plugins; install missing ones manually.
})
```

| Option | Default | Description |
| --- | --- | --- |
| `spec` | Empty | A plugin spec, a list of specs, or an import; may also be passed as the first argument |
| `root` | `$XDG_DATA_HOME/rex/lazy`, or `~/.local/share/rex/lazy` | Plugin installation root; must be an absolute path |
| `install.missing` | `true` | Install missing plugins when the configuration loads |

Call `setup` only once per Rex configuration load.
By default, the manager is installed at `<data directory>/rex/lazy/lazy.rex`; regular plugins are installed at `<root>/<name>`.
Changing `root` does not move the manager automatically; `lazypath` in the bootstrap module specifies its location separately.

### import

`{ import = "plugins" }` imports the following, when found:

- `plugins.lua`.
- `plugins/init.lua`.
- `plugins/*.lua`.
- `plugins/*/init.lua`.

`plugins.lua` is read first, followed by directory contents sorted by module name, with `init.lua` first.
Files are not read recursively at arbitrary depths; add deeper levels with explicit `import` entries.
An imported file at the same path is not executed twice; circular imports, syntax errors, and invalid return values report the source file.
An empty directory or `return {}` can represent an empty spec; a missing import module raises an error.

A plugin file returns one spec or a list of specs:

```lua
return {
  "taterdoge/smart-title-rex",
  main = "smart-title-rex",
  opts = {
    api_key = os.getenv("OPENAI_API_KEY") or "",
    model = "gpt-4o-mini",
  },
}
```

Installation starts only after all specs have been validated.
Duplicate plugin names raise an error; use `name` to distinguish identically named plugins from different repositories.
Duplicate declarations are not currently merged.

## Plugin spec

| Field | Type | Description |
| --- | --- | --- |
| `[1]` | string | `owner/repo`, a full Git URL, or a local absolute path |
| `dir` | string | Absolute path to a local plugin; not installed or updated by the manager |
| `url` | string | Custom Git URL, as an alternative to `[1]` |
| `name` | string | Plugin name and installation directory name; defaults to the last source path component without `.git` |
| `enabled` | boolean / function | Skip installation and loading when `false` or when the function returns `false` |
| `init` | function(plugin) | Startup initialization; all `init` functions run before any `config` |
| `opts` | table / function(plugin, opts) | Passed to the default `setup`; the function can modify opts or return a replacement table |
| `main` | string | Lua module to load for the default `setup`; may be specified explicitly |
| `config` | true / function(plugin, opts) | `true` calls the default `setup`; a function replaces the default behavior |

At least one of `[1]`, `dir`, or `url` is required. Paths do not expand `~`.
Using only `dir` is valid; set a valid `name` if its last component contains special characters.
Plugin names may contain only letters, digits, underscores, dots, and hyphens; they cannot be `.`, `..`, or `lazy.rex`.
The `lazy` Lua namespace is reserved for the manager.

```lua
return {
  dir = "/absolute/path/to/my-plugin",
  name = "my-plugin",
  opts = function(plugin, opts)
    opts.message = plugin.name
  end,
}
```

### Loading semantics

Plugins may use a Rex-specific `rex/lua/` layout or the standard `lua/` layout:

```text
my-plugin/
├── rex/lua/          -- preferred when this directory exists
│   └── my-plugin/
│       └── init.lua
└── lua/              -- fallback, or a standard Lua module layout
    └── my-plugin/
        └── init.lua
```

The manager chooses exactly one root per plugin: `rex/lua/` when that directory exists, otherwise `lua/`.
It adds `<root>/?.lua` and `<root>/?/init.lua` from the selected root to `package.path` and uses the same root for `main` inference; the roots are never mixed.
An empty or broken `rex/lua/` does not silently fall back to `lua/`.
It does not take over `require`; standard Lua search order and `package.loaded` behavior are preserved.
Module names are shared, so plugin authors should avoid naming conflicts.

As with lazy.nvim, **the default `setup(opts)` is called automatically only when `opts` or `config = true` is present**.
A plugin without `opts/config` is only added to the search path and can be required manually by other modules.

When `main` is not specified, the manager first matches names after removing separators and Lua/Rex prefixes and suffixes.
Otherwise, it uses a top-level Lua module only if there is exactly one; if the module cannot be determined, `main` must be set explicitly.
A custom `config` does not require the plugin to export `setup`.

Installation, initialization, or configuration failures for an individual plugin are recorded in logs and status without blocking other plugins.
Plugin spec or import errors, however, cause configuration loading to fail.

## Rex actions

```sh
rex do lazy_status
rex --timeout 30s do lazy_install
rex --timeout 30s do lazy_update plugin=smart-title-rex
rex --timeout 60s config reload
```

- `lazy_install`: install missing plugins; do not replace existing checkouts.
- `lazy_update`: run `git pull --ff-only` only on clean checkouts.
- `lazy_status`: return directory, enabled state, installation state, loading state, and loading errors; no network access.

`plugin` takes the short plugin name or custom `name`, not `owner/repo`.
Without `plugin`, the action handles all enabled, manager-managed plugins and skips local plugins.
Explicitly specifying an unknown, disabled, or local plugin raises an error.
Install and update actions do not immediately run plugin configuration; reload the Rex configuration afterward.

## Security and limitations

- First-time bootstrapping and missing-plugin installation access the network and wait synchronously; installed plugins are not fetched at startup.
- **`rex config check` also runs the bootstrap and automatic installation.** It is not a read-only mode for this manager.
  When the manager is already installed, `install = { missing = false }` disables installation of regular plugins during the check.
- Bootstrapping waits at most 20 seconds; each plugin installation round or action shares a 20-second budget.
  If the budget is exceeded, retry or use `plugin=name` to process plugins in batches.
- Git interactive credential prompts are disabled; configure credentials for non-interactive use in advance.
- Cloning uses a lock directory and a temporary checkout, then moves the completed checkout to its destination.
  It does not overwrite non-Git directories, leftover directories, or broken symbolic links.
- Updates reject local modifications, untracked files, a different origin, and non-fast-forward history; they do not reset, clean, or force-push.
- An interrupted operation may leave a `<directory>.lazy-rex-lock`. Handle it manually only after confirming that no installation or update is running.
- Plugins are trusted Lua code with Rex server permissions, not sandboxed code.
- There is currently no event/key/require-triggered lazy loading, dependency resolution, version constraints, lockfile, UI, automatic cleanup, or automatic configuration watching.
  Imported modules are initialized during configuration loading; run `rex config reload` after changing declarations.

## Verification

Run from the repository root:

```sh
luajit "tests/test.lua"
# or
lua "tests/test.lua"

stylua --check "lua" "examples" "tests"
```

Tests use local Git repositories and disable network protocols. They cover imports, spec validation, lifecycle, installation, updates, and failure safeguards.
When Rex is installed, they also check the full self-installation flow with a temporary configuration and a subsequent offline reload; they do not reload your running configuration.
When Rex is not installed, this integration check is explicitly skipped.

Design reference: [lazy.nvim](https://github.com/folke/lazy.nvim).
Rex interfaces: [configuration file](https://www.superlogical.com/rex/docs/customize/config),
[Lua API](https://www.superlogical.com/rex/docs/reference/lua).
