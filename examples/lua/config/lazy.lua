local data = os.getenv("XDG_DATA_HOME")
if not data or data == "" then
  local home = os.getenv("HOME")
  assert(home and home ~= "", "HOME is not set")
  data = home .. "/.local/share"
end
assert(data:sub(1, 1) == "/", "XDG_DATA_HOME must be absolute")
local lazypath = data .. "/rex/lazy/lazy.rex"
local entry = io.open(lazypath .. "/lua/lazy/init.lua", "r")
if entry then
  entry:close()
else
  local script = [=[
set -eu
url=$1
dir=$2
mkdir -p "${dir%/*}"
lock="$dir.lazy-rex-lock"
mkdir "$lock" || { echo "lazy.rex installation is busy; inspect $lock" >&2; exit 1; }
trap 'rm -rf "$lock"' 0
trap 'exit 1' HUP INT TERM
if [ -e "$dir" ] || [ -L "$dir" ]; then
  test -f "$dir/lua/lazy/init.lua" || { echo "refusing to overwrite incomplete installation: $dir" >&2; exit 1; }
else
  git -c core.hooksPath=/dev/null clone --filter=blob:none -- "$url" "$lock/repo"
  test -f "$lock/repo/lua/lazy/init.lua" || { echo "repository is missing lua/lazy/init.lua" >&2; exit 1; }
  mv "$lock/repo" "$dir"
fi
]=]
  local result, err = rex.exec({
    "sh",
    "-c",
    script,
    "lazy.rex",
    "https://github.com/taterdoge/lazy.rex.git",
    lazypath,
  }, { timeout = 20, env = { GIT_TERMINAL_PROMPT = "0" } })
  if not result or not result.ok then
    local message = err or (result.timed_out and "clone timed out") or result.stderr
    error("Failed to bootstrap lazy.rex: " .. tostring(message), 0)
  end
end
package.path = lazypath .. "/lua/?.lua;" .. lazypath .. "/lua/?/init.lua;" .. package.path

require("lazy").setup({
  spec = { { import = "plugins" } },
})
