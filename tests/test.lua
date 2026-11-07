-- Run from the repository root: luajit tests/test.lua (or lua tests/test.lua).
local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function capture(command)
  local pipe = assert(io.popen(command))
  local output = pipe:read("*a"):gsub("%s+$", "")
  pipe:close()
  return output
end

local project = capture("pwd")
local scratch = capture('mktemp -d "${TMPDIR:-/tmp}/lazy-rex-test.XXXXXX"')
assert(scratch ~= "", "cannot create test directory")
local sequence = 0
local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function raw_exec(argv, opts)
  opts = opts or {}
  sequence = sequence + 1
  local out, err = scratch .. "/stdout-" .. sequence, scratch .. "/stderr-" .. sequence
  local parts =
    { "env", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_ALLOW_PROTOCOL=file" }
  for key, value in pairs(opts.env or {}) do
    assert(value ~= false, "test runner does not need environment removal")
    parts[#parts + 1] = key .. "=" .. value
  end
  for _, arg in ipairs(argv) do
    parts[#parts + 1] = arg
  end
  for i, part in ipairs(parts) do
    parts[i] = quote(part)
  end
  local command = table.concat(parts, " ") .. " > " .. quote(out) .. " 2> " .. quote(err)
  if opts.cwd then
    command = "cd " .. quote(opts.cwd) .. " && " .. command
  end
  local result, _, code = os.execute(command)
  if type(result) == "number" then
    code = math.floor(result / 256)
  end
  return {
    ok = result == true or result == 0,
    code = code or 0,
    stdout = read(out) or "",
    stderr = read(err) or "",
  }
end

local function run(argv, opts)
  local result = raw_exec(argv, opts)
  assert(result.ok, table.concat(argv, " ") .. ": " .. result.stderr .. "\n" .. result.stdout)
  return result.stdout:gsub("%s+$", "")
end

local function write(path, content)
  run({ "mkdir", "-p", assert(path:match("^(.*)/[^/]+$")) })
  local file = assert(io.open(path, "w"))
  assert(file:write(content))
  assert(file:close())
end

local function commit(dir)
  run({ "git", "-C", dir, "add", "." })
  run({
    "git",
    "-c",
    "user.name=Test",
    "-c",
    "user.email=test@example.invalid",
    "-C",
    dir,
    "commit",
    "-m",
    "fixture",
  })
end

local plugin_source = [[
local M = {}
function M.setup(opts)
  _G.__lazy_rex_values = _G.__lazy_rex_values or {}
  table.insert(_G.__lazy_rex_values, opts)
  rex.action({ name = "fixture_action", title = "Fixture", run = function() return opts end })
end
return M
]]
local remote = scratch .. "/remote plugin"
write(remote .. "/lua/fixture_plugin/init.lua", plugin_source)
run({ "git", "init", "--initial-branch=main", remote })
commit(remote)
local manager_remote = scratch .. "/remote manager"
run({ "mkdir", "-p", manager_remote })
run({ "cp", "-R", project .. "/lua", manager_remote .. "/lua" })
run({ "git", "init", "--initial-branch=main", manager_remote })
commit(manager_remote)

local original_path = package.path
local getenv = os.getenv
local test_env, actions, logs, calls, override, case_dir, config_dir
local remotes = {
  ["https://github.com/acme/fixture.rex.git"] = remote,
  ["https://github.com/taterdoge/lazy.rex.git"] = manager_remote,
}
---@diagnostic disable-next-line: duplicate-set-field
os.getenv = function(name)
  if test_env and test_env[name] ~= nil then
    return test_env[name] ~= false and test_env[name] or nil
  end
  return getenv(name)
end

local function reload()
  local clear = {}
  for name in pairs(package.loaded) do
    if name == "lazy" or name:match("^lazy%.") or name:match("^fixture_") then
      clear[#clear + 1] = name
    end
  end
  for _, name in ipairs(clear) do
    package.loaded[name] = nil
  end
  package.path = project
    .. "/lua/?.lua;"
    .. project
    .. "/lua/?/init.lua;"
    .. config_dir
    .. "/?.lua;"
    .. config_dir
    .. "/?/init.lua;"
    .. original_path
  actions, logs, calls, override = {}, {}, {}, nil
  _G.__lazy_rex_values = {}
  _G.rex = {
    action = function(action)
      actions[action.name] = action.run
    end,
    log = function(level, message)
      logs[#logs + 1] = { level, message }
    end,
    exec = function(argv, opts)
      calls[#calls + 1] = { argv = argv, opts = opts }
      if override then
        return override(argv, opts)
      end
      local mapped = {}
      for i, arg in ipairs(argv) do
        if arg:match("^https://github.com/") then
          assert(remotes[arg], "network access forbidden in tests: " .. arg)
          mapped[i] = remotes[arg]
        else
          mapped[i] = arg
        end
      end
      return raw_exec(mapped, opts)
    end,
  }
end

local count, failures = 0, 0
local function test(name, fn)
  count = count + 1
  case_dir = scratch .. "/case " .. count
  config_dir = case_dir .. "/config"
  test_env = { HOME = case_dir .. "/home", XDG_DATA_HOME = case_dir .. "/data" }
  reload()
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
  else
    print("ok " .. name)
  end
end

local function expect_error(fn, message)
  local ok, err = pcall(fn)
  assert(not ok, "expected an error: " .. message)
  assert(tostring(err):find(message, 1, true), "unexpected error: " .. tostring(err))
end

local local_count = 0
local function local_plugin(name, layout)
  local_count = local_count + 1
  local main = "fixture_" .. local_count
  local dir = case_dir .. "/local " .. name
  write(dir .. "/" .. (layout or "lua") .. "/" .. main .. "/init.lua", plugin_source)
  return { "acme/" .. name, dir = dir, main = main, opts = { value = name } }
end

local function source(plugin)
  return string.format(
    "return { %q, dir = %q, main = %q, opts = { value = %q } }\n",
    plugin[1],
    plugin.dir,
    plugin.main,
    plugin.opts.value
  )
end

local function status(name)
  return actions.lazy_status()[name:match("[^/]+$")]
end

local function setup(specs, install)
  return require("lazy").setup(specs, { install = { missing = install } })
end

test("imports init, files and subdirectory init in deterministic order", function()
  write(config_dir .. "/plugins/init.lua", source(local_plugin("first")))
  write(config_dir .. "/plugins/b.lua", source(local_plugin("second")))
  write(config_dir .. "/plugins/z/init.lua", source(local_plugin("third")))
  write(config_dir .. "/plugins/z/helper.lua", "error('must not import helpers')")
  require("lazy").setup("plugins")
  for i, value in ipairs({ "first", "second", "third" }) do
    assert(_G.__lazy_rex_values[i].value == value)
  end
  assert(#_G.__lazy_rex_values == 3)
end)

test("accepts single file imports and repeated imports once", function()
  write(config_dir .. "/plugins.lua", source(local_plugin("single")))
  setup({ { import = "plugins" }, { import = "plugins" } })
  assert(#_G.__lazy_rex_values == 1)
end)

test("nested imports do not load the same file twice", function()
  write(config_dir .. "/plugins/init.lua", 'return { { import = "plugins.child" } }')
  write(config_dir .. "/plugins/child.lua", source(local_plugin("child")))
  setup({ { import = "plugins" } })
  assert(#_G.__lazy_rex_values == 1)
end)

test("empty plugin directory is valid", function()
  run({ "mkdir", "-p", config_dir .. "/plugins" })
  require("lazy").setup("plugins")
  assert(next(actions.lazy_status()) == nil)
end)

test("cyclic imports report their source", function()
  write(config_dir .. "/plugins/init.lua", 'return { import = "plugins" }')
  expect_error(function()
    require("lazy").setup("plugins")
  end, "cyclic import: plugins")
end)

test("missing imports fail before installing anything", function()
  expect_error(function()
    setup({ "acme/fixture.rex", { import = "missing" } })
  end, "import not found")
  assert(#calls == 0)
end)

test("broken plugin files fail with a file name", function()
  write(config_dir .. "/plugins/broken.lua", "this is not Lua")
  expect_error(function()
    require("lazy").setup("plugins")
  end, "broken.lua")
end)

test("plugin files must return a spec", function()
  write(config_dir .. "/plugins/empty.lua", "return nil")
  expect_error(function()
    require("lazy").setup("plugins")
  end, "empty.lua")
end)

local invalid = {
  { { "../escape" }, "invalid plugin" },
  { { "acme/demo", opts = false }, "opts must" },
  { { "acme/demo", enabled = "false" }, "enabled must" },
  { { "acme/demo", dir = "relative" }, "absolute path" },
  { { "acme/demo", path = "/a" }, "unsupported plugin option" },
  { { "acme/demo", config = false }, "config must" },
  { { "acme/demo", main = "../escape" }, "invalid main" },
  { { "acme/demo", main = "lazy.util" }, "reserved" },
  { { "acme/demo", event = "startup" }, "unsupported plugin option" },
  { { import = "../plugins" }, "invalid import" },
  { { import = "plugins", opts = {} }, "only accept" },
  { { unexpected = true }, "expected a list" },
  { { "acme/demo", dir = false }, "dir must" },
  { { "acme/demo", main = false }, "invalid main" },
  { { "acme/demo", name = false }, "invalid plugin name" },
  { { "acme/demo", url = false }, "url must" },
  { { "acme/demo", init = false }, "init must" },
  { {
    "acme/demo",
    enabled = function()
      return nil
    end,
  }, "enabled() must" },
}
for i, item in ipairs(invalid) do
  test("rejects invalid spec " .. i, function()
    expect_error(function()
      setup({ item[1] })
    end, item[2])
    assert(#calls == 0)
  end)
end

test("duplicate plugin names require an explicit name", function()
  expect_error(function()
    setup({ "acme/demo", "acme/demo" })
  end, "duplicate plugin name")
  expect_error(function()
    setup({ "acme/demo", "other/demo" })
  end, "duplicate plugin name")
  assert(#calls == 0)
end)

test("cyclic Lua spec lists are rejected", function()
  local list = {}
  list[1] = list
  expect_error(function()
    setup(list)
  end, "cyclic spec list")
end)

test("missing plugins install automatically before setup", function()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = { value = 42 } } })
  assert(status("acme/fixture.rex").loaded == "loaded", status("acme/fixture.rex").error)
  assert(_G.__lazy_rex_values[1].value == 42)
  assert(calls[1].opts.timeout <= 20)
  assert(calls[1].opts.env.GIT_TERMINAL_PROMPT == "0")
  reload()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  assert(#calls == 0, "existing plugins must not fetch on startup")
end)

test("manual install requires reload before running plugin setup", function()
  local specs = { { "acme/fixture.rex", main = "fixture_plugin", opts = {} } }
  setup(specs, false)
  assert(status("acme/fixture.rex").loaded == "missing")
  assert(#calls == 0)
  assert(actions.lazy_install(nil, {}).reload == "rex config reload")
  assert(status("acme/fixture.rex").installed)
  assert(#_G.__lazy_rex_values == 0)
  reload()
  setup(specs, false)
  assert(status("acme/fixture.rex").loaded == "loaded")
end)

test("local dir plugins are loaded and never managed", function()
  local plugin = local_plugin("local")
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded")
  assert(next(actions.lazy_update(nil, {}).plugins) == nil)
  expect_error(function()
    actions.lazy_install(nil, { plugin = plugin[1]:match("[^/]+$") })
  end, "externally managed")
  expect_error(function()
    actions.lazy_install(nil, { plugin = "unknown/name" })
  end, "unknown plugin")
  assert(#calls == 0)
end)

test("disabled plugins neither load nor install", function()
  setup({ { "acme/not-installed", enabled = false } })
  assert(status("acme/not-installed").loaded == "disabled")
  expect_error(function()
    actions.lazy_install(nil, { plugin = "not-installed" })
  end, "disabled")
  assert(#calls == 0)
end)

test("main is inferred from the only Lua module", function()
  local plugin = local_plugin("default.rex")
  plugin[1] = "acme/" .. plugin.main .. ".rex"
  local main = plugin.main
  plugin.main = nil
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded", main)
end)

test("rex layout loads with an explicit main", function()
  local plugin = local_plugin("rex-explicit", "rex/lua")
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded", status(plugin[1]).error)
  assert(_G.__lazy_rex_values[1].value == "rex-explicit")
end)

test("rex layout main is inferred and setup receives opts", function()
  local plugin = local_plugin("rex-inferred", "rex/lua")
  plugin.main = nil
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded", status(plugin[1]).error)
  assert(_G.__lazy_rex_values[1].value == "rex-inferred")
end)

test("rex layout submodules are requireable from a custom config", function()
  local plugin = local_plugin("rex-submodule", "rex/lua")
  write(plugin.dir .. "/rex/lua/" .. plugin.main .. "/extra.lua", "return 19")
  plugin.config = function(p, opts)
    assert(p.name == plugin[1]:match("[^/]+$") and opts.value == "rex-submodule")
    assert(require(p.main .. ".extra") == 19)
  end
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded")
  assert(#_G.__lazy_rex_values == 0)
end)

test("rex layout takes precedence without mixing roots", function()
  local plugin = local_plugin("rex-priority", "rex/lua")
  write(plugin.dir .. "/lua/" .. plugin.main .. "/init.lua", "error('native path must not load')")
  write(plugin.dir .. "/lua/native_only.lua", "return 23")
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded", status(plugin[1]).error)
  assert(not package.path:find(plugin.dir .. "/lua", 1, true), "native root was added")
  assert(not pcall(require, "native_only"), "native-only module must not be requireable")
end)

test("empty or broken rex layouts do not fall back to lua", function()
  local empty = local_plugin("rex-empty", "rex/lua")
  write(empty.dir .. "/lua/" .. empty.main .. "/init.lua", plugin_source)
  run({ "rm", empty.dir .. "/rex/lua/" .. empty.main .. "/init.lua" })
  empty.main = nil
  local broken = local_plugin("rex-broken", "rex/lua")
  write(broken.dir .. "/lua/" .. broken.main .. "/init.lua", plugin_source)
  run({ "rm", broken.dir .. "/rex/lua/" .. broken.main .. "/init.lua" })
  setup({ empty, broken })
  assert(status(empty[1]).loaded == "error")
  assert(status(empty[1]).error:find("cannot infer main", 1, true))
  assert(status(broken[1]).loaded == "error")
  assert(status(broken[1]).error:find("not found", 1, true))
end)

test("lua layout remains the fallback when rex layout is absent", function()
  local plugin = local_plugin("lua-fallback")
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded", status(plugin[1]).error)
  assert(_G.__lazy_rex_values[1].value == "lua-fallback")
end)

test("custom config receives plugin and opts and can require submodules", function()
  local plugin = local_plugin("callback")
  write(plugin.dir .. "/lua/" .. plugin.main .. "/extra.lua", "return 19")
  plugin.config = function(p, opts)
    assert(p.name == plugin[1]:match("[^/]+$") and opts.value == "callback")
    assert(require(p.main .. ".extra") == 19)
  end
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded")
  assert(#_G.__lazy_rex_values == 0)
end)

test("standard package.loaded caching is respected", function()
  local plugin = local_plugin("cached")
  local called = false
  package.loaded[plugin.main] = {
    setup = function()
      called = true
    end,
  }
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded" and called)
end)

test("module resolution follows the normal package.path", function()
  local plugin = local_plugin("missing")
  run({ "rm", plugin.dir .. "/lua/" .. plugin.main .. "/init.lua" })
  write(config_dir .. "/" .. plugin.main .. ".lua", plugin_source)
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded")
  assert(#_G.__lazy_rex_values == 1)
end)

test("one broken setup does not stop other plugins", function()
  local broken, good = local_plugin("broken"), local_plugin("good")
  write(
    broken.dir .. "/lua/" .. broken.main .. "/init.lua",
    "return { setup = function() error('broken setup') end }"
  )
  setup({ broken, good })
  assert(status(broken[1]).loaded == "error")
  assert(status(good[1]).loaded == "loaded")
  assert(#logs == 1)
end)

test("updates fast-forward but never overwrite dirty checkouts", function()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  local dir = status("acme/fixture.rex").dir
  write(remote .. "/new-file", "upstream")
  commit(remote)
  actions.lazy_update(nil, { plugin = "fixture.rex" })
  assert(read(dir .. "/new-file") == "upstream")
  write(dir .. "/new-file", "local edits")
  expect_error(function()
    actions.lazy_update(nil, {})
  end, "dirty checkout")
  assert(read(dir .. "/new-file") == "local edits")
end)

test("origin mismatches refuse updates", function()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  run({
    "git",
    "-C",
    status("acme/fixture.rex").dir,
    "remote",
    "set-url",
    "origin",
    "/different/repository",
  })
  expect_error(function()
    actions.lazy_update(nil, {})
  end, "origin URL differs")
end)

test("diverged histories refuse updates without resetting local commits", function()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  local dir = status("acme/fixture.rex").dir
  write(dir .. "/local-only", "keep")
  commit(dir)
  local head = run({ "git", "-C", dir, "rev-parse", "HEAD" })
  write(remote .. "/upstream-only", "remote")
  commit(remote)
  expect_error(function()
    actions.lazy_update(nil, {})
  end, "Not possible to fast-forward")
  assert(run({ "git", "-C", dir, "rev-parse", "HEAD" }) == head)
  assert(read(dir .. "/local-only") == "keep")
end)

test("failed installs clean only their staging directory", function()
  remotes["https://github.com/acme/failure.git"] = scratch .. "/missing remote"
  setup({ { "acme/failure", main = "fixture_failure" } })
  local state = status("acme/failure")
  assert(state.loaded == "error" and not state.installed)
  assert(not require("lazy.util").exists(state.dir .. ".lazy-rex-lock"))
  assert(not require("lazy.util").exists(state.dir))
end)

test("existing non-Git directories are never overwritten", function()
  local dir = test_env.XDG_DATA_HOME .. "/rex/lazy/fixture.rex"
  write(dir .. "/keep", "user data")
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  assert(status("acme/fixture.rex").error:find("refusing to overwrite", 1, true))
  assert(read(dir .. "/keep") == "user data")
end)

test("an existing install lock is not stolen or deleted", function()
  local dir = test_env.XDG_DATA_HOME .. "/rex/lazy/fixture.rex"
  write(dir .. ".lazy-rex-lock/keep", "another installation")
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  assert(status("acme/fixture.rex").error:find("busy", 1, true))
  assert(read(dir .. ".lazy-rex-lock/keep") == "another installation")
end)

test("expired action budgets do not start commands", function()
  local plugin = require("lazy.spec").collect({ "acme/fixture.rex" }, "/tmp/plugins")[1]
  expect_error(function()
    require("lazy.git").manage(plugin, "install", os.time() - 1)
  end, "time budget exhausted")
  assert(#calls == 0)
end)

test("exec startup failures and timeouts are not treated as success", function()
  override = function()
    return nil, "program not found"
  end
  expect_error(function()
    require("lazy.util").run({ "missing" })
  end, "program not found")
  override = function()
    return { ok = false, timed_out = true, stderr = "" }
  end
  expect_error(function()
    require("lazy.util").run({ "slow" })
  end, "timed out")
end)

test("data paths respect XDG and fall back to HOME", function()
  assert(require("lazy.util").data_dir() == test_env.XDG_DATA_HOME)
  test_env.XDG_DATA_HOME = ""
  assert(require("lazy.util").data_dir() == test_env.HOME .. "/.local/share")
  test_env.XDG_DATA_HOME = "relative"
  expect_error(function()
    require("lazy.util").data_dir()
  end, "must be absolute")
end)

test("setup options and repeated setup are validated", function()
  expect_error(function()
    require("lazy").setup({ root = "relative", spec = {} })
  end, "must be absolute")
  expect_error(function()
    require("lazy").setup({ install = "manual", spec = {} })
  end, "install must")
  expect_error(function()
    require("lazy").setup({ spec = {}, unknown = true })
  end, "unsupported setup option")
  setup({})
  expect_error(function()
    setup({})
  end, "only run once")
end)

test("bootstrap installs manager once and imports the config directory", function()
  write(config_dir .. "/plugins/a.lua", source(local_plugin("bootstrapped")))
  dofile(project .. "/examples/lua/config/lazy.lua")
  assert(read(test_env.XDG_DATA_HOME .. "/rex/lazy/lazy.rex/lua/lazy/init.lua"))
  assert(_G.__lazy_rex_values[1].value == "bootstrapped")
  reload()
  dofile(project .. "/examples/lua/config/lazy.lua")
  for _, call in ipairs(calls) do
    assert(call.argv[1] ~= "sh", "installed manager must not clone again")
  end
end)

test("bootstrap failures preserve incomplete existing installations", function()
  local path = test_env.XDG_DATA_HOME .. "/rex/lazy/lazy.rex"
  write(path .. "/keep", "user data")
  expect_error(function()
    dofile(project .. "/examples/lua/config/lazy.lua")
  end, "Failed to bootstrap")
  assert(read(path .. "/keep") == "user data")
  assert(not read(path .. "/lua/lazy/init.lua"))
end)

test("bootstrap reports unavailable Git without continuing to setup", function()
  override = function()
    return nil, "git unavailable"
  end
  expect_error(function()
    dofile(project .. "/examples/lua/config/lazy.lua")
  end, "git unavailable")
  assert(next(actions) == nil)
end)

test("no plugins directory is implicitly required", function()
  write(config_dir .. "/plugins/broken.lua", "error('must not import implicitly')")
  require("lazy").setup()
  assert(next(actions.lazy_status()) == nil and #calls == 0)
end)

test("imports use arbitrary namespaces and configured Lua search roots", function()
  local first, second = local_plugin("custom-one"), local_plugin("custom-two")
  write(config_dir .. "/bundles/terminal.lua", source(first))
  write(config_dir .. "/lua/extensions/other.lua", source(second))
  package.path = config_dir .. "/lua/?.lua;" .. config_dir .. "/lua/?/init.lua;" .. package.path
  require("lazy").setup({ { import = "bundles" }, { import = "extensions" } })
  assert(status(first[1]).loaded == "loaded" and status(second[1]).loaded == "loaded")
end)

test("a local plugin only needs dir and an optional name", function()
  local plugin = local_plugin("directory")
  plugin[1], plugin.name = nil, "directory"
  setup({ plugin })
  assert(status("directory").loaded == "loaded" and #calls == 0)
end)

test("custom Git URLs and explicit names use root/name", function()
  local root = case_dir .. "/custom root"
  require("lazy").setup(
    { { url = remote, name = "custom", main = "fixture_plugin", opts = {} } },
    { root = root }
  )
  assert(status("custom").dir == root .. "/custom")
  assert(status("custom").loaded == "loaded")
end)

test("unconfigured plugins only become available to require", function()
  local plugin = local_plugin("no-setup")
  plugin.opts = nil
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded")
  assert(package.loaded[plugin.main] == nil and #_G.__lazy_rex_values == 0)
  assert(type(require(plugin.main).setup) == "function")
end)

test("config=true calls setup with empty opts", function()
  local plugin = local_plugin("config-true")
  plugin.opts, plugin.config = nil, true
  setup({ plugin })
  assert(status(plugin[1]).loaded == "loaded" and next(_G.__lazy_rex_values[1]) == nil)
end)

test("opts functions can mutate opts or return a replacement", function()
  local first, second = local_plugin("mutate"), local_plugin("replace")
  first.opts = function(plugin, opts)
    assert(plugin.name == "mutate")
    opts.value = 11
  end
  second.opts = function()
    return { value = 12 }
  end
  setup({ first, second })
  assert(_G.__lazy_rex_values[1].value == 11 and _G.__lazy_rex_values[2].value == 12)
end)

test("invalid opts function results are reported", function()
  local plugin = local_plugin("bad-opts")
  plugin.opts = function()
    return false
  end
  setup({ plugin })
  assert(status(plugin[1]).error:find("opts() must return", 1, true))
end)

test("all init callbacks run before any config callback", function()
  local first, second = local_plugin("init-first"), local_plugin("init-second")
  local trace = {}
  for _, plugin in ipairs({ first, second }) do
    plugin.init = function(p)
      trace[#trace + 1] = "init:" .. p.name
    end
    plugin.config = function(p)
      trace[#trace + 1] = "config:" .. p.name
    end
  end
  setup({ first, second })
  assert(
    table.concat(trace, ",")
      == "init:init-first,init:init-second,config:init-first,config:init-second"
  )
end)

test("enabled functions skip disabled plugins", function()
  setup({ {
    "acme/disabled",
    enabled = function()
      return false
    end,
  } })
  assert(status("disabled").loaded == "disabled" and #calls == 0)
end)

test("main inference matches normalized plugin names among multiple modules", function()
  local plugin = local_plugin("named")
  plugin.name, plugin.main = plugin.main .. ".rex", nil
  write(plugin.dir .. "/lua/another.lua", "return {}")
  setup({ plugin })
  assert(status(plugin.name).loaded == "loaded", status(plugin.name).error)
end)

test("ambiguous main inference requires an explicit main", function()
  local plugin = local_plugin("ambiguous")
  plugin.main = nil
  write(plugin.dir .. "/lua/another.lua", "return {}")
  setup({ plugin })
  assert(status(plugin[1]).error:find("set main", 1, true))
end)

test("updates respect Git URL rewrite configuration", function()
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  override = function(argv, opts)
    local mapped = {}
    for i, arg in ipairs(argv) do
      mapped[i] = remotes[arg] or arg
    end
    opts.env.GIT_CONFIG_COUNT = "1"
    opts.env.GIT_CONFIG_KEY_0 = "url.file://" .. remote .. ".insteadOf"
    opts.env.GIT_CONFIG_VALUE_0 = remote
    return raw_exec(mapped, opts)
  end
  actions.lazy_update(nil, { plugin = "fixture.rex" })
end)

test("dangling plugin symlinks are never replaced", function()
  local dir = test_env.XDG_DATA_HOME .. "/rex/lazy/fixture.rex"
  run({ "mkdir", "-p", dir:match("^(.*)/[^/]+$") })
  run({ "ln", "-s", case_dir .. "/missing-target", dir })
  setup({ { "acme/fixture.rex", main = "fixture_plugin", opts = {} } })
  assert(status("fixture.rex").error:find("refusing to overwrite", 1, true))
  run({ "test", "-L", dir })
end)

test("dangling manager symlinks are never replaced", function()
  local dir = test_env.XDG_DATA_HOME .. "/rex/lazy/lazy.rex"
  run({ "mkdir", "-p", dir:match("^(.*)/[^/]+$") })
  run({ "ln", "-s", case_dir .. "/missing-target", dir })
  expect_error(function()
    dofile(project .. "/examples/lua/config/lazy.lua")
  end, "Failed to bootstrap")
  run({ "test", "-L", dir })
end)

test("empty HOME cannot select a directory below filesystem root", function()
  test_env.XDG_DATA_HOME, test_env.HOME = false, ""
  expect_error(function()
    require("lazy.util").data_dir()
  end, "HOME is not set")
  expect_error(function()
    dofile(project .. "/examples/lua/config/lazy.lua")
  end, "HOME is not set")
  assert(#calls == 0)
end)

test("sparse spec lists cannot silently drop plugins", function()
  local list = { { "acme/one" }, nil, { "acme/three" }, { "acme/four" } }
  expect_error(function()
    setup(list)
  end, "list of plugin specs")
  assert(#calls == 0)
end)

test("bootstrap rejects the wrong repository and cleans staging", function()
  local url = "https://github.com/taterdoge/lazy.rex.git"
  local original = remotes[url]
  remotes[url] = remote
  local ok, err = pcall(dofile, project .. "/examples/lua/config/lazy.lua")
  remotes[url] = original
  assert(not ok and tostring(err):find("missing lua/lazy/init.lua", 1, true))
  local path = test_env.XDG_DATA_HOME .. "/rex/lazy/lazy.rex"
  assert(not require("lazy.util").exists(path))
  assert(not require("lazy.util").exists(path .. ".lazy-rex-lock"))
end)

if raw_exec({ "sh", "-c", "command -v rex" }).ok then
  test("real Rex boots from local Git remotes and checks again offline", function()
    write(config_dir .. "/init.lua", assert(read(project .. "/examples/init.lua")))
    write(
      config_dir .. "/lua/config/lazy.lua",
      assert(read(project .. "/examples/lua/config/lazy.lua"))
    )
    write(
      config_dir .. "/lua/plugins/fixture.lua",
      'return { "acme/fixture.rex", main = "fixture_plugin", opts = { value = 17 } }'
    )
    local env = {
      XDG_DATA_HOME = test_env.XDG_DATA_HOME,
      GIT_CONFIG_COUNT = "2",
      GIT_CONFIG_KEY_0 = "url.file://" .. manager_remote .. ".insteadOf",
      GIT_CONFIG_VALUE_0 = "https://github.com/taterdoge/lazy.rex.git",
      GIT_CONFIG_KEY_1 = "url.file://" .. remote .. ".insteadOf",
      GIT_CONFIG_VALUE_1 = "https://github.com/acme/fixture.rex.git",
    }
    local output = run(
      { "rex", "--autostart=false", "config", "check", config_dir .. "/init.lua", "--json" },
      { env = env }
    )
    for _, name in ipairs({ "lazy_install", "lazy_update", "lazy_status", "fixture_action" }) do
      assert(output:find(name, 1, true), output)
    end
    assert(not output:find('"severity"%s*:%s*"error"'), output)
    assert(read(test_env.XDG_DATA_HOME .. "/rex/lazy/lazy.rex/.git/HEAD"))
    assert(read(test_env.XDG_DATA_HOME .. "/rex/lazy/fixture.rex/.git/HEAD"))
    env.GIT_CONFIG_COUNT = "0"
    run(
      { "rex", "--autostart=false", "config", "check", config_dir .. "/init.lua", "--json" },
      { env = env }
    )
  end)
else
  print("skip real Rex check: rex is not installed")
end

os.getenv = getenv
run({ "rm", "-rf", scratch })
assert(failures == 0, failures .. " tests failed")
print(count .. " tests passed")
