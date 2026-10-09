--!strict
-- State and view of the `connect` block: pick a configured connection, type
-- or paste its credentials, save them to the keychain (through the window
-- half) and test the connection. Typed values exist only in this state; the
-- view shows their length, never their text, and `saved` keeps only the
-- selected connection id.

local Classify = require("../account/classify")
local Config = require("../config")
local Credentials = require("./credentials")
local Errors = require("./errors")
local ui = require("../ui")

local M = {}

type Node = ui.Node
type NsError = Errors.NsError

export type Target = {
	id: string,
	auth: Config.Auth,
	transport: Config.Transport,
	read_only: boolean,
	account_id: string,
	account_label: string,
	production: boolean,
}

export type Phase = "edit" | "saving" | "testing"

export type Notice = { tone: "success" | "error" | "info", text: string, error: NsError? }

export type State = {
	targets: { Target },
	selected: number,
	field: number,
	values: { [string]: string },
	phase: Phase,
	notice: Notice?,
}

export type Effect = "save" | "test" | "forget" | "close"

M.TEST_SQL = "SELECT 1 AS ok FROM DUAL"

-- One target per configured connection whose account is configured.
function M.targets(cfg: Config.Config): { Target }
	local out: { Target } = {}
	for _, c in cfg.connections do
		for _, a in cfg.accounts do
			if a.id == c.account then
				local class = Classify.account(a.account_id, cfg)
				table.insert(out, {
					id = c.id,
					auth = c.auth,
					transport = c.transport,
					read_only = c.read_only,
					account_id = a.account_id,
					account_label = class.label,
					production = class.production,
				})
			end
		end
	end
	return out
end

function M.new(targets: { Target }, preselect: string?): State
	local selected = 1
	for i, tg in targets do
		if tg.id == preselect then
			selected = i
		end
	end
	return { targets = targets, selected = selected, field = 1, values = {}, phase = "edit", notice = nil }
end

function M.target(s: State): Target?
	return s.targets[s.selected]
end

local function fields(s: State): { Credentials.Field }
	local tg = M.target(s)
	return if tg then Credentials.FIELDS[tg.auth] else {}
end

local function with(s: State, changes: { [string]: any }): State
	local n = table.clone(s) :: any
	for k, v in changes do
		n[k] = v
	end
	return n
end

local function setValue(s: State, text: string): State
	local f = fields(s)[s.field]
	if f == nil then
		return s
	end
	local values = table.clone(s.values)
	values[f.id] = text
	return with(s, { values = values })
end

local function current(s: State): string
	local f = fields(s)[s.field]
	return if f then s.values[f.id] or "" else ""
end

local function typed(s: State, text: string): State
	local f = fields(s)[s.field]
	if f == nil then
		return s
	end
	local clean = string.gsub(text, "\r\n?", "\n")
	if not f.multiline then
		clean = string.gsub(clean, "%s", "")
	end
	return setValue(s, current(s) .. clean)
end

local function select(s: State, index: number): State
	if index == s.selected or s.targets[index] == nil then
		return s
	end
	local n = with(s, { selected = index, field = 1, values = {} })
	n.notice = nil
	return n
end

-- The next state and effect for a key press; `changed` false means the view
-- is unchanged (Tern then skips the render).
function M.key(s: State, key: { [string]: any }): (State, Effect?, boolean)
	local name = key.name
	if name == "escape" then
		return s, "close", false
	end
	if s.phase ~= "edit" then
		return s, nil, false
	end
	local n = #fields(s)
	if name == "tab" and not key.shift or name == "down" then
		return with(s, { field = math.min(s.field + 1, math.max(n, 1)) }), nil, true
	elseif name == "tab" and key.shift or name == "up" then
		return with(s, { field = math.max(s.field - 1, 1) }), nil, true
	elseif name == "enter" then
		if s.field < n then
			return with(s, { field = s.field + 1 }), nil, true
		end
		return s, "save", false
	elseif name == "backspace" then
		local v = current(s)
		if v == "" then
			return s, nil, false
		end
		return setValue(s, string.sub(v, 1, (utf8.offset(v, -1) or #v) - 1)), nil, true
	elseif name == "u" and key.ctrl then
		return setValue(s, ""), nil, true
	elseif name == "n" and key.ctrl then
		return select(s, s.selected % math.max(#s.targets, 1) + 1), nil, true
	elseif name == "p" and key.ctrl then
		return select(s, (s.selected - 2) % math.max(#s.targets, 1) + 1), nil, true
	elseif name == "paste" and type(key.text) == "string" then
		return typed(s, key.text), nil, true
	elseif type(key.text) == "string" and key.text ~= "" and not key.ctrl and not key.meta then
		return typed(s, key.text), nil, true
	end
	return s, nil, false
end

-- The next state and effect for a click (`act` and `value` of the event).
function M.event(s: State, act: string?, value: string?): (State, Effect?)
	local idle = s.phase == "edit"
	if act == "conn" and idle then
		for i, tg in s.targets do
			if tg.id == value then
				return select(s, i), nil
			end
		end
		return s, nil
	elseif act == "field" then
		local i = tonumber(value)
		if i and fields(s)[i] then
			return with(s, { field = i }), nil
		end
		return s, nil
	elseif (act == "save" or act == "test" or act == "forget") and idle then
		return s, act :: any
	elseif act == "close" then
		return s, "close"
	end
	return s, nil
end

-- The values to store, or nil and the reason.
function M.collect(s: State): ({ [string]: string }?, string?)
	local tg = M.target(s)
	if tg == nil then
		return nil, "no connection is configured"
	end
	local why = Credentials.unstorable(tg.id, tg.auth)
	if why then
		return nil, why
	end
	return Credentials.validate(tg.auth, s.values)
end

function M.busy(s: State, phase: Phase, text: string): State
	return with(s, { phase = phase, notice = { tone = "info", text = text } })
end

-- Back to editing with `notice`; typed values are dropped once stored.
function M.settle(s: State, notice: Notice, clearValues: boolean?): State
	return with(s, {
		phase = "edit",
		notice = notice,
		values = if clearValues then {} else s.values,
		field = if clearValues then 1 else s.field,
	})
end

function M.saved(s: State): any
	local tg = M.target(s)
	return if tg then { connection = tg.id } else nil
end

-- View -------------------------------------------------------------------------

local KIND_LABEL: { [string]: string } = {
	auth = "authentication",
	permission = "permission",
	query = "query",
	rate_limit = "rate limit",
	network = "network",
	server = "NetSuite server",
}

local function errorLines(e: NsError): { Node }
	local tail = {}
	if e.code then
		table.insert(tail, e.code)
	end
	if e.status then
		table.insert(tail, "HTTP " .. tostring(e.status))
	end
	local out: { Node } = {
		ui.row({
			ui.badge(KIND_LABEL[e.kind] or e.kind, "error"),
			ui.text({ ui.span(e.message) }),
		}, { key = "err" }),
	}
	if #tail > 0 then
		table.insert(out, ui.muted(table.concat(tail, " · "), { key = "errcode" }))
	end
	return out
end

local function targetRow(s: State): Node
	local chips: { Node } = {}
	for i, tg in s.targets do
		local label = tg.id .. " · " .. tg.account_label
		table.insert(
			chips,
			ui.badge(
				label,
				if i == s.selected then (if tg.production then "error" else "accent") else "neutral",
				{ key = "c" .. i, actions = { click = "conn=" .. tg.id } }
			)
		)
	end
	return ui.row(chips, { key = "targets", wrap = true })
end

local function fieldRows(s: State): { Node }
	local out: { Node } = {}
	for i, f in fields(s) do
		local value = s.values[f.id] or ""
		local focused = i == s.field and s.phase == "edit"
		local shown = Credentials.mask(value)
		table.insert(
			out,
			ui.row({
				ui.text({ ui.span(if focused then "›" else " ", "accent") }),
				ui.text(
					{ ui.span(f.label, if focused then "strong" else "muted") },
					{ actions = { click = "field=" .. i } }
				),
				ui.text({
					ui.span(
						if shown == "" then (if focused then "" else "empty") else shown,
						if shown == "" then "muted" else nil
					),
					ui.span(if focused then "▏" else "", "accent"),
				}),
			}, { key = "f" .. i })
		)
	end
	return out
end

function M.view(s: State): { main: Node }
	local tg = M.target(s)
	local body: { Node } = {}
	if tg == nil then
		table.insert(
			body,
			ui.text({
				ui.span("No connections are configured. ", "strong"),
				ui.span(
					"Add an account and a connection to connections[] in the config "
						.. "(Tern NetSuite: Open config; examples/config.json shows one).",
					"muted"
				),
			}, { key = "none" })
		)
		return { main = ui.col({ ui.card({ "Connect a NetSuite account" }, body, { key = "card" }) }) }
	end
	table.insert(body, targetRow(s))
	table.insert(
		body,
		ui.kv({
			{ { "Account" }, { tg.account_id .. (if tg.production then "  (production)" else "") } },
			{ { "Auth" }, { if tg.auth == "tba" then "token-based (OAuth 1.0a)" else "OAuth 2.0 client credentials" } },
			{ { "Transport" }, { tg.transport } },
			{ { "Queries" }, { if tg.read_only then "read-only (single SELECT / WITH)" else "any statement" } },
		})
	)
	local why = Credentials.unstorable(tg.id, tg.auth)
	if why then
		table.insert(body, ui.text({ ui.span(why, "error") }, { key = "unstorable" }))
	end
	table.insert(body, ui.rule({ "Credentials" }, { key = "credrule" }))
	for _, row in fieldRows(s) do
		table.insert(body, row)
	end
	table.insert(
		body,
		ui.muted(
			"Type or paste each value · Tab / Enter next field · Enter on the last field saves · Ctrl+U clears · "
				.. "Ctrl+N / Ctrl+P switch connection · Esc closes. Values go to the keychain; they are never shown, "
				.. "logged or saved with this block.",
			{ key = "hint" }
		)
	)
	local idle = s.phase == "edit"
	table.insert(
		body,
		ui.row({
			ui.badge(
				"Save & test",
				if idle then "accent" else "neutral",
				{ key = "save", actions = if idle then { click = "save" } else nil }
			),
			ui.badge(
				"Test connection",
				"neutral",
				{ key = "test", actions = if idle then { click = "test" } else nil }
			),
			ui.badge(
				"Forget credentials",
				"neutral",
				{ key = "forget", actions = if idle then { click = "forget" } else nil }
			),
		}, { key = "actions" })
	)
	local notice = s.notice
	if notice then
		if notice.error then
			table.insert(body, ui.text({ ui.span(notice.text, "strong") }, { key = "noticehead" }))
			for _, n in errorLines(notice.error) do
				table.insert(body, n)
			end
		else
			table.insert(
				body,
				ui.text(
					{ ui.span(notice.text, if notice.tone == "success" then "success" else "muted") },
					{ key = "notice" }
				)
			)
		end
	end
	return { main = ui.col({ ui.card({ "Connect a NetSuite account" }, body, { key = "card" }) }) }
end

function M.title(s: State): string
	local tg = M.target(s)
	return if tg then "NetSuite: connect " .. tg.id else "NetSuite: connect"
end

return M
