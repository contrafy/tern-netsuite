--!strict
-- The SuiteCloud CLI commands (`suitecloud <command>`), as listed by
-- `suitecloud --help` for @oracle/suitecloud-cli 3.2.0.

local M = {}

M.ALL = table.freeze({
	"account:manageauth",
	"account:setup",
	"account:setup:ci",
	"file:create",
	"file:import",
	"file:list",
	"file:upload",
	"object:import",
	"object:list",
	"object:update",
	"proxy:generatekey",
	"proxy:start",
	"project:adddependencies",
	"project:create",
	"project:deploy",
	"project:package",
	"project:validate",
})

local known: { [string]: boolean } = {}
for _, c in M.ALL do
	known[c] = true
end

function M.isKnown(command: string): boolean
	return known[command] == true
end

return table.freeze(M)
