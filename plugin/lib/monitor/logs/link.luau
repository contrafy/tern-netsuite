--!strict
-- Links into the execution log tail, for the palette, other features (the
-- SuiteCloud lens can offer "tail logs" for the scripts a deploy touched) and
-- the block's own "connect account" hand-off:
--
--   tern-netsuite://logs[?connection=<id>][&script=<ids>]...[&since=<when>]
--     connection  a configured connection id (default: the first one)
--     script      repeatable and/or comma-separated; `customscript_x` style
--                 script ids (case-insensitive) or numeric internal ids;
--                 at most MAX_SCRIPTS
--     since       `YYYY-MM-DD`, `YYYY-MM-DD[T ]HH:MM[:SS]` (account time
--                 zone) or a relative `<n>m`, `<n>h`, `<n>d` (at most 30 days)
--   tern-netsuite://logs/connect?connection=<id>
--     opens the connect block for that connection
--
-- Everything is validated here, strictly: unknown parameters, fragments,
-- other paths, repeated single values and malformed escapes are refused.
-- Values only ever reach SuiteQL as `?` parameters (query.luau).

local Encoding = require("../../ns/encoding")
local Query = require("./query")

local M = {}

M.SCHEME = "tern-netsuite://"
M.AREA = "logs"
M.BLOCK = "tern-netsuite.logs"
M.CONNECT_BLOCK = "tern-netsuite.connect"
M.MAX_URL = 2048
M.MAX_SCRIPTS = 50
M.MAX_SINCE_MINUTES = 30 * 1440

export type Launch = {
	connection: string?,
	scripts: { string },
	since: Query.Since?,
}

export type Decision = { block: string, args: { string } }

local function quote(v: string): string
	local short = if #v > 60 then string.sub(v, 1, 57) .. "..." else v
	return string.format("%q", short)
end

function M.validConnection(id: string): boolean
	return #id <= 48 and string.find(id, "^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

-- The canonical (lower-case) script id or numeric id, or nil.
function M.script(v: string): string?
	local s = string.lower(v)
	if #s <= 100 and string.find(s, "^custom[a-z0-9_]+$") then
		return s
	elseif #s <= 12 and string.find(s, "^[1-9]%d*$") then
		return s
	end
	return nil
end

local function daysIn(y: number, m: number): number
	if m == 2 then
		return if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then 29 else 28
	end
	return if m == 4 or m == 6 or m == 9 or m == 11 then 30 else 31
end

function M.since(v: string): Query.Since?
	local n, unit = string.match(v, "^(%d+)([mhd])$")
	if n and unit then
		local minutes = (tonumber(n) :: number) * (if unit == "m" then 1 elseif unit == "h" then 60 else 1440)
		if minutes < 1 or minutes > M.MAX_SINCE_MINUTES then
			return nil
		end
		return { minutes = minutes }
	end
	local y, mo, d, rest = string.match(v, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if y == nil or mo == nil or d == nil or rest == nil then
		return nil
	end
	local h, mi, s = "00", "00", "00"
	if rest ~= "" then
		local hh, mm, tail = string.match(rest, "^[T ](%d%d):(%d%d)(.*)$")
		if hh == nil or mm == nil or tail == nil then
			return nil
		end
		h, mi = hh, mm
		if tail ~= "" then
			local sec = string.match(tail, "^:(%d%d)$")
			if sec == nil then
				return nil
			end
			s = sec
		end
	end
	local yn, mon, dn = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if
		mon < 1
		or mon > 12
		or dn < 1
		or dn > daysIn(yn, mon)
		or (tonumber(h) :: number) > 23
		or (tonumber(mi) :: number) > 59
		or (tonumber(s) :: number) > 59
	then
		return nil
	end
	return { at = string.format("%s-%s-%s %s:%s:%s", y, mo, d, h, mi, s) }
end

local function sinceText(s: Query.Since): string
	return if s.minutes then string.format("%dm", s.minutes) else s.at or ""
end

type Seen = { [string]: boolean }

-- Applies one `key=value` to `launch`; returns the problem, if any.
local function apply(launch: Launch, key: string, value: string, seen: Seen): string?
	if string.find(value, "%c") then
		return string.format("%s has a control character", key)
	end
	if key == "connection" then
		if seen.connection then
			return '"connection" is given more than once'
		end
		seen.connection = true
		if not M.validConnection(value) then
			return "invalid connection " .. quote(value)
		end
		launch.connection = value
	elseif key == "script" then
		for part in string.gmatch(value, "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
			local id = M.script(trimmed)
			if id == nil then
				return "invalid script " .. quote(trimmed) .. " (a customscript... id or a numeric id)"
			end
			if not table.find(launch.scripts, id) then
				if #launch.scripts >= M.MAX_SCRIPTS then
					return string.format("too many scripts (at most %d)", M.MAX_SCRIPTS)
				end
				table.insert(launch.scripts, id)
			end
		end
	elseif key == "since" then
		if seen.since then
			return '"since" is given more than once'
		end
		seen.since = true
		local s = M.since(value)
		if s == nil then
			return "invalid since "
				.. quote(value)
				.. " (YYYY-MM-DD, YYYY-MM-DD HH:MM[:SS] or <n>m / <n>h / <n>d up to 30 days)"
		end
		launch.since = s
	else
		return "unknown parameter " .. quote(key)
	end
	return nil
end

local function decode(s: string): (string?, string?)
	local i = 1
	while true do
		local at = string.find(s, "%", i, true)
		if at == nil then
			break
		end
		if not string.find(s, "^%x%x", at + 1) then
			return nil, "malformed escape in " .. quote(s)
		end
		i = at + 3
	end
	return Encoding.decode(s, true), nil
end

-- Launch args for the block, in canonical order.
function M.toArgs(launch: Launch): { string }
	local out: { string } = {}
	if launch.connection then
		table.insert(out, "connection=" .. launch.connection)
	end
	for _, s in launch.scripts do
		table.insert(out, "script=" .. s)
	end
	if launch.since then
		table.insert(out, "since=" .. sinceText(launch.since))
	end
	return out
end

-- The launch the block args describe; invalid args are left out and named
-- in `problems`.
function M.fromArgs(args: { string }): (Launch, { string })
	local launch: Launch = { connection = nil, scripts = {}, since = nil }
	local problems: { string } = {}
	local seen: Seen = {}
	for _, a in args do
		local key, value = string.match(a, "^([^=]*)=(.*)$")
		local problem = if key and value then apply(launch, key, value, seen) else "unknown argument " .. quote(a)
		if problem then
			table.insert(problems, problem)
		end
	end
	return launch, problems
end

-- The decision for a `tern-netsuite://logs...` URL, or nil and why.
function M.route(url: string): (Decision?, string?)
	if #url > M.MAX_URL then
		return nil, "the link is too long"
	end
	local rest = string.match(url, "^tern%-netsuite://logs(.*)$")
	if rest == nil then
		return nil, "not a tern-netsuite://logs link"
	end
	if string.find(rest, "#", 1, true) then
		return nil, "a logs link takes no fragment"
	end
	local path, query = string.match(rest, "^([^?]*)%??(.*)$")
	local connect = path == "/connect"
	if not (connect or path == "" or path == "/") then
		return nil, "unknown logs link path " .. quote(path or "")
	end
	local launch: Launch = { connection = nil, scripts = {}, since = nil }
	local seen: Seen = {}
	for pair in string.gmatch(query or "", "[^&]+") do
		local rawKey, rawValue = string.match(pair, "^([^=]*)=?(.*)$")
		local key, kerr = decode(rawKey or "")
		if key == nil then
			return nil, kerr
		end
		local value, verr = decode(rawValue or "")
		if value == nil then
			return nil, verr
		end
		if connect and key ~= "connection" then
			return nil, quote(key) .. " is not allowed in a connect link"
		end
		local problem = apply(launch, key, value, seen)
		if problem then
			return nil, problem
		end
	end
	if connect then
		if launch.connection == nil then
			return nil, "a connect link needs connection=<id>"
		end
		return { block = M.CONNECT_BLOCK, args = { launch.connection :: string } }, nil
	end
	return { block = M.BLOCK, args = M.toArgs(launch) }, nil
end

-- The link that opens the tail for `launch`.
function M.url(launch: Launch): string
	local kv: { { string } } = {}
	for _, a in M.toArgs(launch) do
		local k, v = string.match(a, "^([^=]*)=(.*)$")
		table.insert(kv, { k :: string, v :: string })
	end
	local q = Encoding.query(kv)
	return M.SCHEME .. M.AREA .. (if q == "" then "" else "?" .. q)
end

-- The link that opens the connect block for `connection`.
function M.connectUrl(connection: string): string
	return M.SCHEME .. M.AREA .. "/connect?connection=" .. Encoding.percent(connection)
end

return M
