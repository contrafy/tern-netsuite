--!strict
-- The machine-wide SuiteCloud CLI slot (lib/sdf/cli_slot.luau) under this
-- plugin's data directory; usable from both halves. Every adapter that
-- starts a SuiteCloud account command goes through it:
--
--   tern.process.run(CliSlotHost.wrap(argv, authId, timeoutMs), { cwd = .., timeout_ms = timeoutMs }, ..)
--   CliSlot.paneScript({ .., lock = CliSlotHost.lock(authId), argv = argv })   -- split panes

local CliSlot = require("./lib/sdf/cli_slot")

local M = {}

function M.lock(authId: string?): string
	return CliSlot.lockPath(tern.plugin.data, authId)
end

-- The directory of every auth ID's slot (TNS_CLI_SLOTS for the guard).
function M.dir(): string
	return CliSlot.slotsDir(tern.plugin.data)
end

-- `argv` (an account command for `authId`) as a background run that waits
-- for the slot within half of `timeoutMs`.
function M.wrap(argv: { string }, authId: string?, timeoutMs: number): { string }
	return CliSlot.argv(argv, M.lock(authId), CliSlot.waitSeconds(timeoutMs))
end

return M
