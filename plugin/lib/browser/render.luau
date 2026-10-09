--!strict
-- The browser block's view: target account, side/type/search filters, a
-- window of the filtered list around the selection (at most MAX_ROWS) in a
-- list that fills the pane and keeps the selection in view (ui.scroll),
-- and a dock with the last message and the keys. Pure: `{k, p, c}` nodes
-- from lib/ui.

local Diff = require("./diff")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type State = State.State
type Entry = Diff.Entry

local M = {}

-- Rows drawn at most; the scrolling list shows what fits the pane.
M.MAX_ROWS = 300

local WHERE_LABEL: { [string]: string } = { account = "account", both = "both", ["local"] = "local" }
local WHERE_STYLE: { [string]: string } = { account = "success", both = "muted", ["local"] = "warning" }

local function chip(text: string, action: string, on: boolean, key: string, title: string?): Node
	return ui.badge(text, if on then "info" else "neutral", { key = key, title = title, actions = { click = action } })
end

local function targetNodes(s: State): { Node }
	local t = s.target
	if s.authId == nil then
		return { ui.badge("no auth ID", "warning", { key = "target", title = "project.json has no defaultAuthId" }) }
	end
	if t == nil then
		return {}
	end
	local badge: Node
	if t.source == "unknown" then
		badge = ui.badge(t.authId .. "?", "warning", {
			key = "target",
			title = t.problem or "Account not resolved yet; unknown accounts are treated as production",
		})
	elseif t.production then
		badge = ui.badge(if t.label == "PROD" then "PROD" else "PROD " .. t.label, "error", {
			key = "target",
			title = "Production account: listing and import only read it",
		})
	else
		badge = ui.badge(t.label, "muted", { key = "target", title = "Target account" })
	end
	local detail = t.authId .. (if t.accountId then " → " .. t.accountId else "")
	return { badge, ui.text({ ui.span(detail, "muted") }, { key = "auth" }) }
end

local function loading(s: State): boolean
	if s.objects.status == "loading" or s.infoLoading then
		return true
	end
	for _, l in s.files do
		if l.status == "loading" then
			return true
		end
	end
	return false
end

local function header(s: State): Node
	local project = s.project
	local nodes: { Node } = {}
	table.insert(
		nodes,
		ui.text({ ui.span(if project then project.name else "NetSuite browser", "strong") }, { key = "project" })
	)
	for _, n in targetNodes(s) do
		table.insert(nodes, n)
	end
	if loading(s) then
		table.insert(nodes, ui.text({ ui.span("listing the account…", "muted") }, { key = "loading" }))
	end
	return ui.row(nodes, { key = "head", wrap = true })
end

local function errors(s: State): { Node }
	local out: { Node } = {}
	if s.objects.status == "error" then
		table.insert(
			out,
			ui.text({ ui.span("object:list failed: ", "error strong"), s.objects.error or "" }, { key = "err-objects" })
		)
	end
	for i, folder in s.folders do
		local l = s.files[folder]
		if l and l.status == "error" then
			table.insert(
				out,
				ui.text(
					{ ui.span("file:list " .. folder .. " failed: ", "error strong"), l.error or "" },
					{ key = "err-f" .. i }
				)
			)
		end
	end
	return out
end

local function filters(s: State): { Node }
	local entries = s.entries[s.kind]
	local c = Diff.counts(entries)
	local kinds = ui.row({
		chip("Objects " .. #s.entries.object, "kind=object", s.kind == "object", "k-object"),
		chip("Files " .. #s.entries.file, "kind=file", s.kind == "file", "k-file"),
		chip(
			"Type: " .. (s.filter.type or "all"),
			"type=next",
			s.filter.type ~= nil,
			"type",
			"t next type, T previous"
		),
	}, { key = "kinds", wrap = true })
	local w = s.filter.where
	local sides = ui.row({
		chip("all " .. c.all, "where=all", w == "all", "w-all"),
		chip(c.account .. " account only", "where=account", w == "account", "w-account", "Importable: i"),
		chip(c.both .. " in both", "where=both", w == "both", "w-both"),
		chip(c["local"] .. " local only", "where=local", w == "local", "w-local", "Not in the account yet"),
	}, { key = "sides", wrap = true })
	local query = s.filter.query
	local search: Node = {
		k = "input",
		p = {
			key = "search",
			text = query,
			cursor = #query,
			placeholder = if s.editing then "type to search" else "press / to search",
			prompt = "/",
		},
	}
	return { kinds, sides, search }
end

local function rowKey(e: Entry): string
	return "r:" .. e.kind .. ":" .. e.id
end

local function rowNode(e: Entry, i: number, selected: boolean): Node
	local spans: { ui.SpanLike } = {
		ui.span(if selected then "▸ " else "  ", "strong"),
		ui.span(string.format("%-7s", WHERE_LABEL[e.where]), WHERE_STYLE[e.where]),
		" ",
	}
	if e.type then
		table.insert(spans, ui.span(e.type .. " ", "muted"))
	end
	table.insert(spans, ui.span(e.id, if selected then "code strong" else "code"))
	return ui.text(spans, { key = rowKey(e), actions = { click = "sel=" .. i } })
end

local function listNodes(s: State): { Node }
	local out: { Node } = {}
	local all = s.entries[s.kind]
	local visible = State.visible(s)
	local summary = string.format("%d of %d %s", #visible, #all, if s.kind == "object" then "objects" else "files")
	table.insert(out, ui.text({ ui.span(summary, "muted") }, { key = "count" }))
	if #visible == 0 then
		local why = if #all == 0 and not loading(s) then "Nothing listed." else "Nothing matches the filters."
		table.insert(out, ui.muted(why, { key = "empty" }))
		return out
	end
	local size = M.MAX_ROWS
	local sel = math.clamp(s.selected, 1, #visible)
	local first = math.clamp(sel - size // 2, 1, math.max(#visible - size + 1, 1))
	local last = math.min(first + size - 1, #visible)
	if first > 1 then
		table.insert(out, ui.muted(string.format("↑ %d above", first - 1), { key = "above" }))
	end
	local rows: { Node } = table.create(last - first + 1)
	for i = first, last do
		table.insert(rows, rowNode(visible[i], i, i == sel))
	end
	table.insert(out, ui.scroll("rows", rows, rowKey(visible[sel]), size))
	if last < #visible then
		table.insert(out, ui.muted(string.format("↓ %d below", #visible - last), { key = "below" }))
	end
	return out
end

local function dock(s: State): Node
	local children: { Node } = {}
	local m = s.message
	if m then
		table.insert(children, ui.text({ ui.span(m.text, m.tone) }, { key = "message" }))
	end
	local scripts = if s.excludeFiles then "scripts excluded" else "scripts included"
	local keys: { ui.SpanLike } = if s.editing
		then {
			ui.span("enter", "key"),
			" done  ",
			ui.span("esc", "key"),
			" done  ",
			ui.span("backspace", "key"),
			" delete",
		}
		else {
			ui.span("/", "key"),
			" search  ",
			ui.span("tab", "key"),
			" objects/files  ",
			ui.span("a", "key"),
			" side  ",
			ui.span("t", "key"),
			" type  ",
			ui.span("i", "key"),
			" import  ",
			ui.span("shift+i", "key"),
			" force  ",
			ui.span("x", "key"),
			" " .. scripts .. "  ",
			ui.span("r", "key"),
			" refresh  ",
			ui.span("q", "key"),
			" close",
		}
	table.insert(children, ui.text(keys, { key = "keys" }))
	return ui.col(children, { key = "dock" })
end

function M.view(s: State): { main: Node, dock: Node }
	local children: { Node } = { header(s) }
	if s.phase == "noproject" then
		local where = s.cwd or "this pane"
		table.insert(
			children,
			ui.text({
				ui.span(s.scanError or (where .. " is not inside an SDF project"), "warning"),
				ui.span(" (no suitecloud.config.js in it or its parents)", "muted"),
			}, { key = "noproject" })
		)
	elseif s.phase ~= "ready" then
		table.insert(children, ui.muted("Reading the project…", { key = "reading" }))
	elseif s.authId == nil then
		table.insert(
			children,
			ui.text({
				ui.span("project.json has no defaultAuthId", "warning strong"),
				ui.span(
					" — the CLI lists the account named there. Run `suitecloud account:setup` in "
						.. (s.root or "the project")
						.. ".",
					"muted"
				),
			}, { key = "noauth" })
		)
	else
		for _, n in errors(s) do
			table.insert(children, n)
		end
		for _, n in filters(s) do
			table.insert(children, n)
		end
		for _, n in listNodes(s) do
			table.insert(children, n)
		end
	end
	return {
		main = ui.col(children, { key = "browser", role = "tern-netsuite.browser" }),
		dock = dock(s),
	}
end

function M.title(s: State): string
	local project = s.project
	return "NetSuite Browser" .. (if project then " · " .. project.name else "")
end

return table.freeze(M)
