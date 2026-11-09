--!strict
-- Single-use, short-lived grants in tern.kv for links that start NetSuite
-- queries (the logs chip, the health block's refresh). The plugin's own UI
-- stores a grant and opens a link that carries only its random id; the
-- window takes (removes) it. A link printed by anything else names no live
-- grant, so it starts nothing. `data` must survive a JSON round trip.

local Crypto = require("../ns/crypto")

export type Grant = { exp: number, data: any }
export type Grants = { [string]: Grant }

local M = {}

M.TTL_SECONDS = 120
M.MAX_GRANTS = 32

function M.newId(prefix: string, seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256(prefix .. ":" .. seed .. ":" .. tostring(counter))), 1, 32)
end

function M.validId(id: string): boolean
	return #id >= 16 and #id <= 64 and string.find(id, "^[a-f0-9]+$") ~= nil
end

local function live(stored: any, now: number): Grants
	local out: Grants = {}
	if type(stored) ~= "table" then
		return out
	end
	for id, v in stored do
		if type(id) == "string" and type(v) == "table" and type(v.exp) == "number" and v.exp >= now then
			out[id] = { exp = v.exp, data = v.data }
		end
	end
	return out
end

-- `stored` plus grant `id` (expiring TTL_SECONDS after `now`), without
-- expired entries and at most MAX_GRANTS (the oldest go first).
function M.add(stored: any, id: string, data: any, now: number): Grants
	local out = live(stored, now)
	out[id] = { exp = now + M.TTL_SECONDS, data = data }
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

-- Removes grant `id` from `stored`; returns its data when it was live, the
-- remaining grants (store them back) and otherwise why not ("unknown" for
-- a used or never issued id, "expired").
function M.take(stored: any, id: string, now: number): (any, Grants, string?)
	local raw = if type(stored) == "table" then stored[id] else nil
	local rest = live(stored, now)
	rest[id] = nil
	if type(raw) ~= "table" or type(raw.exp) ~= "number" then
		return nil, rest, "unknown"
	end
	if raw.exp < now then
		return nil, rest, "expired"
	end
	return raw.data, rest, nil
end

return table.freeze(M)
