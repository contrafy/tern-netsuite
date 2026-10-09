--!strict
-- Pure core of the Doctor block: which checks run, what their answers mean
-- and how they render. The host (doctor_host.luau) performs the effects
-- (config load, project scan, processes) and feeds results back as
-- messages tagged with the run's generation, so answers from a run the user
-- restarted with `r` are dropped.

local Classify = require("./classify")
local Config = require("../config")
local Context = require("./context")
local Manageauth = require("./manageauth")
local ui = require("../ui")

type Config = Config.Config
type Diagnostic = Config.Diagnostic
type Account = Config.Account
type Context = Context.Context
type Node = ui.Node

export type Step = "which" | "version" | "java" | "list" | "info"
export type Severity = "ok" | "info" | "warning" | "error" | "pending"

export type Check = {
	id: string,
	title: string,
	severity: Severity,
	detail: string,
	hint: string?,
	-- The auth id points at a production account.
	production: boolean?,
}

type Probe = { done: boolean, value: string?, error: string? }
type InfoResult = { done: boolean, info: Manageauth.Info?, error: string? }

export type State = {
	gen: number,
	cwd: string?,
	config: Config?,
	diagnostics: { Diagnostic },
	configPath: string?,
	configStatus: string?,
	scanned: boolean,
	context: Context?,
	projects: { Context },
	program: string?,
	which: Probe,
	version: Probe,
	java: Probe,
	list: Probe,
	entries: { Manageauth.Entry },
	infosRequested: boolean,
	infos: { [string]: InfoResult },
}

export type Effect = {
	t: "config" | "scan" | "run" | "exit",
	gen: number,
	cwd: string?,
	step: Step?,
	argv: { string },
	authId: string?,
	timeoutMs: number?,
}

export type Msg =
	{ t: "config", gen: number, config: Config, diagnostics: { Diagnostic }, path: string?, status: string }
	| { t: "scanned", gen: number, context: Context?, projects: { Context } }
	| {
		t: "ran",
		gen: number,
		step: Step,
		authId: string?,
		status: number,
		stdout: string,
		stderr: string,
		timedOut: boolean,
	}
	| { t: "key", name: string }

local M = {}

-- What CLI 3.2.0 checks before starting its Java SDK (ApplicationConstants
-- SDK_COMPATIBLE_JAVA_VERSIONS); every account command needs it.
M.JAVA_VERSIONS = { "17", "21" }

-- The CLI starts a JVM for account commands, so they get more time.
M.TIMEOUT_MS = table.freeze({ which = 5000, version = 15000, java = 10000, list = 60000, info = 60000 })

local SETUP_HINT = "Run `suitecloud account:setup` in an SDF project and save the credentials under this auth ID."

local function pending(): Probe
	return { done = false, value = nil, error = nil }
end

function M.init(args: { cwd: string? }): (State, { Effect })
	local s: State = {
		gen = 1,
		cwd = args.cwd,
		config = nil,
		diagnostics = {},
		configPath = nil,
		configStatus = nil,
		scanned = false,
		context = nil,
		projects = {},
		program = nil,
		which = pending(),
		version = pending(),
		java = pending(),
		list = pending(),
		entries = {},
		infosRequested = false,
		infos = {},
	}
	return s, M.start(s)
end

function M.start(s: State): { Effect }
	return {
		{ t = "config", gen = s.gen, argv = {} },
		{ t = "scan", gen = s.gen, cwd = s.cwd, argv = {} },
	}
end

local function run(s: State, step: Step, argv: { string }, authId: string?): Effect
	return { t = "run", gen = s.gen, step = step, argv = argv, authId = authId, timeoutMs = M.TIMEOUT_MS[step] }
end

-- Auth ids from the config, in config order, with their account.
local function configured(cfg: Config?): { { authId: string, account: Account } }
	local out = {}
	if cfg == nil then
		return out
	end
	for _, a in cfg.accounts do
		for _, id in a.auth_ids do
			table.insert(out, { authId = id, account = a })
		end
	end
	return out
end

-- Auth ids the scanned projects use that no account lists, with the projects using each.
local function referenced(s: State): ({ string }, { [string]: { string } })
	local cfg = s.config
	local order: { string } = {}
	local users: { [string]: { string } } = {}
	local all = table.clone(s.projects)
	if s.context then
		table.insert(all, 1, s.context)
	end
	for _, p in all do
		local id = p.authId
		if id and not (cfg and Classify.authId(id, cfg)) then
			if users[id] == nil then
				users[id] = {}
				table.insert(order, id)
			end
			if not table.find(users[id], p.projectName) then
				table.insert(users[id], p.projectName)
			end
		end
	end
	return order, users
end

local function listed(s: State, authId: string): boolean
	for _, e in s.entries do
		if e.authId == authId then
			return true
		end
	end
	return false
end

-- --info runs once both the auth id list and the project scan are in.
local function requestInfos(s: State, effects: { Effect })
	if s.infosRequested or not s.list.done or not s.scanned or s.config == nil or s.which.value == nil then
		return
	end
	s.infosRequested = true
	local ids: { string } = {}
	for _, c in configured(s.config) do
		if not table.find(ids, c.authId) then
			table.insert(ids, c.authId)
		end
	end
	for _, id in (referenced(s)) do
		if not table.find(ids, id) then
			table.insert(ids, id)
		end
	end
	for _, id in ids do
		if listed(s, id) then
			s.infos[id] = { done = false, info = nil, error = nil }
			table.insert(effects, run(s, "info", { s.which.value :: string, "account:manageauth", "--info", id }, id))
		end
	end
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") :: string
end

local function failure(status: number, stdout: string, stderr: string, timedOut: boolean, ms: number?): string
	if timedOut then
		return string.format("timed out after %d s", math.floor((ms or 0) / 1000))
	end
	local why = Manageauth.errorText(Manageauth.lines(stderr .. "\n" .. stdout))
	return string.format("exit %d%s", status, if why then ": " .. why else "")
end

local function javaVersion(text: string): string?
	return string.match(text, 'version "([^"]+)"')
end

local function javaMajor(version: string): string
	local first, second = string.match(version, "^(%d+)%.?(%d*)")
	if first == "1" and second and second ~= "" then
		return second
	end
	return first or version
end

local function onRan(s: State, msg: any, effects: { Effect })
	local step: Step = msg.step
	local ok = msg.status == 0 and not msg.timedOut
	local why = if ok then nil else failure(msg.status, msg.stdout, msg.stderr, msg.timedOut, M.TIMEOUT_MS[step])
	if step == "which" then
		local path = if ok then string.match(msg.stdout, "^([^\n]+)") else nil
		if path == nil then
			local err = "not found on the PATH Tern runs commands with"
			s.which = { done = true, value = nil, error = err }
			s.version = { done = true, value = nil, error = "the CLI was not found" }
			s.list = { done = true, value = nil, error = "the CLI was not found" }
			return
		end
		s.which = { done = true, value = path, error = nil }
		table.insert(effects, run(s, "version", { path, "--version" }))
		table.insert(effects, run(s, "list", { path, "account:manageauth", "--list" }))
	elseif step == "version" then
		local line = if ok then Manageauth.errorText(Manageauth.lines(msg.stdout)) else nil
		s.version = { done = true, value = line, error = if line then nil else why or "printed no version" }
	elseif step == "java" then
		local version = javaVersion(msg.stderr) or javaVersion(msg.stdout)
		s.java = {
			done = true,
			value = version,
			error = if version then nil else why or "printed no version",
		}
	elseif step == "list" then
		local entries = if ok then Manageauth.parseList(Manageauth.lines(msg.stdout)) else nil
		if ok and entries == nil and trim(msg.stdout) == "" then
			entries = {}
		end
		s.entries = entries or {}
		s.list = {
			done = true,
			value = if entries then tostring(#entries) else nil,
			error = if entries then nil else why or "unrecognised output",
		}
		requestInfos(s, effects)
	elseif step == "info" then
		local id: string? = msg.authId
		if id == nil or s.infos[id] == nil then
			return
		end
		local info = if ok then Manageauth.parseInfo(Manageauth.lines(msg.stdout)) else nil
		s.infos[id] = {
			done = true,
			info = info,
			error = if info then nil else why or "unrecognised output",
		}
	end
end

local function copy(s: State): State
	local n = table.clone(s)
	n.infos = table.clone(s.infos)
	return n
end

function M.update(prev: State, msg: Msg): (State, { Effect })
	local effects: { Effect } = {}
	if msg.t == "key" then
		if msg.name == "r" then
			local s, fx = M.init({ cwd = prev.cwd })
			s.gen = prev.gen + 1
			for _, e in fx do
				e.gen = s.gen
			end
			return s, fx
		elseif msg.name == "escape" then
			return prev, { { t = "exit", gen = prev.gen, argv = {} } }
		end
		return prev, effects
	end
	if msg.gen ~= prev.gen then
		return prev, effects
	end
	local s = copy(prev)
	if msg.t == "config" then
		s.config = msg.config
		s.diagnostics = msg.diagnostics
		s.configPath = msg.path
		s.configStatus = msg.status
		s.program = msg.config.suitecloud.program
		table.insert(effects, run(s, "which", { "sh", "-c", 'command -v -- "$1"', "sh", s.program :: string }))
		table.insert(effects, run(s, "java", { "java", "-version" }))
	elseif msg.t == "scanned" then
		s.scanned = true
		s.context = msg.context
		s.projects = msg.projects
		requestInfos(s, effects)
	elseif msg.t == "ran" then
		onRan(s, msg, effects)
	end
	return s, effects
end

-- Checks ----------------------------------------------------------------------

local function probeCheck(id: string, title: string, p: Probe, okDetail: (string) -> string, hint: string): Check
	if not p.done then
		return { id = id, title = title, severity = "pending", detail = "checking…" }
	end
	if p.value then
		return { id = id, title = title, severity = "ok", detail = okDetail(p.value) }
	end
	return { id = id, title = title, severity = "error", detail = p.error or "failed", hint = hint }
end

local function javaCheck(s: State): Check
	local supported = table.concat(M.JAVA_VERSIONS, " or ")
	local hint = "Install JDK " .. supported .. " on the PATH Tern runs commands with: the CLI runs its SDK on Java."
	local c = probeCheck("java", "Java", s.java, function(v)
		return "java " .. v
	end, hint)
	local v = s.java.value
	if v and not table.find(M.JAVA_VERSIONS, javaMajor(v)) then
		return {
			id = "java",
			title = "Java",
			severity = "error",
			detail = "java " .. v .. " is not supported by the SuiteCloud CLI (needs " .. supported .. ")",
			hint = hint,
		}
	end
	return c
end

local function configChecks(s: State, out: { Check })
	if s.config == nil then
		table.insert(out, { id = "config", title = "Config", severity = "pending", detail = "loading…" })
		return
	end
	local path = s.configPath or "(no config path: neither XDG_CONFIG_HOME nor HOME is set)"
	if s.configStatus == "missing" then
		table.insert(out, {
			id = "config",
			title = "Config",
			severity = "info",
			detail = "no file at " .. path .. "; defaults apply",
			hint = "Run 'Tern NetSuite: Open config'; examples/config.json shows every key.",
		})
	else
		table.insert(out, {
			id = "config",
			title = "Config",
			severity = if s.configStatus == "loaded" then "ok" else "warning",
			detail = (s.configStatus or "?") .. ": " .. path,
		})
	end
	for i, d in s.diagnostics do
		local where = if d.path == "" then "" else d.path .. ": "
		table.insert(out, {
			id = "config:" .. i,
			title = "Config",
			severity = d.level,
			detail = where .. d.message,
		})
	end
	if #s.config.accounts == 0 then
		table.insert(out, {
			id = "accounts",
			title = "Accounts",
			severity = "info",
			detail = "no accounts configured: every auth id resolves through the CLI",
			hint = "Add accounts (id, account_id, auth_ids, production) so production is labelled and guarded explicitly.",
		})
	end
end

local function projectCheck(s: State): Check
	if not s.scanned then
		return { id = "project", title = "Project", severity = "pending", detail = "scanning…" }
	end
	local ctx = s.context
	if ctx == nil then
		return {
			id = "project",
			title = "Project",
			severity = "info",
			detail = (s.cwd or "the focused pane's directory") .. " is not inside an SDF project",
		}
	end
	if ctx.authId == nil then
		return {
			id = "project",
			title = "Project " .. ctx.projectName,
			severity = "warning",
			detail = ctx.problem or "no default auth id",
			hint = "Run `suitecloud account:setup` in " .. ctx.projectRoot .. " to pick an auth ID.",
		}
	end
	return {
		id = "project",
		title = "Project " .. ctx.projectName,
		severity = "ok",
		detail = ctx.projectRoot .. " deploys with auth id " .. ctx.authId,
	}
end

local function describeInfo(info: Manageauth.Info): string
	local parts = { info.accountId or "unknown account" }
	if info.kind then
		table.insert(parts, "(" .. info.kind .. ")")
	end
	if info.role then
		table.insert(parts, "as " .. info.role)
	end
	return table.concat(parts, " ")
end

local function authCheck(s: State, authId: string, account: Account?, users: { string }?): Check
	local cfg = s.config :: Config
	local id = "auth:" .. authId
	local title = "Auth ID " .. authId
	local usedBy = if users then "used by " .. table.concat(users, ", ") .. "; " else ""
	local unconfigured = if account
		then ""
		else "not in any configured account, so it resolves through `manageauth --info` only (unknown counts as production)"
	local unconfiguredHint = "Add it to the auth_ids of its account in the config."
	if not s.list.done then
		return { id = id, title = title, severity = "pending", detail = usedBy .. "checking…" }
	end
	if s.list.error then
		return {
			id = id,
			title = title,
			severity = "warning",
			detail = usedBy .. "not checked: the auth id list failed",
		}
	end
	if not listed(s, authId) then
		return {
			id = id,
			title = title,
			severity = "error",
			detail = usedBy .. "not set up on this machine (missing from `manageauth --list`)",
			hint = SETUP_HINT,
		}
	end
	local r = s.infos[authId]
	if r == nil or not r.done then
		if account == nil then
			return {
				id = id,
				title = title,
				severity = "warning",
				detail = usedBy .. "checking `manageauth --info`…; " .. unconfigured,
				hint = unconfiguredHint,
			}
		end
		return { id = id, title = title, severity = "pending", detail = usedBy .. "checking…" }
	end
	local info = r.info
	if info == nil then
		return {
			id = id,
			title = title,
			severity = "error",
			detail = usedBy .. "`manageauth --info` failed: " .. (r.error or "?"),
			hint = SETUP_HINT,
		}
	end
	local accountId = info.accountId
	if account and accountId and accountId ~= account.account_id then
		return {
			id = id,
			title = title,
			severity = "error",
			detail = string.format(
				"points at %s but the config lists it under account %q (%s)",
				accountId,
				account.id,
				account.account_id
			),
			hint = "Fix accounts[].account_id or the auth_ids list; the status line and guard trust the config.",
		}
	end
	local production = if accountId then Classify.account(accountId, cfg).production else true
	if account == nil then
		return {
			id = id,
			title = title,
			severity = "warning",
			detail = usedBy .. describeInfo(info) .. "; " .. unconfigured,
			hint = unconfiguredHint,
			production = production,
		}
	end
	return {
		id = id,
		title = title,
		severity = "ok",
		detail = string.format("account %s: %s", account.label or account.id, describeInfo(info)),
		production = production,
	}
end

function M.checks(s: State): { Check }
	local out: { Check } = {}
	local program = s.program or "suitecloud"
	table.insert(
		out,
		probeCheck("program", "SuiteCloud CLI", s.which, function(path)
			return program .. " -> " .. path
		end, "Install it (npm install -g @oracle/suitecloud-cli) or set suitecloud.program to its absolute path.")
	)
	table.insert(
		out,
		probeCheck("version", "CLI version", s.version, function(v)
			return v
		end, "Run `" .. program .. " --version` in a terminal to see why it fails.")
	)
	table.insert(out, javaCheck(s))
	configChecks(s, out)
	table.insert(out, projectCheck(s))
	table.insert(
		out,
		probeCheck("list", "Auth IDs", s.list, function(n)
			return n .. " auth id(s) set up on this machine"
		end, "Run `" .. program .. " account:manageauth --list` in a terminal to see why it fails.")
	)
	if s.config then
		local seen: { [string]: boolean } = {}
		for _, c in configured(s.config) do
			if not seen[c.authId] then
				seen[c.authId] = true
				table.insert(out, authCheck(s, c.authId, c.account, nil))
			end
		end
		local order, users = referenced(s)
		for _, authId in order do
			if not seen[authId] then
				table.insert(out, authCheck(s, authId, nil, users[authId]))
			end
		end
	end
	return out
end

-- View ------------------------------------------------------------------------

local TONE: { [string]: string } = {
	ok = "success",
	info = "info",
	warning = "warning",
	error = "error",
	pending = "muted",
}

function M.title(_s: State): string
	return "NetSuite Doctor"
end

local function row(c: Check): Node
	local head: { Node } = { ui.badge(c.severity, TONE[c.severity], { key = "sev" }) }
	if c.production then
		table.insert(head, ui.badge("PROD", "error", { key = "prod" }))
	end
	table.insert(head, ui.text({ ui.span(c.title, "strong") }, { key = "title" }))
	local body: { Node } = { ui.row(head, { key = "head" }), ui.text({ c.detail }, { key = "detail" }) }
	if c.hint and c.severity ~= "ok" then
		table.insert(body, ui.muted(c.hint, { key = "hint" }))
	end
	return ui.col(body, { key = c.id, gap = "xs" })
end

function M.view(s: State): { main: Node, dock: Node }
	local checks = M.checks(s)
	local counts: { [string]: number } = {}
	for _, c in checks do
		counts[c.severity] = (counts[c.severity] or 0) + 1
	end
	local summary: { Node } = {}
	local order: { Severity } = { "error", "warning", "pending" }
	for _, sev in order do
		local n = counts[sev]
		if n then
			table.insert(summary, ui.badge(n .. " " .. sev, TONE[sev], { key = "n-" .. sev }))
		end
	end
	if #summary == 0 then
		table.insert(summary, ui.badge("all good", "success", { key = "n-ok" }))
	end
	local rows: { Node } = { ui.row(summary, { key = "summary" }) }
	if s.cwd then
		table.insert(rows, ui.muted(s.cwd, { key = "cwd" }))
	end
	table.insert(rows, ui.rule(nil, { key = "rule" }))
	for _, c in checks do
		table.insert(rows, row(c))
	end
	return {
		main = ui.col(rows, { key = "doctor" }),
		dock = ui.col({
			ui.text({ ui.span("r", "key"), " rerun  ", ui.span("esc", "key"), " close" }, { key = "keys" }),
		}),
	}
end

return M
