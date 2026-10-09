--!strict
-- Environment the host's `spawn` hook gives every new pane, read by
-- shell/tern-netsuite-guard (shell/PROTOCOL.md "Environment"). Settings travel
-- as variables rather than the guard parsing the config file: they are
-- already validated here, and an absent variable means the guard's
-- fail-closed defaults.

local Config = require("../config")

type Config = Config.Config

local M = {}

function M.forSpawn(cfg: Config, spool: string): { [string]: string }
	local accounts: { string } = {}
	for _, a in cfg.accounts do
		-- The shell splits the list on spaces and the entries on "=".
		if a.production ~= nil and string.find(a.account_id, "^[%w_%-]+$") then
			table.insert(accounts, a.account_id .. "=" .. (if a.production then "prod" else "nonprod"))
		end
	end
	local env: { [string]: string } = {
		TNS_SPOOL = spool,
		TNS_GUARD_COMMANDS = table.concat(cfg.guard.commands, " "),
		TNS_GUARD_CONFIRM = if cfg.guard.confirm_production then "1" else "0",
		TNS_GUARD_TIMEOUT = string.format("%d", cfg.guard.timeout_s),
		TNS_GUARD_ACCOUNTS = table.concat(accounts, " "),
	}
	local program = cfg.suitecloud.program
	if string.sub(program, 1, 1) == "/" and not string.find(program, "%s") then
		env.TNS_SUITECLOUD = program
	end
	return env
end

return M
