local M = {}

function M.exists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

function M.run(argv, opts)
  opts = opts or {}
  opts.timeout = opts.timeout or 3
  local result, err = rex.exec(argv, opts)
  assert(result, err)
  if not result.ok then
    local message = (result.stderr or ""):gsub("%s+$", "")
    if result.timed_out then
      message = "command timed out"
    elseif message == "" then
      message = result.signal or ("exit status " .. tostring(result.code))
    end
    error(argv[1] .. ": " .. message, 0)
  end
  return result.stdout or ""
end

function M.data_dir()
  local path = os.getenv("XDG_DATA_HOME")
  if not path or path == "" then
    local home = os.getenv("HOME")
    assert(home and home ~= "", "HOME is not set")
    path = home .. "/.local/share"
  end
  assert(path:sub(1, 1) == "/", "data directory must be absolute")
  return path
end

function M.module_name(name)
  return type(name) == "string"
    and name:match("^[%w_-][%w_.-]*$") ~= nil
    and not name:find("..", 1, true)
    and name:sub(-1) ~= "."
end

function M.modules(directory)
  local modules = {}
  if not M.exists(directory) then
    return modules
  end
  local output =
    M.run({ "find", "-L", directory, "-maxdepth", "2", "-type", "f", "-name", "*.lua", "-print0" })
  for path in output:gmatch("([^%z]+)%z") do
    local child = path:sub(#directory + 2)
    local name = child == "init.lua" and ""
      or child:match("^([^/]+)%.lua$")
      or child:match("^([^/]+)/init%.lua$")
    if name and child:sub(1, 1) ~= "." then
      modules[#modules + 1] = { name = name, path = path }
    end
  end
  table.sort(modules, function(a, b)
    return a.name == b.name and a.path < b.path or a.name < b.name
  end)
  return modules
end

return M
