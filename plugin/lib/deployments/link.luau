--!strict
-- Links into the deployments view:
--
--   tern-netsuite://deployments[?connection=<id>][&q=<text>]
--     connection  a configured connection id (default: the first one)
--     q           initial text filter (at most MAX_QUERY bytes)
--
-- Any program can print such a link, so the block it opens starts held
-- (block arg `hold=1`): it shows the connection and queries nothing until
-- the user presses Enter. The palette command starts at once. Nothing a
-- link carries can edit a file or open another page: those only follow
-- keys and clicks in the block itself.

local Encoding = require("../ns/encoding")
local LogsLink = require("../monitor/logs/link")

local M = {}

M.SCHEME = "tern-netsuite://"
M.AREA = "deployments"
M.BLOCK = "tern-netsuite.deployments"
M.MAX_URL = 2048
M.MAX_QUERY = 200
M.HOLD_ARG = "hold=1"

export type Launch = { connection: string?, query: string?, hold: boolean? }

export type Decision = { block: string, args: { string } }

local function quote(v: string): string
	local short = if #v > 60 then string.sub(v, 1, 57) .. "..." else v
	return string.format("%q", short)
end

type Seen = { [string]: boolean }

local function apply(launch: Launch, key: string, value: string, seen: Seen): string?
	if seen[key] then
		return string.format("%q is given more than once", key)
	end
	seen[key] = true
	if string.find(value, "%c") then
		return string.format("%s has a control character", key)
	end
	if key == "connection" then
		if not LogsLink.validConnection(value) then
			return "invalid connection " .. quote(value)
		end
		launch.connection = value
	elseif key == "q" then
		if #value > M.MAX_QUERY then
			return string.format("q is longer than %d bytes", M.MAX_QUERY)
		end
		launch.query = value
	else
		return "unknown parameter " .. quote(key)
	end
	return nil
end

function M.toArgs(launch: Launch): { string }
	local out: { string } = {}
	if launch.connection then
		table.insert(out, "connection=" .. launch.connection)
	end
	if launch.query and launch.query ~= "" then
		table.insert(out, "q=" .. launch.query)
	end
	if launch.hold then
		table.insert(out, M.HOLD_ARG)
	end
	return out
end

-- The launch block args describe; invalid ones are left out and named in
-- `problems`. `hold=1` is a block arg only.
function M.fromArgs(args: { string }): (Launch, { string })
	local launch: Launch = {}
	local problems: { string } = {}
	local seen: Seen = {}
	for _, a in args do
		local key, value = string.match(a, "^([^=]*)=(.*)$")
		local problem: string? = nil
		if a == M.HOLD_ARG then
			launch.hold = true
		elseif key and value then
			problem = apply(launch, key, value, seen)
		else
			problem = "unknown argument " .. quote(a)
		end
		if problem then
			table.insert(problems, problem)
		end
	end
	return launch, problems
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

-- The block to open for a `tern-netsuite://deployments...` URL (always
-- held), or nil and why.
function M.route(url: string): (Decision?, string?)
	if #url > M.MAX_URL then
		return nil, "the link is too long"
	end
	local rest = string.match(url, "^tern%-netsuite://deployments(.*)$")
	if rest == nil then
		return nil, "not a tern-netsuite://deployments link"
	end
	if string.find(rest, "#", 1, true) then
		return nil, "a deployments link takes no fragment"
	end
	local path, query = string.match(rest, "^([^?]*)%??(.*)$")
	if not (path == "" or path == "/") then
		return nil, "unknown deployments link path " .. quote(path or "")
	end
	local launch: Launch = { hold = true }
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
		local problem = apply(launch, key, value, seen)
		if problem then
			return nil, problem
		end
	end
	return { block = M.BLOCK, args = M.toArgs(launch) }, nil
end

-- The (held) link for `launch`.
function M.url(launch: Launch): string
	local kv: { { string } } = {}
	if launch.connection then
		table.insert(kv, { "connection", launch.connection :: string })
	end
	if launch.query and launch.query ~= "" then
		table.insert(kv, { "q", launch.query :: string })
	end
	local q = Encoding.query(kv)
	return M.SCHEME .. M.AREA .. (if q == "" then "" else "?" .. q)
end

return table.freeze(M)
