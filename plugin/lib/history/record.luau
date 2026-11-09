--!strict
-- One local deploy or upload as a line of `<plugin data>/history.jsonl`.
-- The account is the one project.json pointed at when the command finished;
-- an auth id the config does not list and the CLI did not resolve in time is
-- recorded as unknown, never guessed.

local Context = require("../account/context")
local Encoding = require("../ns/encoding")
local Git = require("./git")
local Recognize = require("./recognize")
local Resolve = require("../account/resolve")

export type Record = {
	-- Unix seconds when the command finished / started.
	at: number,
	startedAt: number,
	cwd: string,
	command: string,
	line: string,
	-- nil when the line's exit status may not be the deploy's
	-- (`suitecloud project:deploy | tee log`).
	status: number?,
	tookMs: number,
	project: string?,
	root: string?,
	authId: string?,
	accountId: string?,
	accountLabel: string?,
	-- nil when the account is unknown.
	production: boolean?,
	accountSource: Resolve.Source?,
	branch: string?,
	head: string?,
	dirty: boolean?,
	repoRoot: string?,
	-- Absolute path of the command's `--log` file.
	log: string?,
}

export type Input = {
	finishedAt: number,
	tookMs: number,
	-- The whole line's exit status.
	status: number,
	line: string,
	cwd: string,
	match: Recognize.Match,
	context: Context.Context?,
	resolution: Resolve.Resolution?,
	git: Git.Info?,
}

local M = {}

M.VERSION = 1
-- Bytes of the command line kept; the rest is cut with an ellipsis.
M.MAX_LINE = 2000

-- Record field -> JSON key.
local KEYS: { { string } } = {
	{ "at", "at" },
	{ "startedAt", "started_at" },
	{ "cwd", "cwd" },
	{ "command", "command" },
	{ "line", "line" },
	{ "status", "status" },
	{ "tookMs", "took_ms" },
	{ "project", "project" },
	{ "root", "root" },
	{ "authId", "auth_id" },
	{ "accountId", "account_id" },
	{ "accountLabel", "account_label" },
	{ "production", "production" },
	{ "accountSource", "account_source" },
	{ "branch", "branch" },
	{ "head", "head" },
	{ "dirty", "dirty" },
	{ "repoRoot", "repo_root" },
	{ "log", "log" },
}

local NUMBERS: { [string]: boolean } = { at = true, startedAt = true, tookMs = true }
local OPTIONAL_NUMBERS: { [string]: boolean } = { status = true }
local BOOLEANS: { [string]: boolean } = { production = true, dirty = true }
local SOURCES: { [string]: boolean } = { configured = true, cli = true, unknown = true }

local ELLIPSIS = "…"

local function cap(line: string): string
	if #line <= M.MAX_LINE then
		return line
	end
	local cut = string.sub(line, 1, M.MAX_LINE - #ELLIPSIS)
	-- Do not end inside a UTF-8 sequence.
	while #cut > 0 do
		local b = string.byte(cut, #cut)
		if b < 0x80 then
			break
		end
		cut = string.sub(cut, 1, #cut - 1)
		if b >= 0xC0 then
			break
		end
	end
	return cut .. ELLIPSIS
end

-- `NAME=value` words often carry tokens, and the shell takes them as
-- assignments after `export`/`env`/`declare`, inside subshells and groups,
-- after `&` or a newline: the value of every such word is replaced before
-- anything reaches the history file, wherever it sits in the line. Words are
-- cut where Recognize cuts commands, so `(TOKEN=x` is seen as `TOKEN=x`.
local function redactAssignments(line: string): string
	local parts: { string } = {}
	local i, n = 1, #line
	while i <= n do
		local gap = string.match(line, "^[%s;|&(){}!]+", i)
		if gap then
			table.insert(parts, gap)
			i += #gap
		else
			local j = i
			while j <= n do
				local c = string.sub(line, j, j)
				if string.find(c, "^[%s;|&()]") then
					break
				elseif c == "'" then
					local close = string.find(line, "'", j + 1, true)
					j = if close then close + 1 else n + 1
				elseif c == '"' then
					j += 1
					while j <= n and string.sub(line, j, j) ~= '"' do
						j += if string.sub(line, j, j) == "\\" then 2 else 1
					end
					j += 1
				elseif c == "\\" then
					j += 2
				else
					j += 1
				end
			end
			local word = string.sub(line, i, j - 1)
			local name = string.match(word, "^([%a_][%w_]*)=")
			table.insert(parts, if name then name .. "=" .. ELLIPSIS else word)
			i = j
		end
	end
	return table.concat(parts)
end

local function absolute(path: string, cwd: string): string
	return if string.sub(path, 1, 1) == "/" then path else cwd .. "/" .. path
end

function M.build(input: Input): Record
	local inv = input.match.invocation
	local cwd = input.cwd
	local ctx = input.context
	local res = input.resolution
	local git: Git.Info = input.git or {}
	local logFlag = inv.flags.log
	local r: Record = {
		at = input.finishedAt,
		startedAt = input.finishedAt - math.floor(input.tookMs / 1000 + 0.5),
		cwd = cwd,
		command = input.match.command,
		line = cap(redactAssignments(input.line)),
		status = Recognize.status(input.match, input.status),
		tookMs = input.tookMs,
		project = if ctx then ctx.projectName else nil,
		root = if ctx then ctx.projectRoot else nil,
		authId = if ctx then ctx.authId else nil,
		branch = git.branch,
		head = git.head,
		dirty = git.dirty,
		repoRoot = git.root,
		log = if type(logFlag) == "string" and logFlag ~= "" then absolute(logFlag, cwd) else nil,
	}
	if r.authId and res and res.authId == r.authId then
		r.accountSource = res.source
		if res.source ~= "unknown" then
			r.accountId = res.accountId
			r.accountLabel = res.label
			r.production = res.production
		end
	elseif r.authId then
		r.accountSource = "unknown"
	end
	return r
end

-- One JSON line, newline-terminated.
function M.encode(r: Record): string
	local doc: { [string]: any } = { v = M.VERSION }
	local rec = r :: any
	for _, pair in KEYS do
		local v = rec[pair[1]]
		if v ~= nil then
			doc[pair[2]] = v
		end
	end
	return Encoding.json(doc) .. "\n"
end

function M.decode(line: string, decode: (string) -> any): Record?
	local ok, doc = pcall(decode, line)
	if not ok or type(doc) ~= "table" or doc.v ~= M.VERSION then
		return nil
	end
	local out: { [string]: any } = {}
	for _, pair in KEYS do
		local field, key = pair[1], pair[2]
		local v = doc[key]
		if NUMBERS[field] then
			if type(v) ~= "number" then
				return nil
			end
		elseif OPTIONAL_NUMBERS[field] then
			if type(v) ~= "number" then
				v = nil
			end
		elseif BOOLEANS[field] then
			if type(v) ~= "boolean" then
				v = nil
			end
		elseif type(v) ~= "string" then
			v = nil
		end
		out[field] = v
	end
	if
		out.cwd == nil
		or out.line == nil
		or not Recognize.COMMANDS[out.command]
		or (out.accountSource ~= nil and not SOURCES[out.accountSource])
	then
		return nil
	end
	return out :: any
end

return M
