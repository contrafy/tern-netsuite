--!strict
-- Links of the `browser` area. `tern-netsuite://browser?cwd=<dir>` opens the
-- browser block (the lens chip uses it). An import runs in a window split,
-- so the block stores a single-use grant under tern.kv and opens
-- `tern-netsuite://browser/import?grant=<id>`: the link carries only the
-- random id, so a link printed by anything else cannot name what to import,
-- and the window re-validates the stored request before running it.

local Crypto = require("../ns/crypto")
local Imports = require("./imports")

-- `cwd` is set for some browse links, `id` for every import link.
export type Parsed = { t: "browse" | "import", cwd: string?, id: string? }

export type Grant = {
	request: Imports.Request,
	-- "<project> -> <account>" for the toast.
	label: string,
	-- os.time() seconds after which the grant is void.
	exp: number,
}

export type Grants = { [string]: Grant }

local M = {}

M.BLOCK = "tern-netsuite.browser"
M.BASE = "tern-netsuite://browser"
M.GRANTS_KEY = "browser.grants"
M.TTL_SECONDS = 120
M.MAX_GRANTS = 32

function M.newId(seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256("browser:" .. seed .. ":" .. tostring(counter))), 1, 32)
end

local function encode(s: string): string
	return (
		string.gsub(s, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function decode(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

function M.browseUrl(cwd: string?): string
	return if cwd then M.BASE .. "?cwd=" .. encode(cwd) else M.BASE
end

function M.importUrl(id: string): string
	return M.BASE .. "/import?grant=" .. id
end

function M.parse(url: string): Parsed?
	if url == M.BASE or url == M.BASE .. "/" then
		return { t = "browse", cwd = nil }
	end
	local raw = string.match(url, "^tern%-netsuite://browser/?%?cwd=([^&#]*)$")
	if raw then
		local cwd = decode(raw)
		if string.sub(cwd, 1, 1) ~= "/" or string.find(cwd, "%c") then
			return nil
		end
		return { t = "browse", cwd = cwd }
	end
	local id = string.match(url, "^tern%-netsuite://browser/import%?grant=([0-9a-f]+)$")
	if id and #id >= 16 and #id <= 64 then
		return { t = "import", id = id }
	end
	return nil
end

-- kv round-trips through JSON: rebuild a Request from plain fields only.
local function request(v: any): Imports.Request?
	if type(v) ~= "table" then
		return nil
	end
	local function str(x: any): string?
		return if type(x) == "string" then x else nil
	end
	local kind = v.kind
	if kind ~= "object" and kind ~= "file" then
		return nil
	end
	local root, pf = str(v.root), str(v.projectFolder)
	if root == nil or pf == nil then
		return nil
	end
	return {
		kind = kind,
		root = root,
		projectFolder = pf,
		type = str(v.type),
		scriptId = str(v.scriptId),
		destinationFolder = str(v.destinationFolder),
		excludeFiles = v.excludeFiles == true,
		path = str(v.path),
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
	out[id] = { request = grant.request, label = grant.label, exp = now + M.TTL_SECONDS }
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

-- Removes grant `id` from `stored`; returns it when it is live and its
-- request validates, the remaining grants (store them back) and otherwise
-- why not.
function M.takeGrant(stored: any, id: string, now: number): (Grant?, Grants, string?)
	local raw = if type(stored) == "table" then stored[id] else nil
	local rest = live(stored, now)
	rest[id] = nil
	if type(raw) ~= "table" then
		return nil, rest, "this import link was already used or is unknown; press i in the browser again"
	end
	if type(raw.exp) ~= "number" or raw.exp < now then
		return nil, rest, "this import link expired; press i in the browser again"
	end
	local req = request(raw.request)
	if req == nil then
		return nil, rest, "the stored import request is malformed"
	end
	local err = Imports.validate(req)
	if err then
		return nil, rest, err
	end
	return { request = req, label = if type(raw.label) == "string" then raw.label else "", exp = raw.exp }, rest, nil
end

return table.freeze(M)
