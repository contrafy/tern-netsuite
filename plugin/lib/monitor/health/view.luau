--!strict
-- The `health` block: one card per configured connection, rendered from the
-- summaries the window's poller stores in tern.kv.

local Checks = require("./checks")
local Model = require("./model")
local ui = require("../../ui")

type Node = ui.Node

local M = {}

-- Deployments listed per connection before "… N more".
M.MAX_DEPLOYMENTS_SHOWN = 15

export type Entry = { id: string, label: string, summary: Model.Summary? }
export type Input = { entries: { Entry }, now: number }

local TONE: { [string]: string } = {
	ok = "success",
	warn = "warning",
	error = "error",
	failed = "error",
	pending = "pending",
	not_connected = "muted",
}

local STATE_TEXT: { [string]: string } = {
	ok = "ok",
	warn = "warning",
	error = "error",
	failed = "check failed",
	pending = "pending",
	not_connected = "not connected",
}

local function badge(state: string, key: string): Node
	return ui.badge(STATE_TEXT[state] or state, TONE[state] or "neutral", { key = key })
end

local function checkRow(c: Model.CheckRow, now: number, i: number): Node
	local tail: { ui.SpanLike } = {}
	if c.error then
		table.insert(tail, ui.span(c.error, "error"))
	elseif c.value then
		table.insert(tail, ui.span(c.value, "strong"))
	end
	if c.threshold then
		table.insert(tail, ui.span("  " .. c.threshold, "muted"))
	end
	table.insert(
		tail,
		ui.span(if c.at then "  ran " .. Checks.ageText(math.max(0, now - c.at)) else "  not run yet", "muted")
	)
	return ui.row({
		badge(c.state, "b"),
		ui.text({ ui.span(c.label) }),
		ui.text(tail),
	}, { key = "check" .. i })
end

local function spark(s: Model.Summary): Node?
	local series = s.spark
	if series == nil then
		return nil
	end
	local points = table.create(#series)
	for i, n in series do
		points[i] = { value = n, label = string.format("-%d h", #series - i) }
	end
	return ui.col({
		ui.muted(
			"Errors per hour, last 24 h" .. (if s.sparkEnd then " (server time, up to " .. s.sparkEnd .. ")" else ""),
			{ key = "sparkhead" }
		),
		{ k = "chart", p = { kind = "spark", series = points, key = "spark" } },
	}, { key = "sparkcol" })
end

local function deployments(s: Model.Summary): Node?
	local list = s.deployments
	if list == nil or #list == 0 then
		return nil
	end
	local lines: { Node } = {}
	for i, d in list do
		if i > M.MAX_DEPLOYMENTS_SHOWN then
			break
		end
		table.insert(
			lines,
			ui.text({
				ui.span(d.scriptid, "strong"),
				ui.span("  " .. d.title),
				ui.span(
					"  " .. string.lower(d.status) .. (if d.deployed then "" else ", not deployed"),
					if d.status == "TESTING" then "warning" else "muted"
				),
			}, { key = "d" .. i })
		)
	end
	local hidden = #list - math.min(#list, M.MAX_DEPLOYMENTS_SHOWN)
	if hidden > 0 or s.deploymentsMore then
		table.insert(
			lines,
			ui.muted(string.format("… %d%s more", hidden, if s.deploymentsMore then "+" else ""), { key = "more" })
		)
	end
	return ui.section({ "Deployments in testing or not deployed" }, lines, { key = "deps" })
end

local function lastError(s: Model.Summary): Node?
	local e = s.lastError
	if e == nil then
		return nil
	end
	local script = e.scriptName or e.script or "unknown script"
	if e.scriptName and e.script then
		script = e.scriptName .. " (" .. e.script .. ")"
	end
	local items: { { { ui.SpanLike } } } = {
		{ { "At" }, { e.at .. " (server time)" } },
		{ { "Script" }, { script } },
		{ { "Title" }, { e.title } },
	}
	local children: { Node } = { ui.kv(items) }
	if e.detail ~= "" then
		table.insert(children, ui.code(e.detail, nil, nil, { key = "detail" }))
	end
	return ui.section({ "Last error" }, children, { key = "lasterr" })
end

local function card(e: Entry, now: number, i: number): Node
	local s = e.summary
	local head: { ui.SpanLike } = { ui.span(e.label, "strong"), ui.span("  " .. e.id, "muted") }
	local body: { Node } = {}
	if s == nil then
		table.insert(
			body,
			ui.muted("waiting for the first poll (an open Tern window polls NetSuite; press r to poll now)")
		)
		return ui.card(head, body, { key = "conn" .. i })
	end
	table.insert(
		body,
		ui.row({
			badge(s.state, "state"),
			ui.muted(string.format("updated %s · every %d s", Checks.ageText(math.max(0, now - s.at)), s.poll)),
		}, { key = "head" })
	)
	if s.state == "not_connected" then
		table.insert(body, ui.text({ ui.span("not connected: ", "strong"), ui.span(s.message or "") }, { key = "nc" }))
		table.insert(
			body,
			ui.muted(
				"Store credentials with the palette command Tern NetSuite: Connect account, then press r.",
				{ key = "nchint" }
			)
		)
		return ui.card(head, body, { key = "conn" .. i })
	end
	local rows: { Node } = {}
	for j, c in s.checks do
		table.insert(rows, checkRow(c, now, j))
	end
	table.insert(body, ui.col(rows, { key = "checks" }))
	for _, build in { spark, deployments, lastError } do
		local n = build(s)
		if n then
			table.insert(body, n)
		end
	end
	return ui.card(head, body, { key = "conn" .. i })
end

function M.render(input: Input): { main: Node, dock: Node }
	local children: { Node } = {}
	if #input.entries == 0 then
		table.insert(
			children,
			ui.text({
				ui.span("No connections are configured. ", "strong"),
				ui.span("Add accounts[] and connections[] to the config (Tern NetSuite: Open config), then press r."),
			}, { key = "empty" })
		)
	end
	for i, e in input.entries do
		table.insert(children, card(e, input.now, i))
	end
	return {
		main = ui.col(children, { key = "main" }),
		dock = ui.col({ ui.muted("r refresh now · esc close", { key = "keys" }) }),
	}
end

local RANK: { [string]: number } = { ok = 0, not_connected = 1, pending = 2, warn = 3, failed = 4, error = 5 }

function M.title(entries: { Entry }): string
	local worst: string? = nil
	for _, e in entries do
		local st = if e.summary then e.summary.state else "pending"
		if worst == nil or RANK[st] > RANK[worst :: string] then
			worst = st
		end
	end
	return if worst then "NetSuite health: " .. (STATE_TEXT[worst :: string] or worst :: string) else "NetSuite health"
end

return M
