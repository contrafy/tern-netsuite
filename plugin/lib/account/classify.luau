--!strict
-- Decides whether a NetSuite account is production. Configured accounts win;
-- otherwise the account id decides: sandbox (`_SB<n>`), release preview
-- (`_RP[<n>]`) and test drive (`TSTDRV<n>`) ids are non-production and every
-- other id counts as production, so an unknown account fails closed.

local Config = require("../config")

type Config = Config.Config
type Account = Config.Account

export type Result = {
	accountId: string,
	production: boolean,
	label: string,
	reason: "configured" | "inferred",
	account: Account?,
}

local M = {}

local function inferProduction(accountId: string): boolean
	local id = string.upper(accountId)
	if string.find(id, "_SB%d+$") or string.find(id, "_RP%d*$") or string.find(id, "^TSTDRV%d+$") then
		return false
	end
	return true
end

local function fromAccount(a: Account): Result
	local production = a.production
	return {
		accountId = a.account_id,
		production = if production == nil then inferProduction(a.account_id) else production,
		label = a.label or a.id,
		reason = if production == nil then "inferred" else "configured",
		account = a,
	}
end

function M.account(accountId: string, cfg: Config): Result
	local id = string.upper(accountId)
	for _, a in cfg.accounts do
		if a.account_id == id then
			return fromAccount(a)
		end
	end
	return { accountId = id, production = inferProduction(id), label = id, reason = "inferred", account = nil }
end

-- The account a configured auth id belongs to; nil when no account lists it.
function M.authId(authId: string, cfg: Config): Result?
	for _, a in cfg.accounts do
		if table.find(a.auth_ids, authId) then
			return fromAccount(a)
		end
	end
	return nil
end

return M
