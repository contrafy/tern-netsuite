--!strict
-- State and transitions of the approve block (`tern-netsuite.approve`), which
-- answers a request from shell/tern-netsuite-guard. Elm style: `init` and
-- `update` return the new state plus effects for plugin/guard_host.luau to
-- run; results come back as messages. The block never runs the command: it
-- only writes a decision the guard verifies (shell/PROTOCOL.md).
--
-- Every path fails closed: nothing can be approved until the request is
-- known to sit in the plugin's spool and its displayed contents hash to its
-- fingerprint, and a production target needs the typed confirmation.

local Audit = require("./audit")
local Classify = require("../account/classify")
local Config = require("../config")
local Protocol = require("./protocol")

type Config = Config.Config
type Request = Protocol.Request

local M = {}

M.TYPED_INPUT = "main.typed"
-- Requests dated this far in the future are refused.
M.CLOCK_SKEW_S = 60
M.HASH_TIMEOUT_MS = 10000

M.SPOOL_SCRIPT = 'cd -P -- "$1" && pwd -P'
M.HASH_SCRIPT = [[
if command -v sha256sum >/dev/null 2>&1; then exec sha256sum; fi
if command -v shasum >/dev/null 2>&1; then exec shasum -a 256; fi
echo 'neither sha256sum nor shasum is available' >&2
exit 3
]]
M.RESPOND_SCRIPT = 'chmod 600 "$1" 2>/dev/null; mv -f "$1" "$2"'

-- verifying: checks running; ready: may be approved; blocked: a check
-- failed, only Deny; error: nothing can be answered, only Close; expired:
-- the shell stopped waiting.
export type Phase = "verifying" | "ready" | "blocked" | "error" | "responding" | "expired" | "closed"

export type Target = {
	accountId: string?,
	label: string,
	production: boolean,
	-- false: the guard could not resolve the account.
	known: boolean,
	reason: "configured" | "inferred" | "unknown",
	-- What the user types to confirm (shown as the prompt) and every
	-- accepted spelling (compared trimmed and case-insensitively).
	prompt: string,
	tokens: { string },
}

export type Warning = { level: "warning" | "info", text: string }

export type ProcessResult = { status: number, stdout: string, stderr: string, timed_out: boolean }

export type Key = { name: string, text: string?, ctrl: boolean, alt: boolean, shift: boolean, meta: boolean }

export type Effect = {
	t: "run" | "write" | "remove" | "audit" | "focus" | "exit",
	tag: string?,
	gen: number?,
	argv: { string }?,
	stdin: string?,
	timeout_ms: number?,
	path: string?,
	text: string?,
	line: string?,
	id: string?,
}

export type Msg = {
	t: "result" | "key" | "action" | "tick",
	tag: string?,
	gen: number?,
	result: ProcessResult?,
	key: Key?,
	act: string?,
	value: string?,
	now: number?,
	paneAlive: boolean?,
	cancelled: boolean?,
}

export type Init = {
	args: { string },
	now: number,
	-- The plugin's spool directory (tern.plugin.data .. "/spool").
	spool: string,
	request: { text: string?, error: string? }?,
	-- Ids of the live panes; nil skips the requesting pane check.
	panes: { string }?,
	decode: (string) -> any,
	config: Config,
}

export type State = {
	phase: Phase,
	gen: number,
	now: number,
	spool: string,
	request: Request?,
	target: Target?,
	warnings: { Warning },
	errors: { string },
	pending: { [string]: boolean },
	typed: string,
	typedRequired: boolean,
	-- Whether a response may still be written (request valid, in the spool,
	-- not expired, not answered).
	respondable: boolean,
	-- Why the block refuses to approve, sent along with a Deny.
	blockReason: string?,
	confirmError: string?,
	showFiles: boolean,
	decided: boolean,
}

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

local function firstLine(text: string?): string
	for l in string.gmatch(text or "", "[^\n]+") do
		local s = trim(l)
		if s ~= "" then
			return s
		end
	end
	return ""
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

local function exit(s: State, effects: { Effect })
	s.phase = "closed"
	s.pending = {}
	s.respondable = false
	table.insert(effects, { t = "exit" })
end

local function fail(s: State, text: string)
	s.phase = "error"
	s.respondable = false
	s.pending = {}
	table.insert(s.errors, text)
end

local function block(s: State, text: string)
	s.phase = "blocked"
	s.pending = {}
	s.blockReason = text
	table.insert(s.errors, text)
end

function M.target(r: Request, cfg: Config): Target
	local accountId = r.accountId
	if accountId == nil then
		local prompt = r.authId or "production"
		return {
			accountId = nil,
			label = if r.authId then "unknown account (auth ID " .. r.authId .. ")" else "unknown account",
			production = true,
			known = false,
			reason = "unknown",
			prompt = prompt,
			tokens = { prompt },
		}
	end
	local c = Classify.account(accountId, cfg)
	local tokens = { c.label }
	if c.accountId ~= c.label then
		table.insert(tokens, c.accountId)
	end
	return {
		accountId = c.accountId,
		label = c.label,
		production = c.production,
		known = true,
		reason = c.reason,
		prompt = c.label,
		tokens = tokens,
	}
end

function M.warnings(r: Request, target: Target): { Warning }
	local out: { Warning } = {}
	local function warn(text: string)
		table.insert(out, { level = "warning", text = text })
	end
	if not target.known then
		warn("The target account is unknown: the guard could not resolve it, so it is treated as production.")
	end
	local git = r.git
	if git == nil then
		table.insert(
			out,
			{ level = "info", text = "Not in a git repository: no branch or commit to check the deploy against." }
		)
	else
		if git.dirty then
			warn("Uncommitted changes in " .. git.root .. ": the deploy may include work that is not committed.")
		end
		local branch = git.branch
		if branch == nil then
			warn("Detached HEAD: not on a branch.")
		elseif git.defaultBranch and branch ~= git.defaultBranch then
			warn(string.format("On branch %s, not %s.", branch, git.defaultBranch :: string))
		end
		local upstream = git.upstream
		if upstream == nil then
			if branch ~= nil then
				table.insert(
					out,
					{ level = "info", text = "The branch has no upstream: cannot tell whether it is up to date." }
				)
			end
		else
			if (git.behind or 0) > 0 then
				warn(
					string.format(
						"%s behind %s (as of the last fetch): the deploy may overwrite newer changes.",
						plural(git.behind :: number, "commit"),
						upstream
					)
				)
			end
			if (git.ahead or 0) > 0 then
				warn(string.format("%s not pushed to %s.", plural(git.ahead :: number, "commit"), upstream))
			end
		end
	end
	for _, n in r.notes do
		table.insert(out, { level = "info", text = n })
	end
	return out
end

local function emitRun(s: State, effects: { Effect }, tag: string, argv: { string }, stdin: string?)
	s.pending[tag] = true
	table.insert(effects, {
		t = "run",
		tag = tag,
		gen = s.gen,
		argv = argv,
		stdin = stdin,
		timeout_ms = M.HASH_TIMEOUT_MS,
	})
end

local function audit(s: State, effects: { Effect }, decision: Audit.Decision, reason: string?)
	local r = s.request
	local target = s.target
	if r == nil or target == nil then
		return
	end
	local git = r.git
	table.insert(effects, {
		t = "audit",
		line = Audit.line({
			decision = decision,
			decidedAt = s.now,
			command = r.command,
			argv = r.argv,
			cwd = r.cwd,
			folder = r.folder,
			authId = r.authId,
			accountId = target.accountId,
			accountLabel = target.label,
			production = target.production,
			fingerprint = r.fingerprint,
			files = #r.files,
			branch = if git then git.branch else nil,
			head = if git then git.head else nil,
			dirty = if git then git.dirty else nil,
			reason = reason,
		}),
	})
end

local function respond(s: State, effects: { Effect }, decision: Protocol.Decision)
	local r = s.request :: Request
	local final = Protocol.responsePath(r)
	local tmp = final .. ".tmp"
	local reason = if decision == "deny" then s.blockReason else nil
	s.decided = true
	s.respondable = false
	s.phase = "responding"
	s.pending = { respond = true }
	table.insert(effects, {
		t = "write",
		tag = "respond",
		gen = s.gen,
		path = tmp,
		text = Protocol.response({
			nonce = r.nonce,
			decision = decision,
			fingerprint = r.fingerprint,
			account = (s.target :: Target).accountId,
			at = s.now,
			reason = reason,
		}),
		argv = { "/bin/sh", "-c", M.RESPOND_SCRIPT, "tern-netsuite-respond", tmp, final },
	})
	audit(s, effects, if decision == "approve" then "approved" else "denied", reason)
end

-- Whether the typed text confirms the target.
function M.typedMatches(s: State): boolean
	local target = s.target
	if target == nil then
		return false
	end
	local typed = string.lower(trim(s.typed))
	for _, token in target.tokens do
		if typed == string.lower(token) then
			return true
		end
	end
	return false
end

-- Why Approve does nothing right now; nil when it would approve.
function M.approveBlocker(s: State): string?
	if s.phase == "verifying" then
		return "The request is still being checked; wait a moment."
	elseif s.phase == "blocked" then
		return s.blockReason or "This request cannot be approved."
	elseif s.phase == "expired" then
		return "The request expired: the shell stopped waiting."
	elseif s.phase ~= "ready" or not s.respondable then
		return "This request cannot be approved."
	end
	if s.typedRequired and not M.typedMatches(s) then
		return string.format("Type %s to approve.", (s.target :: Target).prompt)
	end
	return nil
end

local function approve(s: State, effects: { Effect })
	local why = M.approveBlocker(s)
	if why then
		s.confirmError = why
		return
	end
	s.confirmError = nil
	respond(s, effects, "approve")
end

-- Deny answers whenever an answer is possible; otherwise it only closes.
local function deny(s: State, effects: { Effect })
	if s.decided or s.phase == "responding" or s.phase == "closed" then
		return
	end
	if s.respondable then
		respond(s, effects, "deny")
	else
		exit(s, effects)
	end
end

local function blank(env: Init): State
	return {
		phase = "verifying",
		gen = 1,
		now = env.now,
		spool = env.spool,
		request = nil,
		target = nil,
		warnings = {},
		errors = {},
		pending = {},
		typed = "",
		typedRequired = false,
		respondable = false,
		blockReason = nil,
		confirmError = nil,
		showFiles = false,
		decided = false,
	}
end

function M.init(env: Init): (State, { Effect })
	local s = blank(env)
	local effects: { Effect } = {}
	local path = env.args[1]
	if path == nil or path == "" then
		fail(s, "The approve block was opened without a request; it only answers the tern-netsuite shell guard.")
		return s, effects
	end
	local file = env.request
	if file == nil or file.text == nil then
		fail(s, "Cannot read the approval request: " .. (if file and file.error then file.error :: string else path))
		return s, effects
	end
	local r, err = Protocol.parse(path, file.text :: string, env.decode)
	if r == nil then
		fail(s, "Refusing the approval request: " .. (err or "malformed"))
		return s, effects
	end
	s.request = r
	local target = M.target(r, env.config)
	s.target = target
	s.warnings = M.warnings(r, target)
	s.typedRequired = env.config.guard.typed_confirmation and target.production
	if s.now > Protocol.deadline(r) then
		fail(s, "The approval request expired (the shell stopped waiting); nothing was approved.")
		return s, effects
	end
	if r.createdAt > s.now + M.CLOCK_SKEW_S then
		fail(s, "The approval request is dated in the future; refusing it.")
		return s, effects
	end
	if env.panes and not table.find(env.panes, r.pane) then
		fail(s, "The pane that asked for approval (" .. r.pane .. ") is gone; nothing to approve.")
		return s, effects
	end
	local canonical, cerr = Protocol.canonical(Protocol.fingerprintInput(r))
	if canonical == nil then
		s.respondable = true
		block(s, "The request cannot be fingerprinted: " .. (cerr or "?"))
		return s, effects
	end
	s.respondable = true
	emitRun(s, effects, "spool", { "/bin/sh", "-c", M.SPOOL_SCRIPT, "tern-netsuite-spool", s.spool })
	emitRun(s, effects, "hash", { "/bin/sh", "-c", M.HASH_SCRIPT, "tern-netsuite-hash" }, canonical)
	return s, effects
end

local function onResult(s: State, tag: string, res: ProcessResult, effects: { Effect })
	local r = s.request :: Request
	if tag == "spool" then
		local dir = string.match(res.stdout, "^(/[^\n]*)")
		if res.status ~= 0 or dir == nil then
			fail(s, "Cannot resolve the plugin's spool directory: " .. firstLine(res.stderr))
		elseif dir ~= r.dir then
			fail(s, string.format("The request is not in this plugin's spool (%s); refusing to answer it.", dir))
		end
	elseif tag == "hash" then
		local digest = string.match(res.stdout, "^(%x+)")
		if res.status ~= 0 or digest == nil or #digest ~= 64 then
			block(
				s,
				"Could not verify the request's fingerprint: "
					.. firstLine(if res.timed_out then "timed out" else res.stderr)
			)
		elseif string.lower(digest) ~= r.fingerprint then
			block(s, "The request's contents do not match its fingerprint; it cannot be approved.")
		end
	elseif tag == "respond" then
		if res.status == 0 then
			exit(s, effects)
		else
			s.phase = "error"
			table.insert(s.errors, "Could not write the response (the shell will refuse): " .. firstLine(res.stderr))
		end
		return
	end
	if s.phase == "verifying" and next(s.pending) == nil then
		s.phase = "ready"
		if s.typedRequired then
			table.insert(effects, { t = "focus", id = M.TYPED_INPUT })
		end
	end
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function typing(s: State): boolean
	return s.typedRequired and (s.phase == "verifying" or s.phase == "ready")
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	local name = key.name
	if name == "escape" then
		deny(s, effects)
		return true
	end
	if name == "enter" or name == "return" then
		approve(s, effects)
		return true
	end
	if not typing(s) then
		return false
	end
	if name == "backspace" then
		s.typed = string.sub(s.typed, 1, -2)
	elseif name == "paste" and key.text then
		s.typed ..= (string.gsub(key.text :: string, "%c", ""))
	else
		local ch = printable(key)
		if ch == nil then
			return false
		end
		s.typed ..= ch
	end
	s.confirmError = nil
	return true
end

function M.update(s: State, msg: Msg): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if msg.now then
		s.now = msg.now :: number
	end
	local t = msg.t
	if t == "result" then
		local tag = msg.tag or ""
		if msg.gen ~= s.gen or not s.pending[tag] or msg.result == nil then
			return s, effects, false
		end
		s.pending[tag] = nil
		onResult(s, tag, msg.result :: ProcessResult, effects)
	elseif t == "key" and msg.key then
		return s, effects, onKey(s, msg.key :: Key, effects)
	elseif t == "action" then
		local act = msg.act
		if act == "approve" then
			approve(s, effects)
		elseif act == "deny" or act == "close" then
			deny(s, effects)
		elseif act == "files" then
			s.showFiles = not s.showFiles
		else
			return s, effects, false
		end
	elseif t == "tick" then
		local r = s.request
		if r == nil or s.decided or s.phase == "closed" then
			return s, effects, false
		end
		if msg.cancelled then
			audit(s, effects, "cancelled")
			table.insert(effects, { t = "remove", path = Protocol.cancelPath(r) })
			exit(s, effects)
		elseif msg.paneAlive == false then
			audit(s, effects, "cancelled")
			exit(s, effects)
		elseif s.now > Protocol.deadline(r) and s.phase ~= "expired" then
			s.phase = "expired"
			s.respondable = false
			s.pending = {}
			s.gen += 1
		else
			return s, effects, false
		end
	end
	return s, effects, true
end

-- What the host's liveness timer must report in `tick` messages.
function M.watch(s: State): { pane: string?, cancelPath: string? }
	local r = s.request
	if r == nil or s.decided or s.phase == "closed" then
		return {}
	end
	return { pane = r.pane, cancelPath = Protocol.cancelPath(r) }
end

return M
