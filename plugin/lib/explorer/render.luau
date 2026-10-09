--!strict
-- Draws the explorer: header, tabs, scan progress, notice, filter line and
-- a window of the current view's rows (at most State.MAX_RENDER_ROWS lines,
-- with "more above/below" lines) in a list that fills the pane and keeps
-- the selected row in view (ui.scroll), plus a dock of key hints.

local Rows = require("./rows")
local State = require("./state")
local Types = require("./types")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
type Row = Types.Row

local M = {}

local function relative(s: Types.State, path: string): string
	return Rows.relative(s.base, path)
end

local function rowKey(r: Row): string
	return "row:" .. r.key
end

local function rowNode(r: Row, index: number, rows: { Row }, selected: boolean): Node
	local spans: { ui.SpanLike } = {}
	if r.target then
		table.insert(spans, if selected then ui.span("▸ ", "accent strong") else ui.span("  "))
	else
		table.insert(spans, ui.span("  "))
	end
	if r.depth > 0 then
		table.insert(spans, ui.span(string.rep("  ", r.depth)))
	end
	for i, sp in r.spans do
		local style = sp.s
		if selected and i == 1 then
			style = if style then style .. " strong" else "strong"
		end
		table.insert(spans, ui.span(sp.t, style))
	end
	local props: { [string]: any } = { key = rowKey(r) }
	if r.tone then
		props.tone = r.tone
	end
	if r.target then
		props.actions = { click = "row=" .. State.clickValue(rows, index) }
	end
	if r.badges and #r.badges > 0 then
		local children: { Node } = { ui.text(spans, { key = "label" }) }
		for i, b in r.badges do
			table.insert(children, ui.badge(b.text, b.tone, { key = "b" .. i, title = b.title }))
		end
		return ui.row(children, props)
	end
	return ui.text(spans, props)
end

local function tabs(s: Types.State): Node
	local function tab(label: string, active: boolean): Span
		return ui.span(label, if active then "strong accent" else "muted")
	end
	local onProjects = s.tab == "projects" and not s.picking
	local spans: { ui.SpanLike } = {
		tab(string.format("Projects (%d)", #s.projects), onProjects),
		"   ",
		tab(string.format("Findings (%d)", #s.findings), s.tab == "findings" and not s.picking),
	}
	if s.picking then
		table.insert(spans, "   ")
		table.insert(spans, tab("Upload", true))
	end
	if onProjects and s.detail then
		local p = Rows.project(s, s.detail)
		table.insert(spans, ui.span("   › ", "muted"))
		table.insert(spans, ui.span(if p then p.name else relative(s, s.detail), "strong"))
	end
	return ui.text(spans, { key = "tabs" })
end

local function progress(s: Types.State): Node?
	if s.phase == "loading" then
		return ui.row({
			{ k = "spinner", p = { style = "dots", tone = "accent" } },
			ui.muted("Finding SDF projects…"),
		}, { key = "progress" })
	elseif s.phase == "scanning" then
		local name = if s.current then relative(s, s.current) else ""
		return ui.row({
			{ k = "spinner", p = { style = "dots", tone = "accent" } },
			ui.muted(string.format("Scanning %d/%d: %s", math.min(s.done + 1, s.total), s.total, name)),
		}, { key = "progress" })
	end
	return nil
end

function M.view(s: Types.State): { main: Node, dock: Node }
	local main: { Node } = {}
	table.insert(
		main,
		ui.text({ ui.span("SDF explorer", "strong"), ui.span("  " .. (s.base or s.cwd), "muted") }, { key = "head" })
	)
	table.insert(main, tabs(s))
	local p = progress(s)
	if p then
		table.insert(main, p)
	end
	if s.skipped > 0 then
		table.insert(
			main,
			ui.text({
				ui.span(
					string.format("%d more projects not scanned (limit %d)", s.skipped, State.MAX_PROJECTS),
					"warning"
				),
			}, { key = "skipped" })
		)
	end
	if s.notice then
		table.insert(main, ui.text({ ui.span(s.notice.text, s.notice.tone) }, { key = "notice" }))
	end
	local vk = State.viewKey(s)
	local filter = s.filters[vk]
	local rows = State.rows(s)
	if s.editing or filter then
		local spans: { ui.SpanLike } = { ui.span("/", "key"), " ", ui.span(filter or "", "mono") }
		if s.editing then
			table.insert(spans, ui.span("▏", "accent"))
		end
		table.insert(spans, ui.span(string.format("  %d rows", #rows), "muted"))
		table.insert(main, ui.text(spans, { key = "filter" }))
	end

	local selected = State.selectedIndex(s, rows)
	local first, last = State.window(s, rows, selected)
	if first > 1 then
		table.insert(main, ui.muted(string.format("↑ %d more above (k, pageup, g)", first - 1), { key = "above" }))
	end
	local list: { Node } = {}
	for i = first, last do
		table.insert(list, rowNode(rows[i], i, rows, i == selected))
	end
	table.insert(
		main,
		ui.scroll("rows", list, if rows[selected] then rowKey(rows[selected]) else nil, State.MAX_RENDER_ROWS)
	)
	if last < #rows then
		table.insert(
			main,
			ui.muted(string.format("↓ %d more below (j, pagedown, G; / filters)", #rows - last), { key = "below" })
		)
	end

	local hints: { ui.SpanLike } = {
		ui.span("j/k", "key"),
		" move  ",
		ui.span("enter", "key"),
		" open  ",
	}
	if s.detail or s.picking then
		table.insert(hints, ui.span("⌫", "key"))
		table.insert(hints, " back  ")
	end
	for _, h in
		{
			{ "u", "upload" },
			{ "v", "copy validate" },
			{ "/", "filter" },
			{ "tab", "projects/findings" },
			{ "r", "rescan" },
			{ "esc", "close" },
		}
	do
		table.insert(hints, ui.span(h[1], "key"))
		table.insert(hints, " " .. h[2] .. "  ")
	end
	return {
		main = ui.col(main, { role = "tern-netsuite.explorer" }),
		dock = ui.col({ ui.text(hints, { key = "hints" }) }, { role = "tern-netsuite.explorer-dock" }),
	}
end

function M.title(s: Types.State): string
	return State.title(s)
end

return table.freeze(M)
