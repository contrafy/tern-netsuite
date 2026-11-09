--!strict
-- View of the `deployments` block: connection chips (production in red),
-- filter chips, inline errors with what to do, the text filter, a window of
-- deployment rows (ui.scroll) and, in the dock, the selected deployment
-- with its actions or the edit of its local SDF object file.

local Errors = require("../ns/errors")
local Filter = require("./filter")
local Query = require("./query")
local State = require("./state")
local Values = require("./values")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
type State = State.State
type Deployment = Query.Deployment

local M = {}

local KIND_LABEL: { [string]: string } = {
	auth = "authentication",
	permission = "permission",
	query = "query",
	rate_limit = "rate limit",
	network = "network",
	server = "NetSuite server",
}

local FACET_LABEL: { [string]: string } = { type = "type", status = "status", level = "level" }

local function width(text: string): number
	return utf8.len(text) or #text
end

local function pad(text: string, w: number): string
	local n = width(text)
	if n > w then
		local cut = utf8.offset(text, math.max(w, 1)) or w
		return string.sub(text, 1, cut - 1) .. "…"
	end
	return text .. string.rep(" ", w - n)
end

local function chip(text: string, tone: string, key: string, action: string?): Node
	return ui.badge(text, tone, { key = key, actions = if action then { click = action } else nil })
end

local function statusText(d: Deployment): string
	if d.deployed == false then
		return "NOT DEPLOYED"
	end
	return if d.status ~= "" then d.status else "?"
end

function M.statusTone(d: Deployment): string?
	if d.deployed == false then
		return "warning"
	elseif d.status == "TESTING" then
		return "warning"
	elseif d.status == "RELEASED" or d.status == "SCHEDULED" then
		return "success"
	end
	return "muted"
end

local function levelTone(level: string): string?
	if level == "DEBUG" then
		return "accent"
	elseif level == "EMERGENCY" then
		return "error"
	end
	return "muted"
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
	if s.inflight then
		table.insert(chips, chip("loading…", "neutral", "status", nil))
	end
	for _, facet in Filter.FACETS do
		local v = (s.filter :: any)[facet]
		local label = FACET_LABEL[facet]
			.. ": "
			.. (if v then (if facet == "type" then Query.typeLabel(v) else v) else "all")
		table.insert(chips, chip(label, if v then "accent" else "neutral", "f-" .. facet, "facet=" .. facet))
	end
	if not Filter.isEmpty(s.filter) then
		table.insert(chips, chip("Clear filters", "neutral", "clear", "clear"))
	end
	table.insert(chips, chip("Reload", "neutral", "reload", "reload"))
	return ui.row(chips, { key = "head", wrap = true })
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
	elseif e.kind == "permission" then
		return "The connection's role needs SuiteQL access to script deployments (scriptdeployment) and scripts."
	elseif e.kind == "rate_limit" then
		return "NetSuite is throttling requests; press r to try again in a moment."
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
	local actions: { Node } = { chip("Retry", "neutral", "retry", "reload") }
	if (e.code == Errors.NO_CREDENTIALS or e.kind == "auth") and State.target(s) then
		table.insert(actions, 1, chip("Connect account", "accent", "connect", "connect"))
	end
	table.insert(body, ui.row(actions, { key = "erract" }))
	return ui.card({ ui.span("Script deployments cannot be read", "strong") }, body, { key = "errcard" })
end

local MARGIN = 4
local ID_WIDTH = 36
local STATUS_WIDTH = 13
local LEVEL_WIDTH = 10
local TYPE_WIDTH = 15

local function activitySpans(s: State, d: Deployment): { Span }
	local a = State.activityOf(s, d)
	if a == nil or a.total == 0 then
		return {}
	end
	if a.errors > 0 then
		return { ui.span(string.format("  %d err/24h", a.errors), "error") }
	end
	return { ui.span(string.format("  %d lines/24h", a.total), "muted") }
end

-- Rows must stay on one line so the scrolling list (ui.scroll) counts its
-- lines right: columns drop out right to left as the block narrows (type,
-- then log level, then status), and the id is clipped last.
local MIN_ID = 10

local function rowNode(s: State, d: Deployment, selected: boolean): Node
	local cols = s.width or 120
	local avail = cols - MARGIN - 2
	local showStatus = avail >= MIN_ID + 2 + STATUS_WIDTH
	local showLevel = showStatus and avail >= MIN_ID + 2 + STATUS_WIDTH + LEVEL_WIDTH
	local showType = cols >= 110
	local fixed = (if showStatus then STATUS_WIDTH else 0)
		+ (if showLevel then LEVEL_WIDTH else 0)
		+ (if showType then TYPE_WIDTH else 0)
	local idWidth = math.clamp(avail - fixed - 2, MIN_ID, ID_WIDTH)
	local spans: { Span } = {
		ui.span(if selected then "› " else "  ", "accent"),
		ui.span(pad(d.scriptId, idWidth) .. "  ", if selected then "strong" else nil),
	}
	if showStatus then
		table.insert(spans, ui.span(pad(statusText(d), STATUS_WIDTH - 1) .. " ", M.statusTone(d)))
	end
	if showLevel then
		table.insert(
			spans,
			ui.span(pad(if d.logLevel ~= "" then d.logLevel else "?", LEVEL_WIDTH - 1) .. " ", levelTone(d.logLevel))
		)
	end
	if showType then
		table.insert(spans, ui.span(pad(Query.typeLabel(d.scriptType), TYPE_WIDTH - 1) .. " ", "muted"))
	end
	local room = avail - idWidth - 2 - fixed
	local act = activitySpans(s, d)
	local actWidth = 0
	for _, a in act do
		actWidth += width(a.t)
	end
	local local_ = s.scan == "done" and s.owners[d.key] ~= nil
	local localWidth = if local_ then 7 else 0
	if actWidth + localWidth > room then
		act, actWidth = {}, 0
	end
	if localWidth > room then
		local_, localWidth = false, 0
	end
	local titleRoom = room - actWidth - localWidth
	if titleRoom >= 6 and d.title ~= "" then
		table.insert(spans, ui.span(pad(d.title, titleRoom), nil))
	end
	for _, a in act do
		table.insert(spans, a)
	end
	if local_ then
		table.insert(spans, ui.span("  local", "accent"))
	end
	return ui.text(spans, { key = "r-" .. d.key, actions = { click = "sel=" .. d.key } })
end

local function countsLine(s: State, shown: number): Node
	local parts: { string } = {}
	local total = #s.rows
	table.insert(
		parts,
		if shown == total
			then string.format("%d deployments", total)
			else string.format("%d of %d deployments", shown, total)
	)
	if s.truncated then
		table.insert(parts, string.format("only the first %d", Query.MAX_ROWS))
	end
	if s.loadedAt then
		table.insert(parts, "loaded " .. s.loadedAt)
	end
	if s.activityErr then
		table.insert(parts, "24 h activity unavailable (" .. (s.activityErr :: Errors.NsError).message .. ")")
	elseif s.activityReq then
		table.insert(parts, "counting 24 h activity…")
	end
	if s.scan == "scanning" then
		table.insert(parts, "scanning local projects…")
	elseif s.scan == "done" and #s.scanErrors > 0 then
		table.insert(parts, string.format("%d local projects could not be scanned", #s.scanErrors))
	end
	return ui.muted(table.concat(parts, " · "), { key = "counts" })
end

local function rows(s: State): { Node }
	local list = State.visible(s)
	local out: { Node } = { countsLine(s, #list) }
	if #list == 0 then
		local text = if #s.rows > 0
			then "No deployments match the filters."
			elseif s.inflight then "Loading script deployments…"
			elseif s.err then "No rows yet."
			else "The account has no script deployments."
		table.insert(out, ui.muted(text, { key = "empty" }))
		return out
	end
	local sel = State.selectedIndex(s, list)
	local first, last = State.window(sel, #list, s.offset, State.MAX_RENDER_ROWS)
	if first > 1 then
		table.insert(
			out,
			ui.muted(string.format("↑ %d more (k, g)", first - 1), { key = "above", actions = { click = "page=up" } })
		)
	end
	local lines: { Node } = table.create(last - first + 1)
	for i = first, last do
		table.insert(lines, rowNode(s, list[i], i == sel))
	end
	table.insert(out, ui.scroll("rows", lines, "r-" .. list[sel].key, State.MAX_RENDER_ROWS))
	if last < #list then
		table.insert(
			out,
			ui.muted(
				string.format("↓ %d more (j, G)", #list - last),
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
			text = s.filter.text,
			cursor = #s.filter.text,
			placeholder = "press / to filter: deployment, title, script, record type",
			prompt = "/",
		},
	}
end

-- Dock: the selected deployment ---------------------------------------------------

local function detail(s: State, d: Deployment): Node
	local scriptLine: { ui.SpanLike } = { ui.span(d.script or "?", "strong") }
	if d.scriptName then
		table.insert(scriptLine, "  " .. d.scriptName)
	end
	if d.scriptInternalId then
		table.insert(scriptLine, ui.span(string.format("  #%d", d.scriptInternalId :: number), "muted"))
	end
	local status: { ui.SpanLike } = { ui.span(d.status ~= "" and d.status or "?", M.statusTone(d)) }
	if d.deployed == false then
		table.insert(status, ui.span("  not deployed", "warning"))
	end
	local items: { { { ui.SpanLike } } } = {
		{
			{ "Deployment" },
			{
				ui.span(d.scriptId, "strong"),
				ui.span(if d.id then string.format("  #%d", d.id :: number) else "", "muted"),
			},
		},
		{ { "Title" }, { d.title } },
		{ { "Script" }, scriptLine },
		{ { "Type" }, { Query.typeLabel(d.scriptType) } },
		{ { "Status" }, status },
		{ { "Log level" }, { ui.span(d.logLevel ~= "" and d.logLevel or "?", levelTone(d.logLevel)) } },
	}
	if d.recordType then
		table.insert(items, { { "Record type" }, { d.recordType :: string } })
	end
	local a = State.activityOf(s, d)
	if a then
		local spans: { ui.SpanLike } = {
			ui.span(string.format("%d log lines", a.total)),
			ui.span(string.format(" · %d errors", a.errors), if a.errors > 0 then "error" else "muted"),
			ui.span("  (all deployments of the script)", "muted"),
		}
		table.insert(items, { { "Last 24 h" } :: { ui.SpanLike }, spans })
	end
	local owner, why = State.owner(s, d)
	local where: { ui.SpanLike } = if owner
		then {
			ui.span(owner.name, "strong"),
			ui.span(string.format("  %s:%d", owner.rel, owner.line), "mono"),
		}
		else { ui.span(why or "none", "muted") }
	table.insert(items, { { "Local project" } :: { ui.SpanLike }, where })
	local actions: { Node } = {}
	if State.deploymentPage(s, d) then
		table.insert(actions, chip("Open in NetSuite (o)", "accent", "open", "open=deployment"))
	end
	if State.scriptPage(s, d) then
		table.insert(actions, chip("Script page (O)", "neutral", "script", "open=script"))
	end
	table.insert(actions, chip("Tail logs (L)", "neutral", "logs", "logs"))
	if owner then
		table.insert(actions, chip("Edit in project (e)", "neutral", "edit", "edit"))
	end
	return ui.col({ ui.kv(items), ui.row(actions, { key = "dact", wrap = true }) }, { key = "detail" })
end

-- Dock: the edit ----------------------------------------------------------------

local function editHead(s: State, e: State.Edit): Node
	local tg = State.target(s)
	local spans: { ui.SpanLike } = {
		ui.span("Edit ", "strong"),
		ui.span(e.deployment, "strong mono"),
		ui.span(" in ", "strong"),
		ui.span(e.owner.name .. "/" .. e.owner.rel, "mono"),
	}
	local row: { Node } = {}
	if tg and tg.production then
		table.insert(row, ui.badge("PRODUCTION", "error", { key = "badge" }))
	end
	table.insert(row, ui.text(spans, { key = "title" }))
	return ui.row(row, { key = "ehead", wrap = true })
end

local function fieldChips(e: State.Edit): Node
	local out: { Node } = {}
	for _, f in Values.FIELDS do
		local current = if e.target then e.target.values[f] else nil
		table.insert(
			out,
			chip(
				Values.LABELS[f] .. ": " .. (current or "absent"),
				if e.field == f then "accent" else "neutral",
				"field-" .. f,
				"field=" .. f
			)
		)
	end
	return ui.row(out, { key = "fields", wrap = true })
end

local function valueChips(e: State.Edit): Node
	local out: { Node } = {}
	local current = if e.target then e.target.values[e.field] else nil
	for i, v in State.choices(e) do
		local label = if v == current then v .. " (current)" else v
		table.insert(out, chip(label, if i == e.index then "accent" else "neutral", "v-" .. v, "value=" .. v))
	end
	return ui.row(out, { key = "values", wrap = true })
end

local function diffNode(e: State.Edit): Node?
	local plan = e.plan
	if plan == nil then
		return nil
	end
	local text = string.format("%s:%d\n-%s\n+%s", e.owner.rel, plan.line, plan.before, plan.after)
	return ui.code(text, "diff", nil, { key = "diff" })
end

local function editDock(s: State, e: State.Edit): Node
	local body: { Node } = { editHead(s, e) }
	if e.warning then
		table.insert(body, ui.text({ ui.span("⚠ ", "warning"), ui.span(e.warning :: string) }, { key = "warn" }))
	end
	local phase = e.phase
	if phase == "reading" then
		table.insert(body, ui.muted("Reading " .. e.owner.rel .. " …", { key = "reading" }))
	elseif phase == "choose" then
		table.insert(body, fieldChips(e))
		table.insert(body, valueChips(e))
		if e.message then
			table.insert(body, ui.text({ ui.span(e.message :: string, "warning") }, { key = "msg" }))
		end
		table.insert(body, ui.muted("tab field · ←/→ value · enter preview · esc cancel", { key = "ehint" }))
	elseif phase == "preview" or phase == "writing" then
		local plan = e.plan :: any
		local d = diffNode(e)
		if d then
			table.insert(body, d)
		end
		table.insert(
			body,
			ui.text({
				ui.span("Writes the local file only. ", "strong"),
				ui.span(
					string.format(
						"NetSuite keeps %s %s until the project is deployed.",
						Values.LABELS[e.field],
						if plan then plan.old else "?"
					),
					"muted"
				),
			}, { key = "scope" })
		)
		if phase == "writing" then
			table.insert(body, ui.muted("Writing …", { key = "writing" }))
		else
			table.insert(
				body,
				ui.row({
					chip("Write file (enter)", "accent", "write", "write"),
					chip("Back (esc)", "neutral", "back", "back"),
				}, { key = "eact" })
			)
		end
	elseif phase == "done" then
		local plan = e.plan :: any
		table.insert(
			body,
			ui.text({
				ui.span("Wrote ", "success"),
				ui.span(string.format("%s:%d", e.owner.rel, if plan then plan.line else 0), "mono"),
				ui.span(
					if plan
						then string.format(": %s %s → %s.", Values.LABELS[plan.field], plan.old, plan.new)
						else ".",
					nil
				),
			}, { key = "done" })
		)
		if e.command then
			table.insert(
				body,
				ui.text({ ui.span("Deploy it (the guard checks the target account):", "muted") }, { key = "dhint" })
			)
			table.insert(body, ui.code(e.command :: string, "sh", nil, { key = "cmd" }))
			table.insert(
				body,
				ui.row({
					chip("Copy deploy command (y)", "accent", "copy", "copy"),
					chip("Close (esc)", "neutral", "cancel", "cancel"),
				}, { key = "eact" })
			)
		else
			table.insert(
				body,
				ui.text({ ui.span(e.commandWhy or "Deploy the project by hand.", "warning") }, { key = "nocmd" })
			)
		end
	else
		table.insert(body, ui.text({ ui.span(e.message or "The edit failed.", "error") }, { key = "emsg" }))
		table.insert(body, ui.muted("r reads the file again · esc closes", { key = "ehint" }))
	end
	return ui.col(body, { key = "edit" })
end

local function dock(s: State): Node?
	local e = s.edit
	if e then
		return editDock(s, e)
	end
	if not s.detailOpen then
		return nil
	end
	local d = State.selected(s)
	return if d then detail(s, d) else nil
end

local HINT =
	"j/k move · enter detail · / filter · t s l type/status/level · x clear · o open · L logs · e edit · c connection · r reload · esc close"
local HELD_HINT = "enter starts · esc closes"

local function heldView(s: State): { main: Node, dock: Node? }
	local tg = State.target(s)
	local conn: { Node } = {
		ui.text({ ui.span("Connection  ", "muted") }),
		ui.badge(
			if tg then tg.id .. " · " .. tg.account_label else "none",
			if tg and tg.production then "error" else "accent"
		),
	}
	if tg and tg.production then
		table.insert(conn, ui.badge("PROD", "error"))
	end
	local body: { Node } = {
		ui.row(conn, { key = "hconn" }),
		ui.text({ ui.span("Filter      ", "muted"), ui.span(if s.filter.text ~= "" then s.filter.text else "none") }, {
			key = "hfilter",
		}),
		ui.text({
			ui.span("Opened from a link: nothing is queried until you press Enter.", "muted"),
		}, { key = "hwhy" }),
		ui.row({
			chip("Enter starts", "accent", "start", "start"),
			chip("Close", "neutral", "close", "close"),
		}, { key = "hact" }),
	}
	local children: { Node } = {
		ui.card({ ui.span("List script deployments?", "strong") }, body, { key = "held" }),
	}
	if s.notice then
		table.insert(children, ui.text({ ui.span(s.notice :: string, "warning") }, { key = "notice" }))
	end
	table.insert(children, ui.muted(HELD_HINT, { key = "keys" }))
	return { main = ui.col(children), dock = nil }
end

function M.view(s: State): { main: Node, dock: Node? }
	if #s.targets == 0 then
		return {
			main = ui.col({
				ui.card({ "NetSuite script deployments" }, {
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
	if s.held then
		return heldView(s)
	end
	local children: { Node } = { header(s) }
	if s.err then
		table.insert(children, errorCard(s, s.err :: Errors.NsError))
	end
	if s.notice then
		table.insert(children, ui.text({ ui.span(s.notice :: string, "warning") }, { key = "notice" }))
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
	local base = if tg then "NetSuite deployments · " .. tg.id else "NetSuite deployments"
	return if s.held then base .. " (press Enter)" else base
end

return M
