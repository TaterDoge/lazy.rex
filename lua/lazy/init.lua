local util = require("lazy.util")
local spec = require("lazy.spec")
local git = require("lazy.git")
local loader = require("lazy.loader")
local M = {}
local configured = false

local function installed(plugin)
  return util.exists(plugin.dir .. (plugin.managed and "/.git/HEAD" or ""))
end

local function attempt(plugin, fn)
  local ok, err = pcall(fn)
  if not ok then
    plugin.load_status = plugin.load_status == "missing" and "missing" or "error"
    plugin.load_error = tostring(err)
    rex.log("error", "lazy.rex: " .. plugin.name .. ": " .. plugin.load_error)
  end
end

function M.setup(plugins, config)
  assert(not configured, "lazy.rex.setup must only run once per config load")
  if type(plugins) == "table" and plugins.spec ~= nil then
    assert(config == nil, "pass setup options once")
    config, plugins = plugins, plugins.spec
  end
  config = config == nil and {} or config
  assert(type(config) == "table", "setup options must be a table")
  for key in pairs(config) do
    assert(
      key == "spec" or key == "root" or key == "install",
      "unsupported setup option: " .. tostring(key)
    )
  end
  local install = config.install == nil and {} or config.install
  assert(type(install) == "table", "install must be a table")
  for key in pairs(install) do
    assert(key == "missing", "unsupported install option: " .. tostring(key))
  end
  assert(
    install.missing == nil or type(install.missing) == "boolean",
    "install.missing must be a boolean"
  )
  assert(
    config.root == nil or (type(config.root) == "string" and config.root:sub(1, 1) == "/"),
    "plugin root must be absolute"
  )
  local root = config.root or (util.data_dir() .. "/rex/lazy")
  if type(plugins) == "string" then
    plugins = { { import = plugins } }
  end
  plugins = spec.collect(plugins == nil and {} or plugins, root)
  local by_name = {}
  for _, plugin in ipairs(plugins) do
    by_name[plugin.name] = plugin
  end
  configured = true

  for _, operation in ipairs({ "install", "update" }) do
    rex.action({
      name = "lazy_" .. operation,
      title = operation == "install" and "Lazy: Install Plugins" or "Lazy: Update Plugins",
      category = "Plugins",
      args = {
        type = "object",
        properties = { plugin = { type = "string" } },
        additionalProperties = false,
      },
      run = function(_, args)
        args = args or {}
        local selected = args.plugin and by_name[args.plugin]
        if args.plugin then
          assert(selected, "unknown plugin: " .. args.plugin)
          assert(selected.enabled, "plugin is disabled: " .. args.plugin)
          assert(selected.managed, "local plugins are externally managed: " .. args.plugin)
        end
        local results, errors = {}, {}
        local deadline = os.time() + 20
        for _, plugin in ipairs(selected and { selected } or plugins) do
          if plugin.enabled and plugin.managed then
            local ok, result = pcall(git.manage, plugin, operation, deadline)
            results[plugin.name] = ok and result or "failed"
            if not ok then
              errors[#errors + 1] = plugin.name .. ": " .. tostring(result)
            end
          end
        end
        assert(#errors == 0, table.concat(errors, "; "))
        return { plugins = results, reload = "rex config reload" }
      end,
    })
  end
  rex.action({
    name = "lazy_status",
    title = "Lazy: Plugin Status",
    category = "Plugins",
    run = function()
      local status = {}
      for _, plugin in ipairs(plugins) do
        status[plugin.name] = {
          dir = plugin.dir,
          enabled = plugin.enabled,
          managed = plugin.managed,
          installed = installed(plugin),
          loaded = plugin.load_status,
          error = plugin.load_error,
        }
      end
      return status
    end,
  })

  local deadline = os.time() + 20
  for _, plugin in ipairs(plugins) do
    if not plugin.enabled then
      plugin.load_status = "disabled"
    else
      attempt(plugin, function()
        if not installed(plugin) and plugin.managed and install.missing ~= false then
          git.manage(plugin, "install", deadline)
        end
        if not installed(plugin) then
          plugin.load_status = "missing"
          error("plugin not installed: " .. plugin.dir, 0)
        end
        loader.add(plugin)
        plugin.load_status = "ready"
      end)
    end
  end
  for _, plugin in ipairs(plugins) do
    if plugin.load_status == "ready" and plugin.init then
      attempt(plugin, function()
        plugin.init(plugin)
      end)
    end
  end
  for _, plugin in ipairs(plugins) do
    if plugin.load_status == "ready" then
      attempt(plugin, function()
        loader.configure(plugin)
        plugin.load_status = "loaded"
      end)
    end
  end
  return M
end

return M
