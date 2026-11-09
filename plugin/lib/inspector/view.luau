--!strict
-- View of the `inspect` block: connection chips (production in red with a
-- PROD badge), the reference input, the record's title with "Open in
-- NetSuite", tabs for fields / system notes / related records (a window of
-- rows around the selection, ui.scroll) and the selected row in the dock.
-- Errors show inline, per part.

local Catalog = require("./catalog")
local Errors = require("../ns/errors")
local Record = require("./record")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
type State = State.State

local M = {}

M.MAX_DOCK_VALUE = 8000
local LABEL_WIDTH = 24
local MARGIN = 6

local KIND_LABEL: { [string]: string } = {
	auth = "authentication",
	permission = "permission",
	query = "query",
	rate_limit = "rate limit",
	network = "network",
	server = "NetSuite server",
}

local TAB_LABEL: { [string]: string } = { fields = "Fields", notes = "System notes", related = "Related" }

local function width(text: string): number
	return utf8.len(text) or #text
end

local function clip(text: string, max: number): string
	local flat = string.gsub(text, "%s*[\r\n]+%s*", " ⏎ ")
	if width(flat) <= max then
		return flat
	end
	local cut = utf8.offset(flat, math.max(max, 2)) or max
	return string.sub(flat, 1, cut - 1) .. "…"
end

local function pad(text: string, n: number): string
	local c = clip(text, n)
	return c .. string.rep(" ", math.max(n - width(c), 0))
end

local function chip(text: string, tone: string, key: string, action: string?): Node
	return ui.badge(text, tone, { key = key, actions = if action then { click = action } else nil })
end

local function connectionChips(s: State, clickable: boolean): { Node }
	local chips: { Node } = {}
	for i, tg in s.targets do
		local on = i == s.selected
		if on or clickable then
			table.insert(
				chips,
				chip(
					tg.id .. " · " .. tg.account_label,
					if on then (if tg.production then "error" else "accent") else "neutral",
					"c" .. i,
					if clickable then "conn=" .. tg.id else nil
				)
			)
		end
		if on and tg.production then
			table.insert(chips, chip("PROD", "error", "prod", nil))
		end
	end
	return chips
end

local function hint(e: Errors.NsError): string?
	if e.code == Errors.NO_CREDENTIALS or e.kind == "auth" then
		return "Store or fix this connection's credentials with Tern NetSuite: Connect account."
	elseif e.code == Errors.NO_WINDOW then
		return "Queries run in the window half of the plugin: keep a Tern window open."
	elseif e.kind == "permission" then
		return "The connection's role needs SuiteQL access to this record type"
			.. " (and to systemnote, customfield and transactionline for the other tabs)."
	elseif e.kind == "rate_limit" then
		return "NetSuite is throttling requests; press r to try again later."
	end
	return nil
end

local function errorNodes(e: Errors.NsError, key: string): { Node }
	local tail: { string } = {}
	if e.code then
		table.insert(tail, e.code)
	end
	if e.status then
		table.insert(tail, "HTTP " .. tostring(e.status))
	end
	local out: { Node } = {
		ui.row({ ui.badge(KIND_LABEL[e.kind] or e.kind, "error"), ui.text({ ui.span(e.message) }) }, { key = key }),
	}
	if #tail > 0 then
		table.insert(out, ui.muted(table.concat(tail, " · "), { key = key .. "code" }))
	end
	local h = hint(e)
	if h then
		table.insert(out, ui.text({ ui.span(h) }, { key = key .. "hint" }))
	end
	return out
end

local function inputNode(s: State): Node
	return {
		k = "input",
		p = {
			key = "ref",
			text = s.input,
			cursor = #s.input,
			placeholder = "paste a NetSuite record URL or type:id (salesorder:123), Enter inspects",
			prompt = "› ",
		},
	}
end

local function kindLabel(cur: State.Inspection): string
	if cur.kind then
		return (cur.kind :: Catalog.Kind).label
	end
	return string.format("Custom record (type %d)", cur.ref.rectype or 0)
end

local function titleLine(s: State, cur: State.Inspection): Node
	local spans: { Span } = { ui.span(kindLabel(cur), "accent") }
	if cur.title then
		table.insert(spans, ui.span("  " .. cur.title, "strong"))
	end
	table.insert(spans, ui.span("  #" .. cur.ref.id, "muted"))
	if State.loading(s) then
		table.insert(spans, ui.span("  loading…", "muted"))
	end
	return ui.text(spans, { key = "title" })
end

local function actionChips(s: State): Node
	local chips: { Node } = {}
	if State.uiUrl(s) then
		table.insert(chips, chip("Open in NetSuite", "accent", "openui", "open-ui"))
	end
	if #s.history > 0 then
		table.insert(chips, chip(string.format("Back (%d)", #s.history), "neutral", "back", "back"))
	end
	table.insert(chips, chip("Reload", "neutral", "reload", "reload"))
	return ui.row(chips, { key = "acts", wrap = true })
end

local function tabs(s: State): Node
	local chips: { Node } = {}
	for i, tab in State.TABS do
		local n = State.count(s, tab)
		local loading = (tab == "notes" and State.loading(s, "notes"))
			or (
				tab == "related"
				and (State.loading(s, "lines") or State.loading(s, "children") or State.loading(s, "txns"))
			)
		local text = string.format("%d %s (%s)", i, TAB_LABEL[tab], if loading then "…" else tostring(n))
		table.insert(chips, chip(text, if tab == s.tab then "accent" else "neutral", "t" .. tab, "tab=" .. tab))
	end
	if s.tab == "fields" then
		table.insert(
			chips,
			chip(if s.showEmpty then "hide empty (e)" else "show empty (e)", "neutral", "empty", "empty")
		)
	end
	return ui.row(chips, { key = "tabs", wrap = true })
end

local function fieldLabel(cur: State.Inspection, column: string): (string, string?)
	local label = State.label(cur, column)
	if label then
		return label, column
	end
	return column, nil
end

-- Where the standard field labels come from, or why there are none.
local function labelSource(cur: State.Inspection): Node?
	if cur.errs.std or cur.pending.std then
		return nil
	end
	if cur.stdNote then
		return ui.muted(cur.stdNote :: string, { key = "stdnote" })
	end
	if cur.stdFetched == nil then
		return nil
	end
	local text = string.format(
		"Standard labels: NetSuite's metadata catalog, fetched %s%s · l refreshes",
		os.date("%Y-%m-%d", cur.stdFetched :: number),
		if cur.stdCached then " (cached)" else ""
	)
	return ui.text({ ui.span(text, "muted") }, { key = "stdsrc", actions = { click = "labels" } })
end

local function fieldRow(s: State, cur: State.Inspection, f: Record.Field, i: number, selected: boolean): Node
	local cols = s.width or 120
	local label, column = fieldLabel(cur, f.column)
	local lw = math.clamp((cols - MARGIN) // 3, 12, LABEL_WIDTH)
	local name = if column then label .. " (" .. column .. ")" else label
	local spans: { Span } = {
		ui.span(if selected then "› " else "  ", "accent"),
		ui.span(pad(name, lw) .. "  ", if column then "accent" else "muted"),
	}
	local display = cur.names[f.column]
	local room = math.max(cols - MARGIN - lw - 2, 8)
	if f.value == nil then
		table.insert(spans, ui.span("—", "muted"))
	elseif display and display ~= f.value then
		table.insert(spans, ui.span(clip(display, room), if selected then "strong" else nil))
		table.insert(spans, ui.span(clip("  " .. f.value, math.max(room - width(display), 6)), "muted"))
	else
		table.insert(spans, ui.span(clip(f.value, room), if selected then "strong" else nil))
	end
	return ui.text(spans, { key = "f" .. i, actions = { click = "sel=" .. i } })
end

-- `Document Status (TRANDOC.KSTATUS)`, or the field id alone.
local function noteField(n: Record.Note): string?
	if n.field and n.fieldLabel then
		return n.fieldLabel .. " (" .. n.field .. ")"
	end
	return n.field
end

local function noteRow(s: State, n: Record.Note, i: number, selected: boolean): Node
	local cols = s.width or 120
	local spans: { Span } = {
		ui.span(if selected then "› " else "  ", "accent"),
		ui.span(n.noted .. "  ", "muted"),
		ui.span(pad(n.who or "?", 18) .. "  ", if selected then "strong" else nil),
		ui.span(pad(n.action or "", 7) .. " ", "accent"),
	}
	if n.field or n.old or n.new then
		local change = (noteField(n) or "?") .. ": " .. (n.old or "∅") .. " → " .. (n.new or "∅")
		table.insert(spans, ui.span(clip(change, math.max(cols - MARGIN - 50, 12))))
	end
	return ui.text(spans, { key = "n" .. i, actions = { click = "sel=" .. i } })
end

local function relatedRow(s: State, r: Record.Related, i: number, selected: boolean): Node
	local cols = s.width or 120
	local kind = Catalog.get(r.record)
	local what = (if kind then kind.label else r.record) .. " #" .. r.id
	local spans: { Span } = {
		ui.span(if selected then "› " else "  ", "accent"),
		ui.span(pad(r.label, 22) .. "  ", "muted"),
		ui.span(what, "accent"),
	}
	if r.name then
		table.insert(spans, ui.span("  " .. clip(r.name, math.max(cols - MARGIN - 30 - width(what), 8)), "strong"))
	end
	return ui.text(spans, { key = "r" .. i, actions = { click = "go=" .. i } })
end

local function listNodes(s: State, cur: State.Inspection): { Node }
	local out: { Node } = {}
	local tab = s.tab
	local n = State.count(s, tab)
	local errParts: { string } = if tab == "fields"
		then { "std", "labels-plain" }
		elseif tab == "notes" then { "notes" }
		else { "display", "lines", "children", "txns" }
	for _, part in errParts do
		local e = cur.errs[part]
		if e then
			local what = if part == "std"
				then "Standard field labels are unavailable (column names shown)"
				elseif part == "labels-plain" then "Custom field labels are unavailable"
				elseif part == "display" then "Display names are unavailable"
				elseif part == "lines" then "Transaction lines could not be read"
				elseif part == "notes" then "System notes could not be read"
				else "Linked transactions could not be read"
			table.insert(out, ui.text({ ui.span(what .. ": ", "warning"), ui.span(e.message) }, { key = "e" .. part }))
			local h = if part == "std" and e.kind == "permission"
				then "Field labels need the role's REST Web Services permission; press l to try again."
				else hint(e)
			if h then
				table.insert(out, ui.muted(h, { key = "h" .. part }))
			end
		end
	end
	if tab == "fields" then
		local src = labelSource(cur)
		if src then
			table.insert(out, src)
		end
	end
	if tab == "notes" and cur.notice then
		table.insert(out, ui.muted(cur.notice :: string, { key = "notice" }))
	end
	if n == 0 then
		local empty: string? = if tab == "fields"
			then (if cur.fields then "No non-empty fields (e shows empty ones)." else "Loading…")
			elseif tab == "notes" then (if cur.notes
				then "No system notes."
				elseif cur.errs.notes then nil
				else "Loading…")
			else (if State.loading(s) then "Loading…" else "No related records found.")
		if empty then
			table.insert(out, ui.muted(empty, { key = "empty" }))
		end
		return out
	end
	local sel = State.selection(s, tab)
	local first, last = State.window(sel, n, s.offset[tab] or 1, State.MAX_RENDER_ROWS)
	if first > 1 then
		table.insert(out, ui.muted(string.format("↑ %d more (k, g)", first - 1), { key = "above" }))
	end
	local rows: { Node } = table.create(last - first + 1)
	local fields = if tab == "fields" then State.visibleFields(s) else {}
	local related = if tab == "related" then State.related(s) else {}
	local notes: { Record.Note } = cur.notes or {}
	local prefix = if tab == "fields" then "f" elseif tab == "notes" then "n" else "r"
	for i = first, last do
		if tab == "fields" then
			table.insert(rows, fieldRow(s, cur, fields[i], i, i == sel))
		elseif tab == "notes" then
			table.insert(rows, noteRow(s, notes[i], i, i == sel))
		else
			table.insert(rows, relatedRow(s, related[i], i, i == sel))
		end
	end
	table.insert(out, ui.scroll("rows-" .. tab, rows, prefix .. sel, State.MAX_RENDER_ROWS))
	if last < n then
		table.insert(out, ui.muted(string.format("↓ %d more (j, G)", n - last), { key = "below" }))
	end
	if tab == "notes" and cur.notesTruncated then
		table.insert(out, ui.muted(string.format("Only the newest %d notes are shown.", n), { key = "ntrunc" }))
	end
	return out
end

local function dock(s: State, cur: State.Inspection): Node?
	local body: { Node } = {}
	if s.tab == "fields" then
		local f = State.visibleFields(s)[State.selection(s, "fields")]
		if f == nil then
			return nil
		end
		local label, column = fieldLabel(cur, f.column)
		local head: { Span } = { ui.span(label, "strong") }
		if column then
			table.insert(head, ui.span("  " .. column, "muted"))
		end
		table.insert(body, ui.text(head, { key = "dhead" }))
		local display = cur.names[f.column]
		if display and display ~= f.value then
			table.insert(body, ui.text({ ui.span("Display  ", "muted"), ui.span(display) }, { key = "ddisp" }))
		end
		local value = f.value or "(empty)"
		if #value > M.MAX_DOCK_VALUE then
			value = string.sub(value, 1, M.MAX_DOCK_VALUE) .. "\n…"
		end
		table.insert(body, ui.code(value, nil, nil, { key = "dval" }))
	elseif s.tab == "notes" then
		local n = (cur.notes or {})[State.selection(s, "notes")]
		if n == nil then
			return nil
		end
		local meta: { string } = { n.noted }
		for _, v in { n.who, n.role, n.context, n.action } do
			if v then
				table.insert(meta, v)
			end
		end
		table.insert(body, ui.text({ ui.span(table.concat(meta, " · "), "muted") }, { key = "dhead" }))
		table.insert(body, ui.text({ ui.span(noteField(n) or "(no field)", "strong") }, { key = "dfield" }))
		table.insert(body, ui.code("- " .. (n.old or "") .. "\n+ " .. (n.new or ""), "diff", nil, { key = "dval" }))
	else
		return nil
	end
	return ui.col(body, { key = "detail" })
end

local HINT = "j/k move · tab or 1/2/3 switch · enter opens a related record (shift+enter: in a new pane)"
	.. " · o Open in NetSuite · / new record · b back · r reload · l refresh labels · c connection · esc close"
local HELD_HINT = "enter inspects · esc closes"

local function heldView(s: State): { main: Node, dock: Node? }
	local cur = s.cur :: State.Inspection
	local conn: { Node } = { ui.text({ ui.span("Connection  ", "muted") }) }
	for _, n in connectionChips(s, false) do
		table.insert(conn, n)
	end
	if State.target(s) == nil then
		table.insert(conn, ui.badge("none", "neutral"))
	end
	local body: { Node } = {
		ui.row(conn, { key = "hconn" }),
		ui.text({
			ui.span("Record      ", "muted"),
			ui.span(kindLabel(cur), "accent"),
			ui.span("  #" .. cur.ref.id, "strong"),
		}, { key = "hrec" }),
		ui.text({
			ui.span("Opened from a link: nothing is read until you press Enter. Reading is read-only.", "muted"),
		}, { key = "hwhy" }),
		ui.row({
			chip("Enter inspects", "accent", "start", "start"),
			chip("Close", "neutral", "close", "close"),
		}, { key = "hact" }),
	}
	local children: { Node } = {
		ui.card({ ui.span("Inspect a NetSuite record?", "strong") }, body, { key = "held" }),
	}
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "warning") }, { key = "problem" }))
	end
	table.insert(children, ui.muted(HELD_HINT, { key = "keys" }))
	return { main = ui.col(children), dock = nil }
end

function M.view(s: State): { main: Node, dock: Node? }
	if #s.targets == 0 then
		return {
			main = ui.col({
				ui.card({ "NetSuite record inspector" }, {
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
	if s.held and s.cur then
		return heldView(s)
	end
	local children: { Node } = { ui.row(connectionChips(s, true), { key = "head", wrap = true }), inputNode(s) }
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "warning") }, { key = "problem" }))
	end
	local cur = s.cur
	if cur == nil then
		table.insert(
			children,
			ui.muted(
				"Paste a record URL from the NetSuite UI, or type type:id (salesorder:123, customer:42, "
					.. "item:7, customrecord_x:5). Reading is read-only.",
				{ key = "intro" }
			)
		)
		return { main = ui.col(children), dock = nil }
	end
	table.insert(children, titleLine(s, cur))
	table.insert(children, actionChips(s))
	local recErr = cur.errs.record or cur.errs.rectype
	if recErr then
		table.insert(
			children,
			ui.card({ ui.span("The record cannot be read", "strong") }, errorNodes(recErr, "err"), { key = "errcard" })
		)
	elseif cur.missing then
		table.insert(
			children,
			ui.text({
				ui.span(string.format("No %s has internal id %s", kindLabel(cur), cur.ref.id), "warning"),
				ui.span(" on this connection (or its role cannot see it).", "muted"),
			}, { key = "missing" })
		)
	else
		table.insert(children, tabs(s))
		for _, n in listNodes(s, cur) do
			table.insert(children, n)
		end
	end
	table.insert(children, ui.muted(HINT, { key = "keys" }))
	return { main = ui.col(children), dock = if recErr or cur.missing then nil else dock(s, cur) }
end

function M.title(s: State): string
	local tg = State.target(s)
	local cur = s.cur
	local base = "NetSuite record"
	if cur then
		base = kindLabel(cur) .. " " .. (cur.title or ("#" .. cur.ref.id))
	end
	if tg then
		base ..= " · " .. tg.id
		if tg.production then
			base ..= " · PROD"
		end
	end
	return if s.held then base .. " (press Enter)" else base
end

return M
