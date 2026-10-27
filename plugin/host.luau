--!strict
-- Host (daemon) half: lenses, blocks and host hooks. Every feature lives in a
-- `*_host.luau` adapter exporting `register()`; this file only wires them.
-- Adapters execute effects and feed results to pure modules under lib/.

local ConfigHost = require("./config_host")

pcall(tern.fs.mkdir, tern.plugin.data)

-- The spawn hook and lens callbacks read ConfigHost.current(), which never
-- touches the disk; this throttled re-read keeps them in step with edits
-- (the window half does the same for its own VM).
local CONFIG_RECHECK_MS = 2000
local lastConfigCheck = tern.now()

local function recheckConfig()
	local now = tern.now()
	if now - lastConfigCheck < CONFIG_RECHECK_MS then
		return
	end
	lastConfigCheck = now
	local ok, err = pcall(ConfigHost.load)
	if not ok then
		tern.log.warn("tern-netsuite config reload failed", tostring(err))
	end
end

tern.on("command_finished", recheckConfig)
tern.on("cwd", recheckConfig)

require("./doctor_host").register()
require("./ns_host").register()
require("./guard_host").register()
require("./lens_host").register()
require("./scaffold_host").register()
require("./health_host").register()
require("./logs_host").register()
require("./explorer_host").register()
require("./history_host").register()
require("./browser_host").register()
