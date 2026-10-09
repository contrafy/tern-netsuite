--!strict
-- The native view of one SuiteCloud run: outcome, command and target account,
-- then diagnostics grouped by object (errors open, warnings collapsed), what
-- was deployed/uploaded/added, server steps and any output line the parser
-- did not place. `object:list` / `file:list` get a summary by type or
-- folder, a capped list and a chip that opens the account browser block.
-- Pure: returns `{k, p, c}` nodes; nil means "show raw".

local Argv = require("../sdf/argv")
local Classify = require("../account/classify")
local Config = require("../config")
local Listing = require("../sdf/listing")
local LogsLink = require("../monitor/logs/link")
local Output = require("../sdf/output")
local Project = require("../sdf/project")
local Viewstate = require("./viewstate")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
type Result = Output.Result
type Group = Output.Group
type Diagnostic = Output.Diagnostic
type Invocation = Argv.Invocation
type ViewState = Viewstate.ViewState

export type Options = {
	cfg: Config.Config,
	-- The shell's working directory; absolute paths under it are shown relative.
	cwd: string?,
	-- The folder `~/` paths of server logs are relative to (the project's
	-- defaultProjectFolder); unlinked when unknown.
	projectDir: string?,
	-- The command line as the user ran it.
	line: string?,
}

export type TargetView = {
	text: string,
	tone: string,
	title: string,
	-- nil: no account (local run) or the account is unknown.
	production: boolean?,
}

local M = {}

-- Items listed before "show all".
M.MAX_ITEMS = 12

local OUTCOME: { [string]: { [string]: string } } = {
	validate = { ok = "Valid", warnings = "Valid with warnings", failed = "Validation failed" },
	deploy = { ok = "Deployed", warnings = "Deployed with warnings", failed = "Deploy failed" },
	upload = { ok = "Uploaded", warnings = "Uploaded with warnings", failed = "Upload failed" },
	package = { ok = "Packaged", warnings = "Packaged with warnings", failed = "Package failed" },
	adddependencies = { ok = "Dependencies added", warnings = "Dependencies added", failed = "Failed" },
}

local PREVIEW_OUTCOME: { [string]: string } =
	{ ok = "Preview OK", warnings = "Preview with warnings", failed = "Preview failed" }

local TONE: { [string]: string } = { ok = "success", warnings = "warning", failed = "error" }

local ITEMS_TITLE: { [string]: string } = {
	deploy = "Changes",
	upload = "Files",
	adddependencies = "Added to manifest.xml",
}

-- Server log lines that only mark a phase.
local QUIET_NOTES: { [string]: boolean } = {
	["Validation COMPLETE"] = true,
	["Begin deployment"] = true,
	["Installation started"] = true,
	["Deployment preview"] = true,
}

-- The folder `~/` paths are relative to: `cwd/<defaultProjectFolder>` from
-- the text of cwd's suitecloud.config.js; nil when that file is unknown.
function M.projectDir(cwd: string, configText: string?): string?
	if configText == nil then
		return nil
	end
	return cwd .. "/" .. Project.projectFolder(configText)
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function fileUrl(path: string, line: number?): string
	local url = "file://"
		.. string.gsub(path, "[%%#? ]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	return if line then url .. "#L" .. line else url
end

local function nonProduction(kind: string): boolean
	return kind == "SANDBOX" or kind == "RELEASE PREVIEW"
end

-- The account badge for a classified account; `title` says where it came from.
function M.fromClassify(c: Classify.Result, title: string): TargetView
	if c.production then
		return {
			text = if c.label == "PROD" then "PROD" else "PROD " .. c.label,
			tone = "error",
			title = title .. " (production: " .. c.reason .. ")",
			production = true,
		}
	end
	return { text = c.label, tone = "muted", title = title, production = false }
end

-- The account badge. Only what the output (or a configured auth id) says is
-- shown; an account the run does not name stays "unknown", never guessed.
function M.targetView(r: Result, inv: Invocation, cfg: Config.Config): TargetView
	local t = r.target
	if t and t.accountId then
		local parts = { t.accountId }
		if t.accountName then
			table.insert(parts, t.accountName)
		end
		if t.role then
			table.insert(parts, t.role)
		end
		return M.fromClassify(Classify.account(t.accountId, cfg), table.concat(parts, " · "))
	end
	local auth = (t and t.authId) or inv.authId
	if auth then
		local c = Classify.authId(auth, cfg)
		if c then
			return M.fromClassify(c, "auth ID " .. auth .. " · " .. c.accountId)
		end
	end
	if t and t.kind then
		local name = t.accountName or "account"
		if nonProduction(t.kind) then
			return { text = name, tone = "muted", title = t.kind .. " account", production = false }
		end
		return { text = "PROD " .. name, tone = "error", title = t.kind .. " account", production = true }
	end
	if not r.server then
		return { text = "local", tone = "muted", title = "Ran on this machine; no account was contacted" }
	end
	return {
		text = "account unknown",
		tone = "warning",
		title = "The output does not name the account; the CLI uses project.json's defaultAuthId",
	}
end

local function countsText(r: Result): string
	local c = r.counts
	local parts: { string } = {}
	if c.errors > 0 then
		table.insert(parts, plural(c.errors, "error"))
	end
	if c.warnings > 0 then
		table.insert(parts, plural(c.warnings, "warning"))
	end
	if c.objects > 0 then
		table.insert(parts, plural(c.objects, "object"))
	end
	if c.files > 0 then
		table.insert(parts, plural(c.files, "file"))
	end
	if c.dependencies > 0 then
		table.insert(parts, c.dependencies .. (if c.dependencies == 1 then " dependency" else " dependencies"))
	end
	if #r.steps > 0 then
		table.insert(parts, plural(#r.steps, "step"))
	end
	if r.duration then
		table.insert(parts, "in " .. r.duration)
	end
	return table.concat(parts, " · ")
end

-- Display text and link of a printed path.
local function pathSpan(r: Result, path: string, line: number?, opts: Options): Span
	if string.sub(path, 1, 2) == "~/" then
		local dir = opts.projectDir
		return {
			t = path,
			s = "path",
			href = if dir then fileUrl(dir .. "/" .. string.sub(path, 3), line) else nil,
		}
	end
	if r.family == "upload" then
		local dir = opts.projectDir
		return { t = path, s = "path", href = if dir then fileUrl(dir .. "/FileCabinet" .. path) else nil }
	end
	if string.sub(path, 1, 1) ~= "/" then
		return { t = path, s = "path" }
	end
	local shown = path
	local cwd = opts.cwd
	if cwd and string.sub(path, 1, #cwd + 1) == cwd .. "/" then
		shown = string.sub(path, #cwd + 2)
	end
	return { t = shown, s = "path", href = fileUrl(path, line) }
end

local function diagnosticNode(r: Result, d: Diagnostic, showPath: boolean, opts: Options): Node
	local spans: { ui.SpanLike } = {
		ui.span(d.severity, "strong " .. d.severity),
		" ",
		ui.span(d.message, "strong"),
	}
	local children: { Node } = { ui.text(spans) }
	local where: { ui.SpanLike } = {}
	if showPath and d.path then
		table.insert(where, pathSpan(r, d.path, d.line, opts))
		if d.line then
			table.insert(where, ui.span(":" .. d.line, "muted"))
		end
	elseif d.line and d.path then
		local link = pathSpan(r, d.path, d.line, opts)
		table.insert(where, { t = "line " .. d.line, s = "path", href = link.href })
	end
	if d.title and d.title ~= d.message then
		if #where > 0 then
			table.insert(where, "  ")
		end
		table.insert(where, ui.span(d.title, "muted"))
	end
	if #where > 0 then
		table.insert(children, ui.text(where))
	end
	return ui.col(children, { key = d.key, gap = "xs" })
end

local function groupCard(r: Result, g: Group, opts: Options): Node
	local head: { ui.SpanLike } = {}
	if g.objectScriptId then
		table.insert(head, ui.span(g.objectScriptId, "code strong"))
	end
	-- One path for the whole card when every diagnostic shares it.
	local shared = true
	for _, d in g.diagnostics do
		if d.path ~= g.path then
			shared = false
		end
	end
	if g.path and shared then
		if #head > 0 then
			table.insert(head, "  ")
		end
		table.insert(head, pathSpan(r, g.path, nil, opts))
	end
	if #head == 0 then
		table.insert(head, ui.span("project", "strong"))
	end
	local body: { Node } = table.create(#g.diagnostics)
	for i, d in g.diagnostics do
		body[i] = diagnosticNode(r, d, not shared, opts)
	end
	return ui.card(head, body, { key = "g:" .. g.key, tone = g.severity, role = "tern-netsuite.diagnostics" })
end

local function chip(text: string, action: string, title: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, title = title, actions = { click = action } })
end

local function header(r: Result, inv: Invocation, opts: Options): Node
	local target = M.targetView(r, inv, opts.cfg)
	local labels = OUTCOME[r.family]
	local label = if r.preview then PREVIEW_OUTCOME[r.outcome] else labels[r.outcome]
	local top: { Node } = {
		ui.badge(label or r.outcome, TONE[r.outcome] or "neutral", { key = "outcome" }),
		ui.text({ ui.span(opts.line or (inv.launcher .. " " .. inv.command), "mono strong") }, { key = "command" }),
		ui.badge(target.text, target.tone, { key = "target", title = target.title, role = "tern-netsuite.target" }),
	}
	local counts = countsText(r)
	if counts ~= "" then
		table.insert(top, ui.text({ ui.span(counts, "muted") }, { key = "counts" }))
	end
	-- No exit badge: Tern's lens block shows a non-zero exit status itself.
	return ui.row(top, { key = "bar", wrap = true, role = "tern-netsuite.bar" })
end

-- A toggle chip on its own line; a bare badge in a column stretches.
local function toggleRow(chipNode: Node): Node
	return ui.row({ chipNode })
end

-- The account entry the run's target belongs to, when configured.
local function targetAccount(r: Result, inv: Invocation, cfg: Config.Config): Config.Account?
	local t = r.target
	if t and t.accountId then
		return Classify.account(t.accountId, cfg).account
	end
	local auth = (t and t.authId) or inv.authId
	local c = if auth then Classify.authId(auth, cfg) else nil
	return if c then c.account else nil
end

-- Script ids of the deployed script objects (deployments count for their
-- script), validated the way the logs link validates them.
local function deployedScripts(r: Result): { string }
	local out: { string } = {}
	for _, item in r.items do
		if item.kind ~= "object" then
			continue
		end
		local id = LogsLink.script(string.match(item.name, "^[^%.]+") or item.name)
		if id and string.find(id, "^customscript") and not table.find(out, id) then
			table.insert(out, id)
			if #out >= LogsLink.MAX_SCRIPTS then
				break
			end
		end
	end
	return out
end

-- `logs=<url>` for the deploy's scripts, or nil. `since` is relative to the
-- click (the lens has no clock): the deploy's duration plus 30 minutes.
function M.logsAction(r: Result, inv: Invocation, cfg: Config.Config): string?
	if r.family ~= "deploy" or r.preview then
		return nil
	end
	local scripts = deployedScripts(r)
	if #scripts == 0 then
		return nil
	end
	local connection: string? = nil
	local account = targetAccount(r, inv, cfg)
	if account then
		for _, c in cfg.connections do
			if c.account == account.id then
				connection = c.id
				break
			end
		end
	end
	local minutes = 30 + math.ceil((r.seconds or 0) / 60)
	return "logs=" .. LogsLink.url({ connection = connection, scripts = scripts, since = { minutes = minutes } :: any })
end

local function chips(r: Result, inv: Invocation, opts: Options): Node?
	local out: { Node } = {}
	local logs = M.logsAction(r, inv, opts.cfg)
	if logs then
		table.insert(out, chip("Tail logs", logs, "Execution logs of the deployed scripts", "logs", "accent"))
	end
	if r.counts.errors > 0 then
		table.insert(out, chip("Copy errors", "copy=errors", "Copy every error as the CLI printed it", "copy-errors"))
	end
	if r.counts.warnings > 0 then
		table.insert(out, chip("Copy warnings", "copy=warnings", "Copy every warning", "copy-warnings"))
	end
	local local_ = r.family == "validate" and not r.server
	if local_ or (r.outcome == "failed" and (r.family == "deploy" or r.family == "validate")) then
		local cmd = Argv.serverValidate(inv)
		table.insert(
			out,
			chip(
				"Copy: " .. cmd,
				"copy=rerun",
				"Validates against the project's account (read-only); run it in the project folder",
				"copy-rerun"
			)
		)
	end
	if #out == 0 then
		return nil
	end
	return ui.row(out, { key = "chips", wrap = true, role = "tern-netsuite.chips" })
end

local function itemsNode(r: Result, vs: ViewState): Node?
	if #r.items == 0 then
		return nil
	end
	local shown = if vs.items then #r.items else math.min(#r.items, M.MAX_ITEMS)
	local rows: { Node } = table.create(shown)
	for i = 1, shown do
		local item = r.items[i]
		local tone = if item.action == "Not uploaded" then "error" else "muted"
		local spans: { ui.SpanLike } = { ui.span(item.action, tone), " ", ui.span(item.name, "code") }
		if item.objectType then
			table.insert(spans, ui.span(" (" .. item.objectType .. ")", "muted"))
		end
		if item.error then
			table.insert(spans, ui.span("  " .. item.error, "error"))
		end
		rows[i] = ui.text(spans, { key = "item" .. i })
	end
	if #r.items > M.MAX_ITEMS then
		local label = if vs.items then "Show fewer" else "Show all " .. #r.items
		table.insert(
			rows,
			toggleRow(
				chip(label, Viewstate.action(Viewstate.toggled(vs, "items")), "Toggle the full list", "items-toggle")
			)
		)
	end
	local title = if r.preview then "Would change" else ITEMS_TITLE[r.family] or "Items"
	-- A `lines` node inside a section makes Tern 0.6.3 drop the whole view
	-- (raw shown, nothing logged): rows go in directly.
	return ui.section({ ui.span(title, "strong") }, rows, { key = "items" })
end

local function stepsNode(r: Result, vs: ViewState): Node?
	if #r.steps == 0 then
		return nil
	end
	local rows: { Node } = {}
	local passed = 0
	for i, s in r.steps do
		local ok = s.status == "Success"
		if ok then
			passed += 1
		end
		if vs.steps or not ok then
			local tone = if s.status == "Failed" then "error" elseif ok then "muted" else "warning"
			table.insert(rows, ui.text({ ui.span(s.status, tone), " ", s.name }, { key = "step" .. i }))
		end
	end
	local summary = passed .. " of " .. plural(#r.steps, "step") .. " passed"
	table.insert(
		rows,
		toggleRow(
			chip(
				if vs.steps then "Hide steps" else summary,
				Viewstate.action(Viewstate.toggled(vs, "steps")),
				"Toggle the server validation steps",
				"steps-toggle",
				if passed == #r.steps then "muted" else "warning"
			)
		)
	)
	return ui.col(rows, { key = "steps", gap = "xs" })
end

local function warningsNode(r: Result, vs: ViewState, opts: Options): Node?
	local groups: { Group } = {}
	for _, g in r.groups do
		if g.severity == "warning" then
			table.insert(groups, g)
		end
	end
	if #groups == 0 then
		return nil
	end
	local action = Viewstate.action(Viewstate.toggled(vs, "warnings"))
	local label = if vs.warnings then "Hide warnings" else "Show " .. plural(r.counts.warnings, "warning")
	local children: { Node } = {
		toggleRow(chip(label, action, "Warnings do not stop a deploy", "warnings-toggle", "warning")),
	}
	if vs.warnings then
		for _, g in groups do
			table.insert(children, groupCard(r, g, opts))
		end
	end
	return ui.col(children, { key = "warnings" })
end

local function pair(key: string, value: ui.SpanLike): { { ui.SpanLike } }
	return { { key }, { value } }
end

local function factsNode(r: Result, opts: Options): Node?
	local items: { { { ui.SpanLike } } } = {}
	if r.packageFile then
		table.insert(items, pair("Package", pathSpan(r, r.packageFile, nil, opts)))
	end
	if r.logFile then
		local log = r.logFile :: string
		local full = if string.sub(log, 1, 1) ~= "/" and opts.cwd then opts.cwd .. "/" .. log else log
		table.insert(items, pair("Log file", { t = log, s = "path", href = fileUrl(full) }))
	end
	if r.project and r.family ~= "package" then
		table.insert(items, pair("Project", r.project :: string))
	end
	if #items == 0 then
		return nil
	end
	return ui.kv(items)
end

local function unknownNode(r: Result): Node?
	if #r.unknown == 0 then
		return nil
	end
	local rows: { Node } = table.create(#r.unknown)
	for i, u in r.unknown do
		rows[i] = ui.text({ ui.span(u.text, "mono") }, { key = "u" .. u.line })
	end
	local head = if r.outcome == "failed" and r.counts.errors == 0 then "CLI output" else "Other output"
	return ui.section({ ui.span(head, "strong") }, rows, { key = "unknown" })
end

-- The view of a finished run, or nil (raw) for interactive/help runs and
-- output the parser does not understand.
function M.render(r: Result, inv: Invocation, vs: ViewState, opts: Options): Node?
	if r.outcome == "unknown" or not Argv.renders(inv) then
		return nil
	end
	local children: { Node } = { header(r, inv, opts) }
	local function add(n: Node?)
		if n then
			table.insert(children, n)
		end
	end
	for _, g in r.groups do
		if g.severity == "error" then
			table.insert(children, groupCard(r, g, opts))
		end
	end
	add(unknownNode(r))
	add(warningsNode(r, vs, opts))
	add(chips(r, inv, opts))
	add(factsNode(r, opts))
	add(itemsNode(r, vs))
	add(stepsNode(r, vs))
	for i, note in r.notes do
		if not QUIET_NOTES[note] then
			table.insert(children, ui.muted(note, { key = "note" .. i }))
		end
	end
	return ui.col(children, { key = "suitecloud", role = "tern-netsuite.suitecloud" })
end

export type CopyWhat = "errors" | "warnings" | "rerun"

-- Clipboard text of a copy chip; nil when there is nothing to copy.
function M.copyText(r: Result, inv: Invocation, what: string): string?
	if what == "errors" then
		local text = Output.copyText(r, "error")
		return if text ~= "" then text else nil
	elseif what == "warnings" then
		local text = Output.copyText(r, "warning")
		return if text ~= "" then text else nil
	elseif what == "rerun" then
		return Argv.serverValidate(inv)
	end
	return nil
end

-- Rows a listing shows with "Show all"; past it the browser block has them.
M.MAX_LISTED = 200

-- The action of the chip that opens the browser on the run's directory.
M.BROWSE_ACTION = "browse"

local LIST_FLAGS = { "type", "scriptid", "appid", "folder" }

local function listingFilters(inv: Invocation): string?
	local parts: { string } = {}
	for _, name in LIST_FLAGS do
		local v = inv.flags[name]
		if type(v) == "string" then
			table.insert(parts, "--" .. name .. " " .. v)
		end
	end
	return if #parts > 0 then table.concat(parts, " ") else nil
end

local function listingRows(rows: { Node }, total: number, vs: ViewState): { Node }
	local limit = if vs.items then math.min(total, M.MAX_LISTED) else math.min(total, M.MAX_ITEMS)
	local out = table.move(rows, 1, limit, 1, table.create(limit + 2))
	if total > M.MAX_ITEMS then
		local label = if vs.items then "Show fewer" else "Show all " .. total
		table.insert(
			out,
			toggleRow(
				chip(label, Viewstate.action(Viewstate.toggled(vs, "items")), "Toggle the full list", "items-toggle")
			)
		)
	end
	if vs.items and total > M.MAX_LISTED then
		table.insert(
			out,
			ui.muted(
				string.format("%d more: the account browser searches all of them", total - M.MAX_LISTED),
				{ key = "more" }
			)
		)
	end
	return out
end

-- The native view of a finished `object:list` / `file:list`, or nil (raw)
-- for other commands, interactive/help runs and failed runs.
function M.renderListing(inv: Invocation, lines: { string }, status: number, vs: ViewState, opts: Options): Node?
	if not Argv.renders(inv) or status ~= 0 then
		return nil
	end
	local isObjects = inv.command == "object:list"
	if not isObjects and inv.command ~= "file:list" then
		return nil
	end
	local noun = if isObjects then "object" else "file"
	local count: number
	local empty: boolean
	local unknown: { Listing.Unknown }
	local groups: { Node } = {}
	local rows: { Node } = {}
	if isObjects then
		local r = Listing.objects(lines, status)
		if r == nil then
			return nil
		end
		count, empty, unknown = #r.objects, r.empty, r.unknown
		for _, c in Listing.byType(r.objects) do
			table.insert(groups, ui.badge(c.type .. " " .. c.count, "neutral", { key = "t:" .. c.type }))
		end
		for i, o in r.objects do
			if i > M.MAX_LISTED then
				break
			end
			rows[i] = ui.text({ ui.span(o.type .. " ", "muted"), ui.span(o.scriptId, "code") }, { key = "o" .. i })
		end
	else
		local r = Listing.files(lines, status)
		if r == nil then
			return nil
		end
		count, empty, unknown = #r.files, r.empty, r.unknown
		for _, c in Listing.byFolder(r.files) do
			table.insert(groups, ui.badge(c.folder .. " " .. c.count, "neutral", { key = "f:" .. c.folder }))
		end
		for i, f in r.files do
			if i > M.MAX_LISTED then
				break
			end
			rows[i] = ui.text({ ui.span(f, "path") }, { key = "f" .. i })
		end
	end
	local outcome = if count == 0 then "No " .. noun .. "s" else plural(count, noun)
	local top: { Node } = {
		ui.badge(outcome, if count == 0 then "muted" else "success", { key = "outcome" }),
		ui.text({ ui.span(opts.line or (inv.launcher .. " " .. inv.command), "mono strong") }, { key = "command" }),
	}
	local filters = listingFilters(inv)
	if filters and opts.line == nil then
		table.insert(top, ui.text({ ui.span(filters, "mono muted") }, { key = "filters" }))
	end
	local children: { Node } = { ui.row(top, { key = "bar", wrap = true, role = "tern-netsuite.bar" }) }
	if #groups > 0 then
		table.insert(children, ui.row(groups, { key = "groups", wrap = true }))
	end
	if count > 0 then
		local title = if isObjects then "Objects" else "Files"
		table.insert(
			children,
			ui.section({ ui.span(title, "strong") }, listingRows(rows, count, vs), { key = "items" })
		)
	elseif empty then
		local sentence = if isObjects then Listing.errorText(lines) or "" else "No files found."
		table.insert(children, ui.muted(sentence, { key = "empty" }))
	end
	if #unknown > 0 then
		local other: { Node } = table.create(#unknown)
		for i, u in unknown do
			other[i] = ui.text({ ui.span(u.text, "mono") }, { key = "u" .. u.line })
		end
		table.insert(children, ui.section({ ui.span("Other output", "strong") }, other, { key = "unknown" }))
	end
	if opts.cwd then
		table.insert(
			children,
			ui.row({
				chip(
					"Browse, diff and import",
					M.BROWSE_ACTION,
					"Open the account browser for this directory: search every "
						.. noun
						.. ", compare with the local project, import",
					"browse"
				),
			}, { key = "chips", role = "tern-netsuite.chips" })
		)
	end
	return ui.col(children, { key = "suitecloud", role = "tern-netsuite.suitecloud" })
end

return table.freeze(M)
