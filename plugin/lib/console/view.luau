--!strict
-- View of the `console` block: connection chips (production in red with a
-- PROD badge), the SQL editor, inline errors with what to do, then either
-- the saved-query picker or the results: a head (PROD badge, connection,
-- rows, timing, truncation), export actions, the filter, the column head
-- (click to sort) and a window of rows; the selected row's inspector or
-- the key hints in the dock.

local Editor = require("./editor")
local Errors = require("../ns/errors")
local Grid = require("./grid")
local Library = require("./library")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
type State = State.State
type Result = State.Result

local M = {}

M.EDITOR_LINES = 12
M.MAX_INSPECT_COLUMNS = 200
M.MAX_INSPECT_TEXT = 4000

local KIND_LABEL: { [string]: string } = {
	auth = "authentication",
	permission = "permission",
	query = "query",
	rate_limit = "rate limit",
	network = "network",
	server = "NetSuite server",
}

local function chip(text: string, tone: string, key: string, action: string?, title: string?): Node
	return ui.badge(text, tone, { key = key, actions = if action then { click = action } else nil, title = title })
end

local function prodBadge(key: string): Node
	return ui.badge("PROD", "error", { key = key, title = "Production account" })
end

local function thousands(n: number): string
	local s = string.format("%d", n)
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function seconds(ms: number): string
	if ms < 1000 then
		return string.format("%d ms", ms)
	end
	return string.format("%.2f s", ms / 1000)
end

local function header(s: State): Node
	local chips: { Node } = {}
	for i, tg in s.targets do
		local on = i == s.selected
		table.insert(
			chips,
			chip(
				tg.id .. " · " .. tg.account_label,
				if on then (if tg.production then "error" else "accent") else "neutral",
				"c" .. i,
				"conn=" .. tg.id,
				tg.account_id .. (if tg.production then " (production)" else "")
			)
		)
		if on and tg.production then
			table.insert(chips, prodBadge("prod"))
		end
	end
	if s.running then
		table.insert(chips, chip("running on " .. s.running.connection .. "…", "info", "status", nil))
	end
	table.insert(chips, chip("Run ⌃↵", "accent", "run", "run"))
	table.insert(chips, chip("Saved… ⌃O", "neutral", "picker", "picker"))
	table.insert(chips, chip("Save ⌃S", "neutral", "save", "save"))
	return ui.row(chips, { key = "head", wrap = true })
end

local function editorNode(s: State): Node
	return {
		k = "editor",
		p = {
			key = "sql",
			text = s.editor.text,
			cursor = Editor.caret(s.editor),
			lang = "sql",
			maxLines = M.EDITOR_LINES,
			placeholder = "SELECT id, companyname FROM customer   (Ctrl+Enter runs; Up on the first line recalls history)",
			aria = "SuiteQL query",
		},
	}
end

local function hint(e: Errors.NsError): string?
	if e.code == Errors.READ_ONLY then
		return "The console runs one SELECT or WITH query at a time and nothing that changes data: "
			.. "remove a second statement after ';' and words such as INSERT, UPDATE, DELETE or INTO "
			.. "(comments and string literals are ignored)."
	elseif e.code == Errors.NO_CREDENTIALS or e.kind == "auth" then
		if string.find(e.message, "Connect account", 1, true) then
			return nil
		end
		return "Store or fix this connection's credentials with Tern NetSuite: Connect account."
	elseif e.code == Errors.NO_CONNECTION then
		return "Add it to connections[] in the config (Tern NetSuite: Open config), or pick a configured one above."
	elseif e.code == Errors.NO_WINDOW then
		return "Queries run in the window half of the plugin: keep a Tern window open."
	elseif e.code == Errors.TIMEOUT then
		return "Narrow the query (a WHERE clause, fewer rows) or raise the connection's timeout_ms."
	elseif e.kind == "permission" then
		return "The connection's role lacks a permission this query needs (SuiteAnalytics Workbook or the record's own)."
	elseif e.kind == "rate_limit" then
		return "NetSuite is throttling requests for this account; run the query again in a moment."
	elseif e.kind == "query" then
		return "NetSuite could not run the query: check table and column names (the Records Catalog lists them)."
	end
	return nil
end

local function errorCard(s: State, e: Errors.NsError): Node
	local tail: { string } = {}
	if s.errConnection then
		table.insert(tail, "connection " .. s.errConnection)
	end
	if e.code then
		table.insert(tail, e.code)
	end
	if e.status then
		table.insert(tail, "HTTP " .. tostring(e.status))
	end
	local body: { Node } = {
		ui.row({ ui.badge(KIND_LABEL[e.kind] or e.kind, "error"), ui.text({ ui.span(e.message) }) }, { key = "err" }),
	}
	if #tail > 0 then
		table.insert(body, ui.muted(table.concat(tail, " · "), { key = "errcode" }))
	end
	local h = hint(e)
	if h then
		table.insert(body, ui.text({ ui.span(h) }, { key = "hint" }))
	end
	if e.code == Errors.NO_CREDENTIALS or e.kind == "auth" then
		table.insert(body, ui.row({ chip("Connect account", "accent", "connect", "connect") }, { key = "erract" }))
	end
	local title = if e.code == Errors.READ_ONLY then "Not run: the console is read-only" else "The query failed"
	return ui.card({ ui.span(title, "strong") }, body, { key = "errcard" })
end

local NOTICE_STYLE: { [string]: string } = {
	info = "muted",
	success = "success",
	warning = "warning",
	error = "error",
}

-- Results ---------------------------------------------------------------------

local function resultHead(r: Result, shown: number): Node
	local parts: { string } = {}
	local total = #r.rows
	if shown ~= total then
		table.insert(parts, string.format("%s of %s rows", thousands(shown), thousands(total)))
	else
		table.insert(parts, string.format("%s %s", thousands(total), if total == 1 then "row" else "rows"))
	end
	if r.elapsed then
		table.insert(parts, seconds(r.elapsed))
	end
	if r.ms and r.elapsed and math.abs(r.ms - r.elapsed) >= 100 then
		table.insert(parts, "NetSuite " .. seconds(r.ms))
	end
	if r.pages > 1 then
		table.insert(parts, string.format("%d pages", r.pages))
	end
	if r.at then
		table.insert(parts, "at " .. r.at)
	end
	local chips: { Node } = {}
	if r.production then
		table.insert(chips, prodBadge("rprod"))
	end
	table.insert(
		chips,
		ui.badge(r.connection .. " · " .. r.account, if r.production then "error" else "neutral", { key = "rconn" })
	)
	table.insert(chips, ui.text({ ui.span(table.concat(parts, " · "), "muted") }, { key = "rstats" }))
	if r.truncated then
		local why = if total >= r.maxRows
			then string.format("first %s rows (console.max_rows)", thousands(r.maxRows))
			else "cut short: more rows matched than one answer carries"
		table.insert(chips, ui.badge("truncated: " .. why, "warning", { key = "rtrunc" }))
	end
	return ui.row(chips, { key = "rhead", wrap = true })
end

local function actions(s: State, r: Result): Node
	local list: { Node } = {
		chip("Copy CSV  y", "neutral", "xcsv", "export=copy:csv"),
		chip("Copy TSV  Y", "neutral", "xtsv", "export=copy:tsv"),
		chip(
			"Save CSV  w",
			"neutral",
			"fcsv",
			"export=file:csv",
			"Writes a .csv next to " .. (s.cwd or "the pane's folder")
		),
		chip(
			"Save JSON  W",
			"neutral",
			"fjson",
			"export=file:json",
			"Writes a .json next to " .. (s.cwd or "the pane's folder")
		),
		chip("Open table  o", "neutral", "view", "export=view:csv", "Opens the rows in Tern's table viewer"),
	}
	local row = State.selectedRow(s)
	if #Grid.idCells(row, r.columns) > 0 then
		table.insert(list, chip("Inspect record  i", "accent", "inspect", "inspect="))
	end
	return ui.row(list, { key = "acts", wrap = true })
end

local function filterInput(s: State): Node
	local text = if s.view then s.view.filterText else ""
	return {
		k = "input",
		p = {
			key = "filter",
			text = text,
			cursor = Editor.utf16(text),
			placeholder = "press / to filter rows (every word, any column)",
			prompt = "/",
		},
	}
end

local function cellStyle(kind: Grid.Kind): string?
	if kind == "null" then
		return "muted"
	elseif kind == "boolean" then
		return "accent"
	end
	return nil
end

-- Separate text nodes in a row lose their edge spaces, so the head pads
-- with no-break spaces (the same width in the mono face).
local NBSP = "\194\160" -- U+00A0

local function hard(text: string): string
	return (string.gsub(text, " ", NBSP))
end

-- The column head: one clickable text per column (a click sorts by it).
local function columnHead(r: Result, v: State.View, first: number, last: number, room: number): Node
	local parts: { Node } = { ui.text({ ui.span(hard("  ")) }, { key = "pad" }) }
	local used = 0
	for j = first, last do
		local w = r.widths[j]
		local sep = if j > first then string.rep(" ", Grid.GAP) else ""
		local width = math.min(w, room - used - #sep)
		used += #sep + width
		local mark = if v.sortCol == j then (if v.sortDir == "asc" then " ▲" else " ▼") else ""
		local name = Grid.fit(r.columns[j], math.max(width - Grid.width(mark), 1)) .. mark
		local style = if j == v.col then "strong accent" else "strong"
		table.insert(
			parts,
			ui.text({ ui.span(hard(sep)), ui.span(hard(Grid.fit(name, width)), style) }, {
				key = "h" .. j,
				actions = { click = "sort=" .. j },
				title = "Sort by " .. r.columns[j],
			})
		)
	end
	return ui.row(parts, { key = "cols", gap = "none" })
end

local function rowNode(s: State, r: Result, v: State.View, pos: number, first: number, last: number, room: number): Node
	local i = v.order[pos]
	local row = r.rows[i]
	local selected = pos == v.sel
	local spans: { Span } = { ui.span(if selected then "› " else "  ", "accent") }
	local used = 0
	local null = s.env.null
	for j = first, last do
		local c = r.columns[j]
		local value = if type(row) == "table" then row[c] else nil
		local kind: Grid.Kind = Grid.kind(value, null)
		local sep = if j > first then string.rep(" ", Grid.GAP) else ""
		local width = math.min(r.widths[j], room - used - #sep)
		used += #sep + width
		local text = Grid.fit(Grid.cell(value, null), width, kind == "number")
		local style = cellStyle(kind)
		if selected then
			style = if j == v.col then "strong accent" else (style or "strong")
		end
		if sep ~= "" then
			table.insert(spans, ui.span(sep))
		end
		table.insert(spans, ui.span(text, style))
	end
	-- Keyed by position: a sort moves the selection to another key, and
	-- Tern scrolls the list only when the selected key changes.
	return ui.text(spans, { key = "p" .. pos, actions = { click = "row=" .. pos } })
end

local function results(s: State, r: Result): { Node }
	local v = s.view :: State.View
	local out: { Node } = { resultHead(r, #v.order), actions(s, r), filterInput(s) }
	if #r.columns == 0 or #v.order == 0 then
		local why = if #r.rows == 0 then "The query returned no rows." else "No rows match the filter."
		table.insert(out, ui.muted(why, { key = "empty" }))
		return out
	end
	local room = State.room(s.width)
	local cFirst, cLast = Grid.columnWindow(r.widths, v.col, v.firstCol, room)
	table.insert(out, columnHead(r, v, cFirst, cLast, room))
	local first, last = Grid.window(v.sel, #v.order, v.offset, State.MAX_RENDER_ROWS)
	if first > 1 then
		table.insert(out, ui.muted(string.format("↑ %s more (k, g)", thousands(first - 1)), { key = "above" }))
	end
	local lines: { Node } = table.create(last - first + 1)
	for pos = first, last do
		table.insert(lines, rowNode(s, r, v, pos, cFirst, cLast, room))
	end
	table.insert(out, ui.scroll("rows", lines, "p" .. v.sel, State.MAX_RENDER_ROWS))
	if last < #v.order then
		table.insert(out, ui.muted(string.format("↓ %s more (j, G)", thousands(#v.order - last)), { key = "below" }))
	end
	local hidden = #r.columns - (cLast - cFirst + 1)
	if hidden > 0 then
		table.insert(
			out,
			ui.muted(
				string.format("columns %d–%d of %d (h, l scroll sideways)", cFirst, cLast, #r.columns),
				{ key = "colinfo" }
			)
		)
	end
	return out
end

-- Picker and name prompt ------------------------------------------------------

local function picker(p: State.Picker): { Node }
	local list = Library.filter(p.items, p.text)
	local out: { Node } = {
		ui.text({
			ui.span("Saved queries", "strong"),
			ui.span("  ↵ loads · ⌃↵ loads and runs · ⌃D deletes a saved query · Esc closes", "muted"),
		}, { key = "ptitle" }),
		{
			k = "input",
			p = {
				key = "pickfilter",
				text = p.text,
				cursor = Editor.utf16(p.text),
				placeholder = "type to find a saved query or .sql file",
				prompt = "› ",
			},
		},
	}
	for i, problem in p.problems do
		table.insert(out, ui.text({ ui.span(problem, "warning") }, { key = "pp" .. i }))
	end
	if p.loading then
		table.insert(out, ui.muted("Reading saved queries…", { key = "pempty" }))
		return out
	end
	if #list == 0 then
		local why = if #p.items == 0
			then "Nothing saved yet: Ctrl+S saves the query in the editor; config console.saved_dirs adds .sql folders."
			else "Nothing matches."
		table.insert(out, ui.muted(why, { key = "pempty" }))
		return out
	end
	local sel = math.clamp(p.sel, 1, #list)
	local first, last = Grid.window(sel, #list, 1, State.MAX_RENDER_ROWS)
	local lines: { Node } = {}
	for i = first, last do
		local it = list[i]
		local on = i == sel
		table.insert(
			lines,
			ui.text({
				ui.span(if on then "› " else "  ", "accent"),
				ui.span(if it.kind == "saved" then "saved  " else "file   ", "muted"),
				ui.span(it.label, if on then "strong" else nil),
				ui.span("  " .. it.detail, "muted"),
			}, { key = "p" .. i, actions = { click = "pick=" .. i } })
		)
	end
	table.insert(out, ui.scroll("picks", lines, "p" .. sel, State.MAX_RENDER_ROWS))
	return out
end

local function namePrompt(f: Editor.Field): { Node }
	return {
		ui.text(
			{ ui.span("Save the query as", "strong"), ui.span("  ↵ saves · Esc cancels", "muted") },
			{ key = "ntitle" }
		),
		{
			k = "input",
			p = {
				key = "name",
				text = f.text,
				cursor = Editor.caret(f),
				placeholder = "a name (saving again under a name replaces that query)",
				prompt = "› ",
			},
		},
		ui.row({
			chip("Save", "accent", "nsave", "name-save"),
			chip("Cancel", "neutral", "ncancel", "name-cancel"),
		}, { key = "nact" }),
	}
end

-- Dock ------------------------------------------------------------------------

local function inspector(s: State, r: Result, v: State.View): Node?
	local row, index = State.selectedRow(s)
	if row == nil or index == nil then
		return nil
	end
	local null = s.env.null
	local items: { { { ui.SpanLike } } } = {}
	for j, c in r.columns do
		if j > M.MAX_INSPECT_COLUMNS then
			break
		end
		local value = if type(row) == "table" then row[c] else nil
		local kind: Grid.Kind = Grid.kind(value, null)
		local text = Grid.text(value, null)
		local shown: string
		if text == nil then
			shown = "null"
		elseif #text > M.MAX_INSPECT_TEXT then
			shown = string.sub(text, 1, M.MAX_INSPECT_TEXT) .. "…"
		else
			shown = text
		end
		table.insert(items, {
			{ ui.span(c, if j == v.col then "strong accent" else "strong") },
			{ ui.span(shown, cellStyle(kind)), ui.span("  " .. kind, "muted") },
		})
	end
	local body: { Node } = { ui.kv(items) }
	local idButtons: { Node } = {}
	for k, cell in Grid.idCells(row, r.columns) do
		local what = if string.lower(cell.column) == "id" and r.table
			then r.table .. " " .. cell.id
			else cell.column .. " " .. cell.id
		table.insert(idButtons, chip("Inspect " .. what, "accent", "insp" .. k, "inspect=" .. cell.column))
	end
	if #idButtons > 0 then
		table.insert(body, ui.row(idButtons, { key = "ids", wrap = true }))
	end
	table.insert(body, ui.muted("↵ or Esc closes · j/k move · i inspects the record", { key = "ihint" }))
	local head = string.format("Row %s of %s", thousands(v.sel), thousands(#v.order))
	return ui.col({
		ui.card({ ui.span(head, "strong") }, body, {
			key = "inspect",
			meta = { ui.span(r.connection, if r.production then "error" else "muted") },
		}),
	})
end

local HINTS: { [string]: string } = {
	editor = "⌃↵ run · ↑ on the first line / ↓ on the last: history · ⌃O saved queries · ⌃S save · Tab results",
	grid = "j/k rows · h/l columns · s sort · / filter · ↵ row · i inspect · y/Y copy CSV/TSV · w/W save CSV/JSON · o table · c connection · Tab editor",
	filter = "type to filter · ↵ or Esc back to the rows",
	picker = "↑/↓ choose · ↵ load · ⌃↵ load and run · ⌃D delete · Esc close",
	name = "↵ save · Esc cancel",
}

function M.view(s: State): { main: Node, dock: Node? }
	if #s.targets == 0 then
		return {
			main = ui.col({
				ui.card({ "SuiteQL console" }, {
					ui.text({
						ui.span("No connections are configured. ", "strong"),
						ui.span(
							"Add an account and a connection to connections[] in the config "
								.. "(Tern NetSuite: Open config), then store its credentials with "
								.. "Tern NetSuite: Connect account.",
							"muted"
						),
					}, { key = "none" }),
				}, { key = "card" }),
			}),
		}
	end
	local children: { Node } = { header(s), editorNode(s) }
	local n = s.notice
	if n then
		table.insert(children, ui.text({ ui.span(n.text, NOTICE_STYLE[n.tone]) }, { key = "notice" }))
	end
	if s.err then
		table.insert(children, errorCard(s, s.err))
	end
	local r, v = s.result, s.view
	if s.picker then
		for _, node in picker(s.picker) do
			table.insert(children, node)
		end
	elseif s.name then
		for _, node in namePrompt(s.name) do
			table.insert(children, node)
		end
	elseif r and v then
		for _, node in results(s, r) do
			table.insert(children, node)
		end
	elseif s.running == nil and s.err == nil then
		table.insert(
			children,
			ui.muted("Results show here. The console only runs SELECT / WITH queries.", { key = "empty" })
		)
	end
	local dock: Node? = nil
	if r and v and v.inspect and s.picker == nil and s.name == nil then
		dock = inspector(s, r, v)
	end
	if dock == nil then
		dock = ui.col({ ui.muted(HINTS[s.focus] or HINTS.editor, { key = "keys" }) })
	end
	return { main = ui.col(children), dock = dock }
end

function M.title(s: State): string
	return State.title(s)
end

return M
