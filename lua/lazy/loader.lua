local util = require("lazy.util")
local M = {}

function M.add(plugin)
  local root = plugin.dir .. "/lua"
  package.path = package.path .. ";" .. root .. "/?.lua;" .. root .. "/?/init.lua"
end

local function normalize(name)
  return name:lower():gsub("[._-]", ""):gsub("^lua", ""):gsub("^rex", ""):gsub("rex$", "")
end

local function main_module(plugin)
  if plugin.main then
    return plugin.main
  end
  local modules, matched = {}, nil
  for _, module in ipairs(util.modules(plugin.dir .. "/lua")) do
    if module.name ~= "" then
      modules[#modules + 1] = module.name
      if normalize(module.name) == normalize(plugin.name) then
        assert(not matched, "ambiguous main module; set main for " .. plugin.name)
        matched = module.name
      end
    end
  end
  local main = matched or (#modules == 1 and modules[1])
  assert(main, "cannot infer main module; set main for " .. plugin.name)
  return main
end

function M.configure(plugin)
  if plugin.opts == nil and plugin.config == nil then
    return
  end
  local opts = {}
  if type(plugin.opts) == "function" then
    local result = plugin.opts(plugin, opts)
    assert(result == nil or type(result) == "table", "opts() must return a table or nil")
    opts = result or opts
  elseif plugin.opts then
    opts = plugin.opts
  end
  assert(type(opts) == "table", "opts() must return a table or nil")
  if type(plugin.config) == "function" then
    plugin.config(plugin, opts)
  else
    local module = require(main_module(plugin))
    assert(
      type(module) == "table" and type(module.setup) == "function",
      "main module must return setup(opts)"
    )
    module.setup(opts)
  end
end

return M
