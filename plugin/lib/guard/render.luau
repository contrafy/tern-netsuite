--!strict
-- View of the approve block (lib/guard/session.luau state -> node tree).
-- Clickables are badges with click actions: they need no plugin stylesheet.

local Protocol = require("./protocol")
local Session = require("./session")
local ui = require("../ui")

type State = Session.State
type Node = ui.Node
type Request = Protocol.Request

local M = {}

-- Files listed when the list is expanded; the count covers the rest.
M.MAX_FILES_SHOWN = 300

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

local function shellQuote(arg: string): string
	if arg ~= "" and string.find(arg, "^[%w%-%._/:=@,+%%]+$") then
		return arg
	end
	return "'" .. string.gsub(arg, "'", "'\\''") .. "'"
end

function M.commandText(argv: { string }): string
	local parts: { string } = {}
	for i, a in argv do
		parts[i] = shellQuote(a)
	end
	return table.concat(parts, " ")
end

local function under(path: string, dir: string): string?
	if string.sub(path, 1, #dir + 1) == dir .. "/" then
		return string.sub(path, #dir + 2)
	end
	return nil
end

-- SDF notation (`~/` = project folder) for project files.
function M.displayPath(path: string, r: Request): string
	local inFolder = under(path, r.folder)
	if inFolder then
		return "~/" .. inFolder
	end
	return under(path, r.cwd) or path
end

local KINDS: { { string } } = {
	{ "Objects", "object" },
	{ "FileCabinet", "File Cabinet file" },
	{ "AccountConfiguration", "account configuration file" },
	{ "Translations", "translation file" },
}

function M.fileSummary(r: Request): string
	local counts: { [string]: number } = {}
	local other = 0
	for _, f in r.files do
		local rel = under(f.path, r.folder)
		local top = if rel then string.match(rel, "^([^/]+)/") else nil
		if top then
			counts[top] = (counts[top] or 0) + 1
		else
			other += 1
		end
	end
	local parts: { string } = {}
	for _, kind in KINDS do
		local n = counts[kind[1]]
		if n then
			table.insert(parts, plural(n, kind[2]))
			counts[kind[1]] = nil
		end
	end
	for _, n in counts do
		other += n
	end
	if other > 0 then
		table.insert(parts, plural(other, "project file"))
	end
	return table.concat(parts, " · ")
end

local function chip(text: string, action: string, key: string, tone: string): Node
	return ui.badge(text, tone, { key = key, actions = { click = action } })
end

local function targetBadge(s: State): Node
	local target = s.target
	if target == nil then
		return ui.badge("NO REQUEST", "neutral", { key = "badge" })
	elseif not target.known then
		return ui.badge("UNKNOWN ACCOUNT", "error", { key = "badge" })
	elseif target.production then
		return ui.badge("PRODUCTION", "error", { key = "badge" })
	end
	return ui.badge("NON-PRODUCTION", "success", { key = "badge" })
end

local function header(s: State): Node
	local r = s.request
	local target = s.target
	local spans: { ui.SpanLike } = {}
	if r and target then
		spans = {
			ui.span("Approve ", "strong"),
			ui.span("suitecloud " .. r.command, "strong mono"),
			ui.span(" on ", "strong"),
			ui.span(target.label, if target.production then "error strong" else "strong"),
		}
	else
		spans = { ui.span("NetSuite approval request", "strong") }
	end
	return ui.row({ targetBadge(s), ui.text(spans) }, { key = "header", wrap = true })
end

local function gitValue(r: Request): { ui.SpanLike }
	local git = r.git
	if git == nil then
		return { ui.span("not a git repository", "muted") }
	end
	local out: { ui.SpanLike } = {}
	local head = git.head
	table.insert(out, ui.span(git.branch or "(detached)", "strong"))
	if head then
		table.insert(out, " @ " .. string.sub(head, 1, 12))
	end
	table.insert(
		out,
		ui.span(if git.dirty then "  uncommitted changes" else "  clean", if git.dirty then "warning" else "muted")
	)
	local upstream = git.upstream
	if upstream then
		table.insert(
			out,
			ui.span(
				string.format("  ↑%d ↓%d %s", git.ahead or 0, git.behind or 0, upstream),
				if (git.behind or 0) > 0 then "warning" else "muted"
			)
		)
	end
	return out
end

local function facts(s: State): Node?
	local r = s.request
	local target = s.target
	if r == nil or target == nil then
		return nil
	end
	local account: { ui.SpanLike } = { ui.span(target.label, "strong") }
	local accountId = target.accountId
	if accountId and accountId ~= target.label then
		table.insert(account, "  " .. accountId)
	end
	if r.accountName then
		table.insert(account, ui.span("  " .. r.accountName, "muted"))
	end
	if r.accountType then
		table.insert(account, ui.span("  (" .. r.accountType .. ")", "muted"))
	end
	local items: { { { ui.SpanLike } } } = {
		{ { "Account" }, account },
		{
			{ "Auth ID" },
			if r.authId
				then { r.authId :: string, ui.span("  (project.json defaultAuthId)", "muted") }
				else { ui.span("none (no readable project.json defaultAuthId)", "warning") },
		},
		{ { "Command" }, { ui.span(M.commandText(r.argv), "mono") } },
		{ { "Project" }, { r.cwd } },
	}
	if r.folder ~= r.cwd then
		table.insert(items, { { "Folder" } :: { ui.SpanLike }, { r.folder } :: { ui.SpanLike } })
	end
	table.insert(items, { { "Git" } :: { ui.SpanLike }, gitValue(r) })
	return ui.kv(items)
end

local function warningsNode(s: State): Node?
	if #s.warnings == 0 then
		return nil
	end
	local lines: { Node } = {}
	for i, w in s.warnings do
		table.insert(
			lines,
			ui.text({
				ui.span(
					if w.level == "warning" then "⚠ " else "· ",
					if w.level == "warning" then "warning" else "muted"
				),
				ui.span(w.text, if w.level == "warning" then "" else "muted"),
			}, { key = "w" .. i })
		)
	end
	return ui.section({ "Warnings" }, lines, { key = "warnings" })
end

local function filesNode(s: State): Node?
	local r = s.request
	if r == nil then
		return nil
	end
	local children: { Node } = {
		ui.row({
			ui.text({ ui.span(M.fileSummary(r), "muted") }, { key = "summary" }),
			chip(if s.showFiles then "Hide files" else "Show files", "files", "toggle", "neutral"),
		}, { key = "files-bar", wrap = true }),
	}
	if s.showFiles then
		local lines: { Node } = {}
		for i, f in r.files do
			if i > M.MAX_FILES_SHOWN then
				break
			end
			table.insert(lines, ui.text({ ui.span(M.displayPath(f.path, r), "mono") }, { key = "f" .. i }))
		end
		if #r.files > M.MAX_FILES_SHOWN then
			table.insert(lines, ui.muted(string.format("… %d more", #r.files - M.MAX_FILES_SHOWN), { key = "more" }))
		end
		table.insert(children, ui.lines(lines, { key = "list" }))
	end
	return ui.section({ plural(#r.files, "file") .. " fingerprinted" }, children, { key = "files" })
end

local function statusNodes(s: State, out: { Node })
	if s.phase == "verifying" then
		table.insert(
			out,
			ui.row({
				{ k = "spinner", p = { style = "dots", tone = "accent" } },
				ui.text({ ui.span("Checking the request against its fingerprint …", "muted") }),
			}, { key = "verifying" })
		)
	elseif s.phase == "responding" then
		table.insert(out, ui.muted("Sending the decision …", { key = "responding" }))
	elseif s.phase == "expired" then
		table.insert(
			out,
			ui.text({ ui.span("The request expired: the shell stopped waiting.", "error") }, { key = "expired" })
		)
	end
	for i, e in s.errors do
		table.insert(out, ui.text({ ui.span(e, "error") }, { key = "e" .. i }))
	end
end

local function typedNodes(s: State, out: { Node })
	local target = s.target
	if not s.typedRequired or target == nil or not (s.phase == "verifying" or s.phase == "ready") then
		return
	end
	table.insert(
		out,
		ui.text({
			ui.span("Type ", "strong"),
			ui.span(target.prompt, "mono strong"),
			ui.span(" to approve", "strong"),
			ui.span(
				if #target.tokens > 1 then "  (or " .. table.concat(target.tokens, ", ", 2) .. ")" else "",
				"muted"
			),
		}, { key = "prompt" })
	)
	table.insert(out, {
		k = "input",
		p = {
			key = "typed",
			text = s.typed,
			cursor = #s.typed,
			placeholder = target.prompt,
			prompt = ">",
			tone = if Session.typedMatches(s) then "success" else nil,
		},
	})
end

local function buttons(s: State): Node
	local out: { Node } = {}
	if s.respondable and not s.decided then
		local target = s.target
		local production = target == nil or target.production
		if s.phase ~= "blocked" then
			local ok = Session.approveBlocker(s) == nil
			table.insert(
				out,
				chip(
					if production then "Approve production " .. (target and target.label or "") else "Approve",
					"approve",
					"approve",
					if ok then (if production then "error" else "success") else "neutral"
				)
			)
		end
		table.insert(out, chip("Deny", "deny", "deny", "neutral"))
	elseif s.phase ~= "closed" and s.phase ~= "responding" then
		table.insert(out, chip("Close", "close", "close", "neutral"))
	end
	return ui.row(out, { key = "buttons", wrap = true })
end

function M.view(s: State): { main: Node, dock: Node }
	local main: { Node } = { header(s) }
	local function add(n: Node?)
		if n then
			table.insert(main, n)
		end
	end
	add(facts(s))
	add(warningsNode(s))
	add(filesNode(s))
	statusNodes(s, main)
	typedNodes(s, main)
	if s.confirmError then
		table.insert(main, ui.text({ ui.span(s.confirmError :: string, "warning") }, { key = "confirm-error" }))
	end
	add(buttons(s))
	local hint = if s.respondable and not s.decided
		then "Enter approve · Esc deny · nothing runs unless you approve"
		else "Esc close"
	return {
		main = ui.col(main, { role = "tern-netsuite.approve" }),
		dock = ui.col({ ui.muted(hint, { key = "hints" }) }, { role = "tern-netsuite.approve-dock" }),
	}
end

function M.title(s: State): string
	local r = s.request
	local target = s.target
	if r == nil or target == nil then
		return "NetSuite approve"
	end
	return "NetSuite approve · " .. target.label .. " · " .. r.command
end

return M
