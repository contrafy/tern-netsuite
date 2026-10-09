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
	status: number,
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

local NUMBERS: { [string]: boolean } = { at = true, startedAt = true, status = true, tookMs = true }
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

-- Splits a shell line into words and separators (whitespace runs and the
-- control operators `&&`, `||`, `;`, `|`), keeping quotes inside words.
local function tokens(line: string): { { text: string, sep: string? } }
	local out: { { text: string, sep: string? } } = {}
	local i, n = 1, #line
	while i <= n do
		local ws = string.match(line, "^%s+", i)
		local op = string.match(line, "^&&", i) or string.match(line, "^||", i) or string.match(line, "^[;|]", i)
		if ws then
			table.insert(out, { text = ws, sep = "space" })
			i += #ws
		elseif op then
			table.insert(out, { text = op, sep = "op" })
			i += #op
		else
			local j = i
			while j <= n do
				local c = string.sub(line, j, j)
				if string.find(c, "^%s") or c == ";" or c == "|" or string.sub(line, j, j + 1) == "&&" then
					break
				elseif c == "'" or c == '"' then
					local close = string.find(line, c, j + 1, true)
					j = if close then close + 1 else n + 1
				elseif c == "\\" then
					j += 2
				else
					j += 1
				end
			end
			table.insert(out, { text = string.sub(line, i, j - 1) })
			i = j
		end
	end
	return out
end

-- `NAME=value` words before a command (and after `env`) often carry tokens;
-- their values are replaced before anything reaches the history file.
local function redactAssignments(line: string): string
	local parts: { string } = {}
	local atCommand = true
	for _, tok in tokens(line) do
		if tok.sep == "op" then
			atCommand = true
			table.insert(parts, tok.text)
		elseif tok.sep then
			table.insert(parts, tok.text)
		else
			local name = if atCommand then string.match(tok.text, "^([%a_][%w_]*)=") else nil
			if name then
				table.insert(parts, name .. "=" .. ELLIPSIS)
			else
				table.insert(parts, tok.text)
				atCommand = atCommand and tok.text == "env"
			end
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
		status = input.status,
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
