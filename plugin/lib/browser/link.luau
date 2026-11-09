--!strict
-- Links of the `browser` area. Any program can print a link, so no link
-- runs the CLI by itself:
--   - `tern-netsuite://browser[?cwd=<dir>]` opens the block held: it shows
--     the project, auth ID and account and waits for Enter;
--   - `tern-netsuite://browser?grant=<id>` (the suitecloud lens chip) opens
--     it running, for the directory a single-use grant in tern.kv names;
--   - `tern-netsuite://browser/import?grant=<id>` (the block's i key) runs
--     the import a single-use grant names, in a window split; the window
--     re-validates the stored request before running it.
-- The links carry only random ids, so a printed link cannot name what to
-- list or import. The palette command opens the block directly.

local Crypto = require("../ns/crypto")
local Imports = require("./imports")

-- `cwd` is set for some browse links, `id` for grant and import links.
export type Parsed = { t: "browse" | "grant" | "import", cwd: string?, id: string? }

export type Grant = {
	request: Imports.Request,
	-- "<project> -> <account>" for the toast.
	label: string,
	-- project.json's defaultAuthId: the CLI slot the import pane waits in.
	authId: string?,
	-- os.time() seconds after which the grant is void.
	exp: number,
}

export type Grants = { [string]: Grant }

-- A browse grant: the directory the lens chip was clicked for.
export type Browse = { cwd: string, exp: number }
export type Browses = { [string]: Browse }

local M = {}

M.BLOCK = "tern-netsuite.browser"
M.BASE = "tern-netsuite://browser"
M.GRANTS_KEY = "browser.grants"
M.BROWSE_KEY = "browser.browse"
M.TTL_SECONDS = 120
M.MAX_GRANTS = 32
-- Block argument: wait for Enter before running the CLI.
M.HOLD_FLAG = "--hold"

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

function M.grantUrl(id: string): string
	return M.BASE .. "?grant=" .. id
end

local function grantId(url: string, pattern: string): string?
	local id = string.match(url, pattern)
	return if id and #id >= 16 and #id <= 64 then id else nil
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
	local browse = grantId(url, "^tern%-netsuite://browser/?%?grant=([0-9a-f]+)$")
	if browse then
		return { t = "grant", id = browse }
	end
	local id = grantId(url, "^tern%-netsuite://browser/import%?grant=([0-9a-f]+)$")
	if id then
		return { t = "import", id = id }
	end
	return nil
end

-- The block's arguments for directory `cwd` (nil: the pane's), held or not.
function M.blockArgs(cwd: string?, held: boolean): { string }
	local args: { string } = {}
	if held then
		table.insert(args, M.HOLD_FLAG)
	end
	if cwd then
		table.insert(args, cwd)
	end
	return args
end

-- The directory and hold flag of the block's arguments.
function M.fromArgs(args: { string }): (string?, boolean)
	local cwd: string? = nil
	local held = false
	for _, a in args do
		if a == M.HOLD_FLAG then
			held = true
		elseif cwd == nil and string.sub(a, 1, 1) == "/" then
			cwd = a
		end
	end
	return cwd, held
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

-- Live entries of a grant store (any value with a numeric `exp`).
local function live(stored: any, now: number): { [string]: any }
	local out: { [string]: any } = {}
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

-- Drops the oldest entries past MAX_GRANTS.
local function bound(out: { [string]: any })
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
end

-- `stored` plus the grant (expiring TTL_SECONDS after `now`), without
-- expired entries and at most MAX_GRANTS (the oldest go first).
function M.addGrant(stored: any, id: string, grant: Grant, now: number): Grants
	local out = live(stored, now)
	out[id] = { request = grant.request, label = grant.label, authId = grant.authId, exp = now + M.TTL_SECONDS }
	bound(out)
	return out :: Grants
end

-- Removes grant `id` from `stored`; returns it when it is live and its
-- request validates, the remaining grants (store them back) and otherwise
-- why not.
function M.takeGrant(stored: any, id: string, now: number): (Grant?, Grants, string?)
	local raw = if type(stored) == "table" then stored[id] else nil
	local rest = live(stored, now) :: Grants
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
	return {
		request = req,
		label = if type(raw.label) == "string" then raw.label else "",
		authId = if type(raw.authId) == "string" and raw.authId ~= "" then raw.authId else nil,
		exp = raw.exp,
	},
		rest,
		nil
end

-- `stored` plus a browse grant for `cwd`, bounded like import grants.
function M.addBrowse(stored: any, id: string, cwd: string, now: number): Browses
	local out = live(stored, now)
	out[id] = { cwd = cwd, exp = now + M.TTL_SECONDS }
	bound(out)
	return out :: Browses
end

-- Removes browse grant `id`; returns its directory when it is live and
-- absolute, the remaining grants and otherwise why not.
function M.takeBrowse(stored: any, id: string, now: number): (string?, Browses, string?)
	local raw = if type(stored) == "table" then stored[id] else nil
	local rest = live(stored, now) :: Browses
	rest[id] = nil
	if type(raw) ~= "table" then
		return nil, rest, "this browse link was already used or is unknown; click the chip again"
	end
	if type(raw.exp) ~= "number" or raw.exp < now then
		return nil, rest, "this browse link expired; click the chip again"
	end
	local cwd = raw.cwd
	if type(cwd) ~= "string" or string.sub(cwd, 1, 1) ~= "/" or string.find(cwd, "%c") then
		return nil, rest, "the stored directory is malformed"
	end
	return cwd, rest, nil
end

return table.freeze(M)
