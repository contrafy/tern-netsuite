--!strict
-- Renders the history block: a day-grouped timeline (list) or one entry's
-- details. Times are formatted by the adapter (local time zone).

local Git = require("./git")
local State = require("./state")
local Timeline = require("./timeline")
local ui = require("../ui")

type Node = ui.Node
type Item = Timeline.Item

export type Format = {
	day: (number) -> string,
	clock: (number) -> string,
	-- Timeline rows shown at once.
	rows: number,
}

local M = {}

local SOURCE_TONE: { [string]: string } = { ["local"] = "neutral", guard = "warning", ci = "info" }
-- Keeps a CI row on one line in a half-width pane.
local MAX_TITLE = 36
local VERB: { [string]: string } = { ["project:deploy"] = "deploy", ["file:upload"] = "upload" }

function M.duration(ms: number?): string?
	if ms == nil or ms < 0 then
		return nil
	end
	local s = math.floor(ms / 1000 + 0.5)
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return string.format("%dm %ds", s // 60, s % 60)
	end
	return string.format("%dh %dm", s // 3600, (s % 3600) // 60)
end

local function ref(item: Item): string?
	local short = Git.short(item.head)
	local text = if item.branch and short then item.branch .. "@" .. short else item.branch or short
	if text and item.dirty then
		text ..= "*"
	end
	return text
end

local function accountBadge(item: Item): Node?
	local a = item.account
	if a == nil then
		return nil
	end
	if a.production == true then
		local label = if string.find(string.upper(a.label), "PROD", 1, true) then a.label else a.label .. " PROD"
		return ui.badge(label, "error", { key = "acct" })
	elseif a.production == nil then
		return ui.badge(a.label, "warning", { key = "acct", title = "account unknown when this ran" })
	end
	return ui.badge(a.label, "neutral", { key = "acct" })
end

local function clip(text: string, max: number): string
	if utf8.len(text) == nil or (utf8.len(text) :: number) <= max then
		return text
	end
	return string.sub(text, 1, (utf8.offset(text, max) :: number) - 1) .. "…"
end

local function row(item: Item, selected: boolean, fmt: Format): Node
	local children: { Node } = {
		ui.text({
			ui.span(if selected then "▸ " else "  ", "accent strong"),
			ui.span(fmt.clock(item.at), "mono muted"),
		}, { key = "when" }),
		ui.badge(item.source, SOURCE_TONE[item.source] or "neutral", { key = "src" }),
		ui.badge(item.status, item.tone, { key = "st" }),
	}
	local what = item.project or (if item.title then clip(item.title, MAX_TITLE) else nil)
	if what then
		table.insert(children, ui.text({ ui.span(what, if selected then "strong" else nil) }, { key = "what" }))
	end
	local verb = if item.command then VERB[item.command] else nil
	if verb then
		table.insert(children, ui.text({ ui.span(verb, "muted") }, { key = "verb" }))
	end
	local acct = accountBadge(item)
	if acct then
		table.insert(children, acct)
	end
	local r = ref(item)
	if r then
		table.insert(children, ui.text({ ui.span(r, "mono muted") }, { key = "ref" }))
	end
	local d = M.duration(item.tookMs)
	if d then
		table.insert(children, ui.text({ ui.span(d, "muted") }, { key = "took" }))
	end
	return ui.row(children, { key = item.key, wrap = true, actions = { click = "sel=" .. item.key } })
end

local function chip(name: string, value: string?): Node
	return ui.badge(name .. ": " .. (value or "all"), if value then "accent" else "neutral", {
		key = "f-" .. name,
		actions = { click = "filter=" .. name },
	})
end

local function ciLine(s: State.State): Node?
	local ci = s.settings.ci
	if s.ciLoad == "loading" then
		return ui.muted("Loading CI runs …", { key = "ci" })
	elseif s.ciLoad == "error" then
		return ui.text({ ui.span("CI runs: " .. (s.ciError or "gh failed"), "error") }, { key = "ci" })
	elseif s.ciLoad == "ok" and ci then
		return ui.muted(
			string.format("CI: %s, workflow %s (%d runs)", s.repo or "?", ci.workflow, #s.runs),
			{ key = "ci" }
		)
	elseif s.ciNote and ci then
		return ui.muted("CI runs off: " .. s.ciNote, { key = "ci" })
	end
	return nil
end

-- The rows around the selection.
local function window(items: { Item }, sel: string?, size: number): (number, number)
	local n = #items
	if n <= size then
		return 1, n
	end
	local at = 1
	for i, item in items do
		if item.key == sel then
			at = i
			break
		end
	end
	local first = math.clamp(at - size // 2, 1, n - size + 1)
	return first, first + size - 1
end

local function listView(s: State.State, fmt: Format): Node
	local f = s.filters
	local head: { Node } = { chip("project", f.project), chip("account", f.account), chip("source", f.source) }
	if f.project or f.account or f.source then
		table.insert(head, ui.badge("clear", "neutral", { key = "f-clear", actions = { click = "clear" } }))
	end
	local out: { Node } = { ui.row(head, { key = "filters", wrap = true }) }
	local ci = ciLine(s)
	if ci then
		table.insert(out, ci)
	end
	if s.localError then
		table.insert(
			out,
			ui.text({ ui.span("Local history could not be read: " .. s.localError, "error") }, { key = "lerr" })
		)
	end
	local items = State.visible(s)
	if #items == 0 then
		local loading = s.localLoad == "loading" or s.ciLoad == "loading"
		local text = if loading
			then "Loading …"
			elseif #s.items > 0 then "Nothing matches the filters (x clears them)."
			else "No deploys recorded yet. project:deploy and file:upload runs in Tern panes appear here."
		table.insert(out, ui.muted(text, { key = "empty" }))
		return ui.col(out, { key = "history" })
	end
	local first, last = window(items, s.sel, math.max(fmt.rows, 5))
	if first > 1 then
		table.insert(out, ui.muted(string.format("↑ %d newer", first - 1), { key = "above" }))
	end
	local shown = table.move(items, first, last, 1, {})
	for _, day in Timeline.group(shown, fmt.day) do
		table.insert(out, ui.rule({ day.day }, { key = "d-" .. day.day }))
		for _, item in day.items do
			table.insert(out, row(item, item.key == s.sel, fmt))
		end
	end
	if last < #items then
		table.insert(out, ui.muted(string.format("↓ %d older", #items - last), { key = "below" }))
	end
	return ui.col(out, { key = "history" })
end

type Pair = { { ui.SpanLike } }

local function detailView(item: Item, fmt: Format): Node
	local rows: { Pair } = {}
	local function add(k: string, v: { ui.SpanLike }?)
		if v then
			local key: { ui.SpanLike } = { k }
			table.insert(rows, { key, v })
		end
	end
	local status: { ui.SpanLike } = { ui.span(item.status, item.tone) }
	if item.source == "local" and item.exit then
		table.insert(status, ui.span("  exit " .. item.exit, "muted"))
	end
	add("Source", { item.source :: string })
	add("Status", status)
	if item.guard then
		add("Guard", { item.guard .. (if item.reason then ": " .. item.reason else "") })
	end
	add("When", { fmt.day(item.at) .. " " .. fmt.clock(item.at) })
	local d = M.duration(item.tookMs)
	add("Duration", if d then { d } else nil)
	add("Project", if item.project then { item.project } else nil)
	if item.account then
		local a = item.account
		local tone = if a.production == true then "error" elseif a.production == nil then "warning" else nil
		local text = a.label
			.. (if a.production == true then " (production)" elseif a.production == nil then " (unknown)" else "")
		local spans: { ui.SpanLike } = { ui.span(text, tone) }
		if item.authId then
			table.insert(spans, ui.span("  auth id " .. item.authId, "muted"))
		end
		add("Account", spans)
	end
	add("Command", if item.line then { ui.span(item.line, "mono") } else nil)
	add("Directory", if item.cwd then { ui.span(item.cwd, "mono") } else nil)
	add("Log file", if item.log then { ui.span(item.log, "mono") } else nil)
	if item.branch or item.head then
		local parts: { string } = {}
		if item.branch then
			table.insert(parts, item.branch)
		end
		if item.head then
			table.insert(parts, item.head)
		end
		if item.dirty == true then
			table.insert(parts, "(dirty)")
		elseif item.dirty == false then
			table.insert(parts, "(clean)")
		end
		add("Git", { ui.span(table.concat(parts, " "), "mono") })
	end
	add("Title", if item.title then { item.title } else nil)
	add("Event", if item.event then { item.event } else nil)
	add("Repository", if item.repo then { item.repo } else nil)
	if item.url then
		add("Run", { { t = item.url, s = "link", href = item.url } })
	end
	return ui.col({
		ui.text({ ui.span("← back", "accent") }, { key = "back", actions = { click = "back" } }),
		ui.kv(rows),
	}, { key = "detail" })
end

local function keyHelp(pairs: { { string } }): Node
	local spans: { ui.SpanLike } = {}
	for i, p in pairs do
		if i > 1 then
			table.insert(spans, "  ")
		end
		table.insert(spans, ui.span(p[1], "key"))
		table.insert(spans, " " .. p[2])
	end
	return ui.text(spans, { key = "keys" })
end

function M.view(s: State.State, fmt: Format): { main: Node, dock: Node }
	local item = State.selected(s)
	if s.detail and item then
		local keys = { { "esc", "back" }, { "c", "copy" } }
		if item.url or item.log then
			table.insert(keys, { "o", "open" })
		end
		if item.status == "failed" and item.runId then
			table.insert(keys, { "l", "failed log" })
		end
		return { main = detailView(item, fmt), dock = ui.col({ keyHelp(keys) }, { key = "dock" }) }
	end
	return {
		main = listView(s, fmt),
		dock = ui.col({
			keyHelp({
				{ "j/k", "move" },
				{ "enter", "details" },
				{ "p/a/s", "filter" },
				{ "x", "clear" },
				{ "o", "open" },
				{ "l", "failed log" },
				{ "r", "refresh" },
				{ "esc", "close" },
			}),
		}, { key = "dock" }),
	}
end

return M
