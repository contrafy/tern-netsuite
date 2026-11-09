--!strict
-- `tern-netsuite://history/...` links from the history block to the window,
-- which can split panes (blocks cannot). Opening a failed run's log starts
-- `gh` with the user's token, so the block stores a single-use grant under
-- tern.kv and opens `tern-netsuite://history/failed-log?grant=<id>`: a link
-- printed by anything else names no repository. The window takes (removes)
-- the grant and re-validates both fields, which end up in a shell command.

local Crypto = require("../ns/crypto")

export type Grant = {
	repo: string,
	run: number,
	-- os.time() seconds after which the grant is void.
	exp: number,
}

export type Grants = { [string]: Grant }

local M = {}

M.PREFIX = "tern-netsuite://history/"
M.GRANTS_KEY = "history.grants"
M.TTL_SECONDS = 120
M.MAX_GRANTS = 32

function M.newId(seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256("history:" .. seed .. ":" .. tostring(counter))), 1, 32)
end

function M.validId(id: string): boolean
	return #id >= 16 and #id <= 64 and string.find(id, "^[a-f0-9]+$") ~= nil
end

function M.failedLogUrl(id: string): string
	return M.PREFIX .. "failed-log?grant=" .. id
end

-- The grant id of a link this module produces, else nil.
function M.parse(url: string): string?
	local id = string.match(url, "^tern%-netsuite://history/failed%-log%?grant=([a-f0-9]+)$")
	if id == nil or not M.validId(id) then
		return nil
	end
	return id
end

-- A stored value as a Grant, or nil when a field is missing, mistyped or
-- could smuggle shell text into the log command (kv round-trips JSON).
local function valid(v: any): Grant?
	if type(v) ~= "table" or type(v.repo) ~= "string" or type(v.run) ~= "number" or type(v.exp) ~= "number" then
		return nil
	end
	if not string.match(v.repo, "^[%w%-_%.]+/[%w%-_%.]+$") then
		return nil
	end
	if v.run < 1 or v.run ~= math.floor(v.run) or v.run >= 2 ^ 53 then
		return nil
	end
	return { repo = v.repo, run = v.run, exp = v.exp }
end

local function live(stored: any, now: number): Grants
	local out: Grants = {}
	if type(stored) ~= "table" then
		return out
	end
	for id, v in stored do
		if type(id) == "string" and type(v) == "table" and type(v.exp) == "number" and v.exp >= now then
			out[id] = v
		end
	end
	return out
end

-- `stored` plus a grant for the run's log (expiring TTL_SECONDS after
-- `now`), without expired entries and at most MAX_GRANTS (oldest first).
function M.addGrant(stored: any, id: string, repo: string, run: number, now: number): Grants
	local out = live(stored, now)
	out[id] = { repo = repo, run = run, exp = now + M.TTL_SECONDS }
	local ids: { string } = {}
	for k in out do
		table.insert(ids, k)
	end
	if #ids > M.MAX_GRANTS then
		table.sort(ids, function(a: string, b: string): boolean
			if out[a].exp ~= out[b].exp then
				return out[a].exp < out[b].exp
			end
			return a < b
		end)
		for i = 1, #ids - M.MAX_GRANTS do
			out[ids[i]] = nil
		end
	end
	return out
end

-- Removes grant `id` from `stored`; returns it when it was valid and live,
-- the remaining grants (store them back) and otherwise why not.
function M.takeGrant(stored: any, id: string, now: number): (Grant?, Grants, string?)
	local raw = if type(stored) == "table" then stored[id] else nil
	local rest = live(stored, now)
	rest[id] = nil
	if raw == nil then
		return nil, rest, "this log link was already used or unknown; press l in the history again"
	end
	local g = valid(raw)
	if g == nil then
		return nil, rest, "the stored log request is malformed"
	end
	if g.exp < now then
		return nil, rest, "this log link expired; press l in the history again"
	end
	return g, rest, nil
end

return table.freeze(M)
