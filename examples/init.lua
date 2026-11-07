-- Optional layout: keep Lua modules under the config directory's lua/.
-- Rex prepends the actual config directory, including REX_CONFIG overrides.
local config = assert(package.path:match("^(.-)%?%.lua;"), "cannot locate Rex config")
package.path = config .. "lua/?.lua;" .. config .. "lua/?/init.lua;" .. package.path
require("config.lazy")

-- Keep rex.bind(...) here, or move them to any module you require.
