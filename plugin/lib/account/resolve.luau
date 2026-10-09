--!strict
-- Which account an auth id points at: the config's `accounts[].auth_ids`
-- first, then a cached `account:manageauth --info` answer, else unknown.
-- Unknown counts as production (fail closed); callers that display it should
-- say "unknown" rather than PROD. The adapter runs the CLI and feeds the
-- answers in with `store`.

local Classify = require("./classify")
local Config = require("../config")
local Manageauth = require("./manageauth")

type Config = Config.Config

export type CacheEntry = {
	authId: string,
	-- nil when no lookup has succeeded within the TTL.
	accountId: string?,
	-- tern.now() milliseconds when accountId arrived (or the failure, without one).
	at: number,
	-- The last failed lookup since accountId arrived.
	error: string?,
	errorAt: number?,
}

export type Cache = { [string]: CacheEntry }

export type Source = "configured" | "cli" | "unknown"

export type Resolution = {
	authId: string,
	source: Source,
	accountId: string?,
	-- True for unknown accounts.
	production: boolean,
	label: string,
	problem: string?,
}

export type Options = {
	config: Config,
	cache: Cache,
	now: number,
	-- Defaults to TTL_MS.
	ttl: number?,
}

local M = {}

-- An auth id is re-pointed only by account:setup, so answers last an hour.
M.TTL_MS = 3600000
-- Failures (unknown auth id, CLI missing) are retried after a minute.
M.ERROR_TTL_MS = 60000

local function fresh(entry: CacheEntry, opts: Options): boolean
	return opts.now - entry.at < (opts.ttl or M.TTL_MS)
end

function M.resolve(authId: string, opts: Options): Resolution
	local configured = Classify.authId(authId, opts.config)
	if configured then
		return {
			authId = authId,
			source = "configured",
			accountId = configured.accountId,
			production = configured.production,
			label = configured.label,
			problem = nil,
		}
	end
	local entry = opts.cache[authId]
	if entry and fresh(entry, opts) and entry.accountId then
		local c = Classify.account(entry.accountId, opts.config)
		return {
			authId = authId,
			source = "cli",
			accountId = c.accountId,
			production = c.production,
			label = c.label,
			problem = nil,
		}
	end
	return {
		authId = authId,
		source = "unknown",
		accountId = nil,
		production = true,
		label = authId,
		problem = if entry and fresh(entry, opts) then entry.error else nil,
	}
end

-- Whether the adapter should run `--info` now: never for configured auth
-- ids; after a failure on the error schedule; for answers at half their TTL,
-- so a refresh lands before they expire.
function M.needsLookup(authId: string, opts: Options): boolean
	if Classify.authId(authId, opts.config) then
		return false
	end
	local entry = opts.cache[authId]
	if entry == nil then
		return true
	end
	local failedAt = entry.errorAt or (if entry.accountId == nil then entry.at else nil)
	if failedAt then
		return opts.now - failedAt >= M.ERROR_TTL_MS
	end
	return opts.now - entry.at >= (opts.ttl or M.TTL_MS) / 2
end

function M.fromInfo(info: Manageauth.Info, now: number): CacheEntry
	return { authId = info.authId, accountId = info.accountId, at = now, error = nil, errorAt = nil }
end

function M.fromError(authId: string, err: string, now: number): CacheEntry
	return { authId = authId, accountId = nil, at = now, error = err, errorAt = now }
end

-- A failed refresh must not erase an account still within its TTL (a PROD
-- account would turn unknown); the failure is recorded beside it instead,
-- and resolve() drops the account itself once it expires.
function M.store(cache: Cache, entry: CacheEntry, ttl: number?): Cache
	local out = table.clone(cache)
	local prev = cache[entry.authId]
	if entry.accountId == nil and prev and prev.accountId and entry.at - prev.at < (ttl or M.TTL_MS) then
		local kept = table.clone(prev)
		kept.error = entry.error
		kept.errorAt = entry.at
		out[entry.authId] = kept
	else
		out[entry.authId] = entry
	end
	return out
end

return M
