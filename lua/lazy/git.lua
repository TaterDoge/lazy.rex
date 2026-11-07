local util = require("lazy.util")
local M = {}

local script = [=[
set -eu
url=$1
dir=$2
operation=$3
mkdir -p "${dir%/*}"
lock="$dir.lazy-rex-lock"
mkdir "$lock" || { echo "plugin is busy; inspect $lock before retrying" >&2; exit 1; }
trap 'rm -rf "$lock"' 0
trap 'exit 1' HUP INT TERM
if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
  git -c core.hooksPath=/dev/null clone --filter=blob:none -- "$url" "$lock/repo"
  mv "$lock/repo" "$dir"
  printf 'installed'
else
  test -f "$dir/.git/HEAD" || { echo "refusing to overwrite $dir: not a Git checkout" >&2; exit 1; }
  if [ "$operation" = update ]; then
    origin=$(git -C "$dir" config --get remote.origin.url)
    test "$origin" = "$url" || { echo "origin URL differs from plugin spec" >&2; exit 1; }
    status=$(git -C "$dir" status --porcelain)
    test -z "$status" || { echo "refusing to update a dirty checkout" >&2; exit 1; }
    git -c core.hooksPath=/dev/null -C "$dir" pull --ff-only >&2
    printf 'updated'
  else
    printf 'installed'
  fi
fi
]=]

function M.manage(plugin, operation, deadline)
  assert(plugin.managed, "local plugins are externally managed")
  local remaining = deadline - os.time()
  assert(remaining > 0, "time budget exhausted; retry lazy_install/lazy_update with plugin=name")
  return util.run({ "sh", "-c", script, "lazy.rex", plugin.url, plugin.dir, operation }, {
    timeout = remaining,
    env = { GIT_TERMINAL_PROMPT = "0", GIT_MERGE_AUTOEDIT = "no" },
  })
end

return M
