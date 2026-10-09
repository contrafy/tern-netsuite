--!strict
-- View of the `logs` block: connection chips (production in red), the tail
-- status, inline errors with what to do, the filter, a window of log rows
-- (newest first) and the selected row's detail in the dock.

local Detail = require("./detail")
local Entry = require("./entry")
local Errors = require("../../ns/errors")
local State = require("./state")
local ui = require("../../ui")

type Node = ui.Node
type Span = ui.Span
type State = State.State
type Entry = Entry.Entry

local M = {}

M.MAX_RAW_DETAIL = 8000
local PREVIEW = 140
local SCRIPT_WIDTH = 28

local KIND_LABEL: { [string]: string } = {
	auth = "authentication",
	permission = "permission",
	query = "query",
	rate_limit = "rate limit",
	network = "network",
	server = "NetSuite server",
}

local function seconds(ms: number): string
	local s = math.floor(ms / 1000 + 0.5)
	return if s >= 60 and s % 60 == 0 then string.format("%dm", s // 60) else string.format("%ds", s)
end

local function pad(text: string, width: number): string
	local n = utf8.len(text) or #text
	if n > width then
		local cut = utf8.offset(text, width) or width
		return string.sub(text, 1, cut - 1) .. "…"
	end
	return text .. string.rep(" ", width - n)
end

local function chip(text: string, tone: string, key: string, action: string?): Node
	return ui.badge(text, tone, { key = key, actions = if action then { click = action } else nil })
end

local function statusChip(s: State): Node
	if s.err and s.stopped then
		return chip("stopped · r retries", "error", "status", "reload")
	elseif s.err and s.retryMs then
		return chip("retrying every " .. seconds(s.retryMs), "warning", "status", nil)
	elseif s.paused then
		return chip("paused · p resumes", "warning", "status", "pause")
	elseif not s.loaded and s.inflight then
		return chip("loading…", "neutral", "status", nil)
	end
	return chip("live · every " .. seconds(s.pollMs), "success", "status", "pause")
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
				"conn=" .. tg.id
			)
		)
		if on and tg.production then
			table.insert(chips, chip("PROD", "error", "prod", nil))
		end
	end
	table.insert(chips, statusChip(s))
	table.insert(chips, chip("level ≥ " .. Entry.LEVELS[s.level], "neutral", "level", "level"))
	table.insert(chips, chip(if s.paused then "Resume" else "Pause", "neutral", "pause", "pause"))
	table.insert(chips, chip("Reload", "neutral", "reload", "reload"))
	return ui.row(chips, { key = "head", wrap = true })
end

local function scopeLine(s: State): Node?
	local parts: { string } = {}
	if #s.scope.scripts > 0 then
		table.insert(parts, "scripts: " .. table.concat(s.scope.scripts, ", "))
	end
	local since = s.scope.since
	if since then
		table.insert(
			parts,
			"since " .. (if since.minutes then string.format("%d minutes ago", since.minutes) else since.at or "")
		)
	end
	if #parts == 0 then
		return nil
	end
	return ui.muted("Scope: " .. table.concat(parts, " · "), { key = "scope" })
end

local function hint(e: Errors.NsError): string?
	if e.code == Errors.NO_CREDENTIALS or e.kind == "auth" then
		if string.find(e.message, "Connect account", 1, true) then
			return nil
		end
		return "Store or fix this connection's credentials with Tern NetSuite: Connect account."
	elseif e.code == Errors.NO_CONNECTION then
		return "Add it to connections[] in the config (Tern NetSuite: Open config), or press c to pick a configured one."
	elseif e.code == Errors.NO_WINDOW then
		return "Queries run in the window half of the plugin: keep a Tern window open."
	elseif e.code == Errors.READ_ONLY then
		return nil
	elseif e.kind == "permission" then
		return "The connection's role needs SuiteQL access to script execution logs (scriptnote) and scripts."
	elseif e.kind == "rate_limit" then
		return "NetSuite is throttling requests; polling backs off and resumes on its own."
	end
	return nil
end

local function errorCard(s: State, e: Errors.NsError): Node
	local tail: { string } = {}
	if e.code then
		table.insert(tail, e.code)
	end
	if e.status then
		table.insert(tail, "HTTP " .. tostring(e.status))
	end
	if s.retryMs and not s.stopped then
		table.insert(tail, "next try in " .. seconds(s.retryMs))
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
	if (e.code == Errors.NO_CREDENTIALS or e.kind == "auth") and State.target(s) then
		table.insert(body, ui.row({ chip("Connect account", "accent", "connect", "connect") }, { key = "erract" }))
	end
	return ui.card({ ui.span("The log tail cannot read NetSuite", "strong") }, body, { key = "errcard" })
end

-- Rows must stay on one line so the scrolling list (ui.scroll) counts its
-- lines right: the script column and the date shrink in narrow blocks, then
-- the title is clipped and the detail preview fills what is left.
local MARGIN = 4
local LEVEL_WIDTH = 10
local MIN_PREVIEW = 12

local function width(text: string): number
	return utf8.len(text) or #text
end

local function titleSpans(s: State, e: Entry, max: number?): { Span }
	if max and width(e.title) > max then
		return { ui.span(Detail.preview(e.title, max), "strong") }
	end
	if s.titleJson and e.namespace then
		return { ui.span(e.namespace, "accent"), ui.span(":", "muted"), ui.span(e.event, "strong") }
	end
	return { ui.span(e.title, "strong") }
end

local function rowNode(s: State, e: Entry, selected: boolean): Node
	local cols = s.width or 120
	local wide = cols >= 90
	local time = if wide
		then string.match(e.logged, "^%d%d%d%d%-(%d%d%-%d%d %d%d:%d%d:%d%d)$")
		else string.match(e.logged, "(%d%d:%d%d:%d%d)$")
	local avail = cols - MARGIN - 2 - (if wide then 16 else 10) - LEVEL_WIDTH
	local scriptWidth = math.clamp(avail // 3, 6, SCRIPT_WIDTH)
	local titleMax = math.max(avail - scriptWidth - 2, 4)
	local spans: { Span } = {
		ui.span(if selected then "› " else "  ", "accent"),
		ui.span((time or e.logged) .. "  ", "muted"),
		ui.span(pad(e.level, LEVEL_WIDTH - 1) .. " ", Entry.tone(e.level)),
		ui.span(pad(Entry.scriptLabel(e), scriptWidth) .. "  ", if selected then "strong" else nil),
	}
	for _, t in titleSpans(s, e, titleMax) do
		table.insert(spans, t)
	end
	local room = math.min(titleMax - width(e.title) - 2, PREVIEW)
	if e.detail ~= "" and room >= MIN_PREVIEW then
		table.insert(spans, ui.span("  " .. Detail.preview(e.detail, room), "muted"))
	end
	return ui.text(spans, { key = "r" .. e.id, actions = { click = "sel=" .. e.id } })
end

local function counts(s: State, shown: number): Node
	local total = #s.buffer.entries
	local parts: { string } = {}
	if shown == total then
		table.insert(parts, string.format("%d rows", total))
	else
		table.insert(parts, string.format("%d of %d rows", shown, total))
	end
	if s.polledAt then
		table.insert(parts, "polled " .. s.polledAt)
	end
	if s.buffer.dropped > 0 then
		table.insert(parts, string.format("%d older rows dropped (the tail keeps %d)", s.buffer.dropped, s.buffer.cap))
	end
	return ui.muted(table.concat(parts, " · "), { key = "counts" })
end

local function emptyText(s: State): string
	if #s.buffer.entries > 0 then
		return "No rows match the filter and level."
	elseif s.inflight and not s.loaded then
		return "Loading the newest execution log lines…"
	elseif s.err then
		return "No rows yet."
	end
	return "No execution log lines yet; new ones appear as scripts log them."
end

local function rows(s: State): { Node }
	local list = State.visible(s)
	local out: { Node } = { counts(s, #list) }
	if #list == 0 then
		table.insert(out, ui.muted(emptyText(s), { key = "empty" }))
		return out
	end
	local sel = State.selectedIndex(s, list)
	local first, last = State.window(sel, #list, s.offset, State.MAX_RENDER_ROWS)
	if first > 1 then
		table.insert(
			out,
			ui.muted(
				string.format("↑ %d newer (k, g)", first - 1),
				{ key = "above", actions = { click = "page=up" } }
			)
		)
	end
	local lines: { Node } = table.create(last - first + 1)
	for i = first, last do
		table.insert(lines, rowNode(s, list[i], i == sel))
	end
	table.insert(out, ui.scroll("rows", lines, "r" .. list[sel].id, State.MAX_RENDER_ROWS))
	if last < #list then
		table.insert(
			out,
			ui.muted(
				string.format("↓ %d older (j, G)", #list - last),
				{ key = "below", actions = { click = "page=down" } }
			)
		)
	end
	return out
end

local function filterInput(s: State): Node
	return {
		k = "input",
		p = {
			key = "filter",
			text = s.filterText,
			cursor = #s.filterText,
			placeholder = "press / to filter: words, ns:<namespace>, script:<id or name>",
			prompt = "/",
		},
	}
end

local function dock(s: State): Node?
	local e = State.selected(s)
	local parsed = State.detail(s)
	if e == nil or parsed == nil then
		return nil
	end
	local head: { Span } = {
		ui.span(e.logged .. "  ", "muted"),
		ui.span(e.level .. "  ", Entry.tone(e.level)),
		ui.span(Entry.scriptLabel(e), "strong"),
	}
	if e.scriptId and e.scriptName then
		table.insert(head, ui.span(" (" .. e.scriptId .. ")", "muted"))
	end
	table.insert(head, ui.span("  #" .. e.id, "muted"))
	local body: { Node } = {
		ui.text(head, { key = "dhead" }),
		ui.text(titleSpans(s, e), { key = "dtitle" }),
	}
	if parsed.json and parsed.tree then
		table.insert(body, ui.tree(parsed.tree :: any, { key = "dtree" }))
		if parsed.truncated then
			table.insert(body, ui.muted("Large detail: some nodes are not shown.", { key = "dtrunc" }))
		end
	elseif e.detail == "" then
		table.insert(body, ui.muted("(no detail)", { key = "dnone" }))
	else
		local raw = e.detail
		if #raw > M.MAX_RAW_DETAIL then
			raw = string.sub(raw, 1, M.MAX_RAW_DETAIL) .. "\n…"
		end
		table.insert(body, ui.code(raw, nil, nil, { key = "draw" }))
	end
	table.insert(body, ui.muted("enter closes · j/k move", { key = "dhint" }))
	return ui.col(body, { key = "detail" })
end

local HINT = "j/k move · enter detail · / filter · l level · p pause · c connection · r reload · esc close"

function M.view(s: State): { main: Node, dock: Node? }
	if #s.targets == 0 then
		return {
			main = ui.col({
				ui.card({ "NetSuite execution logs" }, {
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
	local children: { Node } = { header(s) }
	local scope = scopeLine(s)
	if scope then
		table.insert(children, scope)
	end
	if s.err then
		table.insert(children, errorCard(s, s.err))
	end
	if s.notice then
		table.insert(children, ui.text({ ui.span(s.notice, "warning") }, { key = "notice" }))
	end
	table.insert(children, filterInput(s))
	for _, n in rows(s) do
		table.insert(children, n)
	end
	table.insert(children, ui.muted(HINT, { key = "keys" }))
	return { main = ui.col(children), dock = dock(s) }
end

function M.title(s: State): string
	local tg = State.target(s)
	local base = if tg then "NetSuite logs · " .. tg.id else "NetSuite logs"
	return if s.paused then base .. " (paused)" else base
end

return M
