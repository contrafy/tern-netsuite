--!strict
-- How a console starts: its block arguments and its links.
--
-- Block args (palette commands, link routes):
--   cwd=<dir>          the pane it was opened from: relative saved_dirs
--                      resolve in its repository, exported files go there
--   connection=<id>    the connection to select
--   file=<path>.sql    load this file into the editor
--   saved=<name>       load this saved query into the editor
--   run=1              run what was loaded at once (palette only)
--   pick=1             open the saved-query picker
--
--   tern-netsuite://console[?connection=<id>][&file=<absolute .sql path>]
--     opens a console with the file loaded; any program can print one, so
--     it never runs anything: the user presses Ctrl+Enter. `run` and
--     `saved` are block args only. Everything is validated strictly:
--     unknown parameters, fragments, other paths, repeated values and
--     malformed escapes are refused.

local Encoding = require("../ns/encoding")

local M = {}

M.SCHEME = "tern-netsuite://"
M.AREA = "console"
M.BLOCK = "tern-netsuite.console"
M.MAX_URL = 2048
M.MAX_PATH = 1024

export type Launch = {
	cwd: string?,
	connection: string?,
	file: string?,
	saved: string?,
	run: boolean?,
	pick: boolean?,
}

export type Decision = { block: string, args: { string } }

local function quote(v: string): string
	local short = if #v > 60 then string.sub(v, 1, 57) .. "..." else v
	return string.format("%q", short)
end

function M.validConnection(id: string): boolean
	return #id <= 48 and string.find(id, "^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function absolute(path: string): boolean
	return string.sub(path, 1, 1) == "/" and #path <= M.MAX_PATH and not string.find(path, "%c")
end

function M.validFile(path: string): boolean
	return absolute(path) and string.lower(string.sub(path, -4)) == ".sql" and #path > 5
end

type Seen = { [string]: boolean }

-- Applies one `key=value`; returns the problem, if any. `link` limits the
-- keys to those a link may carry.
local function apply(launch: Launch, key: string, value: string, seen: Seen, link: boolean): string?
	if seen[key] then
		return string.format("%q is given more than once", key)
	end
	seen[key] = true
	if string.find(value, "%c") then
		return string.format("%s has a control character", key)
	end
	if key == "connection" then
		if not M.validConnection(value) then
			return "invalid connection " .. quote(value)
		end
		launch.connection = value
	elseif key == "file" then
		if not M.validFile(value) then
			return "file must be an absolute path to a .sql file, not " .. quote(value)
		end
		launch.file = value
	elseif key == "cwd" and not link then
		if not absolute(value) then
			return "cwd must be an absolute path, not " .. quote(value)
		end
		launch.cwd = value
	elseif key == "saved" and not link then
		if value == "" or #value > 200 then
			return "invalid saved query name " .. quote(value)
		end
		launch.saved = value
	elseif key == "run" and not link then
		if value ~= "1" then
			return "run takes 1"
		end
		launch.run = true
	elseif key == "pick" and not link then
		if value ~= "1" then
			return "pick takes 1"
		end
		launch.pick = true
	else
		return "unknown parameter " .. quote(key)
	end
	return nil
end

-- The launch the block args describe; invalid ones are left out and named
-- in `problems`.
function M.fromArgs(args: { string }): (Launch, { string })
	local launch: Launch = {}
	local problems: { string } = {}
	local seen: Seen = {}
	for _, a in args do
		local key, value = string.match(a, "^([^=]*)=(.*)$")
		local problem = if key and value
			then apply(launch, key, value, seen, false)
			else "unknown argument " .. quote(a)
		if problem then
			table.insert(problems, problem)
		end
	end
	if launch.file and launch.saved then
		table.insert(problems, "file and saved are both given; the file is loaded")
		launch.saved = nil
	end
	return launch, problems
end

function M.toArgs(launch: Launch): { string }
	local out: { string } = {}
	if launch.cwd then
		table.insert(out, "cwd=" .. launch.cwd)
	end
	if launch.connection then
		table.insert(out, "connection=" .. launch.connection)
	end
	if launch.file then
		table.insert(out, "file=" .. launch.file)
	end
	if launch.saved then
		table.insert(out, "saved=" .. launch.saved)
	end
	if launch.run then
		table.insert(out, "run=1")
	end
	if launch.pick then
		table.insert(out, "pick=1")
	end
	return out
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

-- The block a `tern-netsuite://console...` URL opens (`cwd` is the clicked
-- pane's directory, when known), or nil and why.
function M.route(url: string, cwd: string?): (Decision?, string?)
	if #url > M.MAX_URL then
		return nil, "the link is too long"
	end
	local rest = string.match(url, "^tern%-netsuite://console(.*)$")
	if rest == nil then
		return nil, "not a tern-netsuite://console link"
	end
	if string.find(rest, "#", 1, true) then
		return nil, "a console link takes no fragment"
	end
	local path, query = string.match(rest, "^([^?]*)%??(.*)$")
	if not (path == "" or path == "/") then
		return nil, "unknown console link path " .. quote(path or "")
	end
	local launch: Launch = {}
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
		local problem = apply(launch, key, value, seen, true)
		if problem then
			return nil, problem
		end
	end
	if cwd and absolute(cwd) then
		launch.cwd = cwd
	end
	return { block = M.BLOCK, args = M.toArgs(launch) }, nil
end

return M
