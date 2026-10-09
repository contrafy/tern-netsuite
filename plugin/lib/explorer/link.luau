--!strict
-- The explorer block (host) asks the window to open an upload pane: it
-- stores a single-use grant under tern.kv and opens
-- `tern-netsuite://explorer/upload?grant=<id>`. The link carries only the
-- random id, so a link printed by anything else cannot name a file to
-- upload; the window takes (removes) the grant and re-validates every field.

local Crypto = require("../ns/crypto")

export type Grant = {
	project: string,
	root: string,
	-- Relative to the project root.
	path: string,
	fileCabinetPath: string,
	authId: string?,
	label: string,
	accountId: string?,
	production: boolean,
	-- os.time() seconds after which the grant is void.
	exp: number,
}

export type Grants = { [string]: Grant }

local M = {}

M.PREFIX = "tern-netsuite://explorer/"
M.GRANTS_KEY = "explorer.grants"
M.TTL_SECONDS = 120
M.MAX_GRANTS = 32

function M.newId(seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256("explorer:" .. seed .. ":" .. tostring(counter))), 1, 32)
end

function M.validId(id: string): boolean
	return #id >= 16 and #id <= 64 and string.find(id, "^[a-f0-9]+$") ~= nil
end

function M.uploadUrl(id: string): string
	return M.PREFIX .. "upload?grant=" .. id
end

-- The action and grant id of a link this module produces, else nil.
function M.parse(url: string): (string?, string?)
	local id = string.match(url, "^tern%-netsuite://explorer/upload%?grant=([a-f0-9]+)$")
	if id == nil or not M.validId(id) then
		return nil, nil
	end
	return "upload", id
end

local function str(v: any): boolean
	return type(v) == "string" and v ~= ""
end

-- A stored value as a Grant, or nil when any field is missing or mistyped
-- (kv round-trips through JSON).
local function valid(v: any): Grant?
	if type(v) ~= "table" then
		return nil
	end
	if not (str(v.project) and str(v.root) and str(v.path) and str(v.fileCabinetPath) and str(v.label)) then
		return nil
	end
	if type(v.production) ~= "boolean" or type(v.exp) ~= "number" then
		return nil
	end
	if (v.authId ~= nil and not str(v.authId)) or (v.accountId ~= nil and not str(v.accountId)) then
		return nil
	end
	return {
		project = v.project,
		root = v.root,
		path = v.path,
		fileCabinetPath = v.fileCabinetPath,
		authId = v.authId,
		label = v.label,
		accountId = v.accountId,
		production = v.production,
		exp = v.exp,
	}
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

-- `stored` plus the grant (expiring TTL_SECONDS after `now`), without
-- expired entries and at most MAX_GRANTS (the oldest go first).
function M.addGrant(stored: any, id: string, grant: Grant, now: number): Grants
	local out = live(stored, now)
	local g = table.clone(grant)
	g.exp = now + M.TTL_SECONDS
	out[id] = g
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
		return nil, rest, "this upload link was already used or unknown; press u in the explorer again"
	end
	local g = valid(raw)
	if g == nil then
		return nil, rest, "the stored upload request is malformed"
	end
	if g.exp < now then
		return nil, rest, "this upload link expired; press u in the explorer again"
	end
	return g, rest, nil
end

return table.freeze(M)
