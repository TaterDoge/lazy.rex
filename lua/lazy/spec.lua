local util = require("lazy.util")
local M = {}

local function parse(spec, root)
  if type(spec) == "string" then
    spec = { spec }
  end
  assert(type(spec) == "table", "expected a plugin spec")
  local allowed = {
    [1] = true,
    dir = true,
    url = true,
    name = true,
    main = true,
    opts = true,
    config = true,
    init = true,
    enabled = true,
  }
  for key in pairs(spec) do
    assert(allowed[key], "unsupported plugin option: " .. tostring(key))
  end
  assert(spec[1] == nil or type(spec[1]) == "string", "plugin source must be a string")
  assert(
    spec.dir == nil or (type(spec.dir) == "string" and spec.dir:sub(1, 1) == "/"),
    "dir must be an absolute path"
  )
  assert(
    spec.url == nil or (type(spec.url) == "string" and spec.url ~= ""),
    "url must be a nonempty string"
  )
  local dir, url = spec.dir, spec.url
  if spec[1] and not dir and not url then
    if spec[1]:sub(1, 1) == "/" then
      dir = spec[1]
    elseif spec[1]:find(":", 1, true) then
      url = spec[1]
    else
      local owner, repo = spec[1]:match("^([%w_.-]+)/([%w_.-]+)$")
      assert(
        owner and owner ~= "." and owner ~= ".." and repo ~= "." and repo ~= "..",
        "invalid plugin: " .. spec[1]
      )
      url = "https://github.com/" .. spec[1] .. ".git"
    end
  end
  assert(dir or url, "plugin spec needs a source, dir or url")
  local source_name = (spec[1] or dir or url):gsub("/+$", ""):match("([^/:]+)$") or ""
  local name = spec.name == nil and source_name:gsub("%.git$", "") or spec.name
  assert(
    type(name) == "string" and name:match("^[%w_.-]+$") and name ~= "." and name ~= "..",
    "invalid plugin name"
  )
  assert(name ~= "lazy.rex", "the lazy.rex name is reserved")
  assert(
    spec.opts == nil or type(spec.opts) == "table" or type(spec.opts) == "function",
    "opts must be a table or function"
  )
  assert(
    spec.config == nil or spec.config == true or type(spec.config) == "function",
    "config must be true or a function"
  )
  assert(spec.init == nil or type(spec.init) == "function", "init must be a function")
  assert(
    spec.enabled == nil or type(spec.enabled) == "boolean" or type(spec.enabled) == "function",
    "enabled must be a boolean or function"
  )
  local enabled = spec.enabled
  if type(enabled) == "function" then
    enabled = enabled()
    assert(type(enabled) == "boolean", "enabled() must return a boolean")
  end
  assert(
    spec.main == nil or util.module_name(spec.main),
    "invalid main module: " .. tostring(spec.main)
  )
  assert(
    spec.main ~= "lazy" and not (spec.main and spec.main:sub(1, 5) == "lazy."),
    "the lazy namespace is reserved"
  )
  return {
    name = name,
    url = url,
    dir = dir or (root .. "/" .. name),
    managed = dir == nil,
    main = spec.main,
    opts = spec.opts,
    config = spec.config,
    init = spec.init,
    enabled = enabled ~= false,
  }
end

local function import_files(name)
  assert(util.module_name(name), "invalid import: " .. tostring(name))
  local relative = name:gsub("%.", "/")
  for template in package.path:gmatch("[^;]+") do
    local prefix = template:match("^(.*)%?%.lua$") or template:match("^(.*)%?/init%.lua$")
    if prefix then
      local directory = prefix .. relative
      if util.exists(directory) or util.exists(directory .. ".lua") then
        local files = {}
        if util.exists(directory .. ".lua") then
          files[#files + 1] = directory .. ".lua"
        end
        for _, module in ipairs(util.modules(directory)) do
          files[#files + 1] = module.path
        end
        return files
      end
    end
  end
  error("import not found: " .. name, 0)
end

function M.collect(specs, root)
  local plugins, names, imports, files, visiting = {}, {}, {}, {}, {}
  local visit
  visit = function(value)
    if type(value) == "table" and value.import ~= nil then
      for key in pairs(value) do
        assert(key == "import", "import specs only accept the import field")
      end
      local name = value.import
      assert(util.module_name(name), "invalid import: " .. tostring(name))
      assert(imports[name] ~= "loading", "cyclic import: " .. name)
      if imports[name] then
        return
      end
      imports[name] = "loading"
      for _, path in ipairs(import_files(name)) do
        if not files[path] then
          files[path] = true
          local chunk, load_error = loadfile(path)
          assert(chunk, load_error)
          local ok, err = pcall(function()
            visit(chunk())
          end)
          assert(ok, path .. ": " .. tostring(err))
        end
      end
      imports[name] = "loaded"
    elseif
      type(value) == "string"
      or (
        type(value) == "table"
        and (
          value.dir ~= nil
          or value.url ~= nil
          or (type(value[1]) == "string" and value[2] == nil)
        )
      )
    then
      local plugin = parse(value, root)
      assert(
        not names[plugin.name],
        "duplicate plugin name: " .. plugin.name .. "; use name to disambiguate"
      )
      names[plugin.name] = true
      plugins[#plugins + 1] = plugin
    else
      assert(type(value) == "table", "plugin files must return a spec or list of specs")
      assert(not visiting[value], "cyclic spec list")
      visiting[value] = true
      for key in pairs(value) do
        assert(
          type(key) == "number" and key >= 1 and key % 1 == 0 and key <= #value,
          "expected a list of plugin specs"
        )
      end
      for i = 1, #value do
        assert(value[i] ~= nil, "expected a dense list of plugin specs")
        visit(value[i])
      end
      visiting[value] = nil
    end
  end
  visit(specs)
  return plugins
end

return M
