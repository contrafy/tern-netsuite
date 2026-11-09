--!strict
-- Links into the record inspector (read-only, parameterised):
--
--   tern-netsuite://inspect[?connection=<id>][&type=<type>][&id=<id>][&rectype=<n>]
--   tern-netsuite://inspect?[connection=<id>&]ref=<NetSuite UI URL or type:id>
--     connection  a configured connection id (default: the one whose account
--                 a pasted URL names, else the first one)
--     type        a record type (salesorder, customer, item...), a SuiteQL
--                 table (transaction, entity...) or a custom record type
--                 script id (customrecord_x); case-insensitive. Optional: a
--                 link with only an id opens the block asking for the type
--     id          the record's internal id (needed when type or rectype is)
--     rectype     a custom record type's numeric internal id (what custom
--                 record UI URLs carry); instead of type
--     ref         a pasted UI URL or `type:id` (lib/inspector/ref.luau);
--                 instead of type / id / rectype
--   tern-netsuite://inspect/start?grant=<id>
--     inspects what a single-use grant (lib/monitor/grant.luau) describes,
--     at once; the plugin's own chips store the grant (`grantStart`)
--
-- Any program can print a plain link: its block shows what it would read
-- and queries nothing until the user presses Enter (block arg `hold=1`).
-- Everything is validated here, strictly: unknown parameters, fragments,
-- other paths, repeated values and malformed escapes are refused. Values
-- reach SuiteQL only as `?` parameters or as identifiers checked against
-- the catalog (lib/inspector/queries.luau).

local Catalog = require("./catalog")
local Encoding = require("../ns/encoding")
local Grant = require("../monitor/grant")
local Ref = require("./ref")

local M = {}

M.SCHEME = "tern-netsuite://"
M.AREA = "inspect"
M.BLOCK = "tern-netsuite.inspect"
M.MAX_URL = 4096
M.GRANTS_KEY = "inspect.grants"
M.HOLD_ARG = "hold=1"

export type Launch = {
	connection: string?,
	-- Canonical record type (Catalog.Kind.record or a customrecord_ id).
	type: string?,
	id: string?,
	rectype: number?,
	-- Upper-case account id a pasted URL named.
	account: string?,
	hold: boolean?,
}

export type Decision = { block: string, args: { string }, hold: boolean?, grant: string? }

local function quote(v: string): string
	local short = if #v > 60 then string.sub(v, 1, 57) .. "..." else v
	return string.format("%q", short)
end

function M.validConnection(id: string): boolean
	return #id <= 48 and string.find(id, "^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function validAccount(v: string): boolean
	return #v <= 32 and string.find(v, "^[%u%d][%u%d_]*$") ~= nil
end

local function newLaunch(): Launch
	return { connection = nil, type = nil, id = nil, rectype = nil, account = nil, hold = nil }
end

type Seen = { [string]: boolean }

local function fromRef(launch: Launch, r: Ref.Ref)
	launch.type = if r.kind then r.kind.record else nil
	launch.id = r.id
	launch.rectype = r.rectype
	launch.account = r.account
end

-- Applies one `key=value`; returns the problem, if any. `ref` and `account`
-- are only accepted from links and block args respectively.
local function apply(launch: Launch, key: string, value: string, seen: Seen, fromLink: boolean): string?
	if string.find(value, "%c") then
		return string.format("%s has a control character", key)
	end
	if seen[key] then
		return quote(key) .. " is given more than once"
	end
	seen[key] = true
	if key == "connection" then
		if not M.validConnection(value) then
			return "invalid connection " .. quote(value)
		end
		launch.connection = value
	elseif key == "type" then
		local k = Catalog.find(value)
		if k == nil then
			return "unknown record type " .. quote(value)
		end
		launch.type = k.record
	elseif key == "id" then
		local id = Ref.id(value)
		if id == nil then
			return "invalid id " .. quote(value) .. " (a positive internal id)"
		end
		launch.id = id
	elseif key == "rectype" then
		local n = if #value <= 9 and string.find(value, "^[1-9]%d*$") then tonumber(value) else nil
		if n == nil then
			return "invalid rectype " .. quote(value)
		end
		launch.rectype = n
	elseif key == "ref" and fromLink then
		local r, err = Ref.parse(value)
		if r == nil then
			return "invalid ref: " .. (err or "?")
		end
		fromRef(launch, r)
	elseif key == "account" and not fromLink then
		if not validAccount(value) then
			return "invalid account " .. quote(value)
		end
		launch.account = value
	else
		return "unknown parameter " .. quote(key)
	end
	return nil
end

-- Cross-parameter rules, after every pair was applied.
local function complete(launch: Launch, seen: Seen): string?
	if seen.ref and (seen.type or seen.id or seen.rectype) then
		return "ref cannot be combined with type, id or rectype"
	end
	if launch.type and launch.rectype then
		return "give type or rectype, not both"
	end
	if (launch.type or launch.rectype) and launch.id == nil then
		return "a record type needs id=<internal id>"
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
	if launch.type then
		table.insert(out, "type=" .. launch.type)
	end
	if launch.rectype then
		table.insert(out, "rectype=" .. string.format("%d", launch.rectype))
	end
	if launch.id then
		table.insert(out, "id=" .. launch.id)
	end
	if launch.account then
		table.insert(out, "account=" .. launch.account)
	end
	if launch.hold then
		table.insert(out, M.HOLD_ARG)
	end
	return out
end

-- The launch block args describe; invalid args are left out and named in
-- `problems`. `hold=1` and `account=` are block args only.
function M.fromArgs(args: { string }): (Launch, { string })
	local launch = newLaunch()
	local problems: { string } = {}
	local seen: Seen = {}
	for _, a in args do
		local key, value = string.match(a, "^([^=]*)=(.*)$")
		local problem: string?
		if a == M.HOLD_ARG then
			launch.hold = true
		elseif key and value then
			problem = apply(launch, key, value, seen, false)
		else
			problem = "unknown argument " .. quote(a)
		end
		if problem then
			table.insert(problems, problem)
		end
	end
	local problem = complete(launch, seen)
	if problem then
		table.insert(problems, problem)
		launch.type, launch.rectype, launch.id = nil, nil, nil
	end
	return launch, problems
end

function M.startUrl(id: string): string
	return M.SCHEME .. M.AREA .. "/start?grant=" .. id
end

-- The decision for a `tern-netsuite://inspect...` URL, or nil and why.
function M.route(url: string): (Decision?, string?)
	if #url > M.MAX_URL then
		return nil, "the link is too long"
	end
	local rest = string.match(url, "^tern%-netsuite://inspect(.*)$")
	if rest == nil then
		return nil, "not a tern-netsuite://inspect link"
	end
	if string.find(rest, "#", 1, true) then
		return nil, "an inspect link takes no fragment"
	end
	local path, query = string.match(rest, "^([^?]*)%??(.*)$")
	if path == "/start" then
		local id = string.match(query or "", "^grant=([a-f0-9]+)$")
		if id == nil or not Grant.validId(id) then
			return nil, "a start link takes only grant=<id>"
		end
		return { block = M.BLOCK, args = {}, grant = id }, nil
	end
	if not (path == "" or path == "/") then
		return nil, "unknown inspect link path " .. quote(path or "")
	end
	local launch = newLaunch()
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
	local problem = complete(launch, seen)
	if problem then
		return nil, problem
	end
	return { block = M.BLOCK, args = M.toArgs(launch), hold = true }, nil
end

-- The block args to open a plain-link decision with.
function M.blockArgs(d: Decision): { string }
	local args = table.clone(d.args)
	if d.hold then
		table.insert(args, M.HOLD_ARG)
	end
	return args
end

-- The plain link for `launch` (held until Enter when clicked outside the
-- plugin; `grantStart` turns it into a start link). `account` is not part
-- of a link: pass the connection instead.
function M.url(launch: Launch): string
	local kv: { { string } } = {}
	for _, a in
		M.toArgs({ connection = launch.connection, type = launch.type, id = launch.id, rectype = launch.rectype })
	do
		local k, v = string.match(a, "^([^=]*)=(.*)$")
		table.insert(kv, { k :: string, v :: string })
	end
	local q = Encoding.query(kv)
	return M.SCHEME .. M.AREA .. (if q == "" then "" else "?" .. q)
end

-- For the plugin's own UI: stores a grant to inspect what `url` describes
-- under id `id`. Returns the start link to open and the grants to store,
-- or nil and why when `url` is not a plain inspect link.
function M.grantStart(url: string, stored: any, id: string, now: number): (string?, Grant.Grants?, string?)
	local d, err = M.route(url)
	if d == nil or d.grant ~= nil then
		return nil, nil, err or "not a plain inspect link"
	end
	return M.startUrl(id), Grant.add(stored, id, d.args, now), nil
end

-- Takes start grant `id`: the block args to start with (validated again),
-- the remaining grants (store them back) and otherwise why not.
function M.takeStart(stored: any, id: string, now: number): ({ string }?, Grant.Grants, string?)
	local data, rest, why = Grant.take(stored, id, now)
	if data == nil then
		return nil,
			rest,
			if why == "expired"
				then "this inspect link expired; click it again"
				else "this inspect link was already used or unknown; click it again"
	end
	if type(data) ~= "table" then
		return nil, rest, "the stored inspect request is malformed"
	end
	local args: { string } = {}
	for _, a in data do
		if type(a) ~= "string" or a == M.HOLD_ARG then
			return nil, rest, "the stored inspect request is malformed"
		end
		table.insert(args, a)
	end
	local _, problems = M.fromArgs(args)
	if #problems > 0 then
		return nil, rest, "the stored inspect request is malformed"
	end
	return args, rest, nil
end

function M.newId(seed: string, counter: number): string
	return Grant.newId("inspect", seed, counter)
end

return M
