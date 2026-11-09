--!strict
-- The drift block's view: the project and target account (red PROD badge
-- for production, a warning badge while the account is unknown, which
-- counts as production), the run's progress or the result's time, tabs and
-- status filters, a window of the rows around the selection (ui.scroll,
-- at most MAX_ROWS), a detail view with the unified diff of the selected
-- entry and the target picker. Pure: `{k, p, c}` nodes from lib/ui.

local Compare = require("./compare")
local Resolve = require("../account/resolve")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type State = State.State
type Entry = Compare.Entry

local M = {}

-- Tern virtualizes a list past 200 children and then renders only `item`
-- props, so the rows stay at or under 200.
M.MAX_ROWS = 200

local LABEL: { [string]: string } = {
	identical = "same",
	changed = "changed",
	missing = "missing",
	account = "account",
	error = "error",
	pending = "pending",
}

local TONE: { [string]: string } = {
	identical = "muted",
	changed = "warning",
	missing = "error",
	account = "info",
	error = "error",
	pending = "muted",
}

local FILTER_TITLE: { [string]: string } = {
	all = "Everything compared",
	changed = "Different in the account",
	missing = "In the project, not in the account",
	account = "In the account under the project's script id prefixes, not in the project (o)",
	error = "Could not be compared",
	identical = "Same in both (formatting aside)",
	pending = "Not compared yet",
}

function M.age(seconds: number): string
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return string.format("%d min ago", seconds // 60)
	elseif seconds < 86400 then
		return string.format("%d h ago", seconds // 3600)
	end
	return string.format("%d d ago", seconds // 86400)
end

local function targetBadge(t: Resolve.Resolution, key: string, action: string?): Node
	local props: { [string]: any } = { key = key }
	if action then
		props.actions = { click = action }
	end
	if t.source == "unknown" then
		props.title = t.problem or "Account not resolved yet; an unknown account counts as production"
		return ui.badge(t.authId .. "?", "warning", props)
	elseif t.production then
		props.title = "Production account: drift only reads it"
		return ui.badge(if t.label == "PROD" then "PROD" else "PROD " .. t.label, "error", props)
	end
	props.title = "Target account (p picks another)"
	return ui.badge(t.label, "muted", props)
end

local function chip(text: string, action: string, on: boolean, key: string, title: string?): Node
	return ui.badge(text, if on then "info" else "neutral", { key = key, title = title, actions = { click = action } })
end

local function runLine(s: State): Node?
	local r = s.run
	if r and (r.status == "preparing" or r.status == "running") then
		local spans: { ui.SpanLike } = {
			ui.span(string.format("comparing %d/%d", r.done, r.total), "info strong"),
		}
		if r.doing then
			table.insert(spans, ui.span("  " .. r.doing, "muted"))
		end
		table.insert(spans, ui.span("  c cancels", "muted"))
		return ui.text(spans, { key = "progress" })
	end
	if r and r.status == "failed" then
		return ui.text({ ui.span("Run stopped: ", "error strong"), r.error or "?" }, { key = "progress" })
	end
	if r and r.status == "cancelled" then
		return ui.text(
			{ ui.span(string.format("Cancelled after %d of %d; press r to run again", r.done, r.total), "warning") },
			{ key = "progress" }
		)
	end
	local result = s.result
	if result and result.at > 0 then
		local when = os.date("%Y-%m-%d %H:%M", result.at) :: string
		local spans: { ui.SpanLike } = {
			ui.span(string.format("compared %s (%s)", M.age(math.max(s.clock - result.at, 0)), when), "muted"),
		}
		if s.cached then
			table.insert(spans, ui.span("  cached; r runs again", "muted"))
		end
		return ui.text(spans, { key = "progress" })
	end
	return nil
end

local function header(s: State): Node
	local project = s.project
	local nodes: { Node } = {
		ui.text({ ui.span(if project then project.name else "NetSuite drift", "strong") }, { key = "project" }),
	}
	if s.authId == nil then
		if s.phase == "ready" then
			table.insert(
				nodes,
				ui.badge(
					"no auth ID",
					"warning",
					{ key = "target", title = "project.json has no defaultAuthId; p picks one" }
				)
			)
		end
	elseif s.target then
		local t = s.target :: Resolve.Resolution
		table.insert(nodes, ui.text({ ui.span("vs", "muted") }, { key = "vs" }))
		table.insert(nodes, targetBadge(t, "target", "picker"))
		local detail = t.authId .. (if t.accountId then " → " .. t.accountId else "")
		table.insert(nodes, ui.text({ ui.span(detail, "muted") }, { key = "auth" }))
	end
	if s.phase == "scanning" then
		table.insert(nodes, ui.text({ ui.span("reading the project…", "muted") }, { key = "scanning" }))
	end
	return ui.row(nodes, { key = "head", wrap = true })
end

local function problems(s: State): { Node }
	local out: { Node } = {}
	local r = s.result
	if r then
		for i, p in r.problems do
			table.insert(out, ui.text({ ui.span(p, "warning") }, { key = "problem" .. i }))
		end
	end
	return out
end

local function filters(s: State): { Node }
	local objects, files = State.entries(s, "object"), State.entries(s, "file")
	local tabs = ui.row({
		chip("Objects " .. #objects, "kind=object", s.kind == "object", "k-object"),
		chip("Files " .. #files, "kind=file", s.kind == "file", "k-file"),
		chip(
			if s.accountOnly then "account-only: on" else "account-only: off",
			"accountonly",
			s.accountOnly,
			"k-account",
			"o: also list account objects under the project's script id prefixes"
		),
	}, { key = "kinds", wrap = true })
	local c = State.counts(State.entries(s, s.kind))
	local chips: { Node } = {}
	for _, f in State.FILTERS do
		local n = c[f] or 0
		if f == "all" or n > 0 or s.filter == f then
			local text = if f == "all" then "all " .. n else n .. " " .. (LABEL[f] or f)
			table.insert(chips, chip(text, "filter=" .. f, s.filter == f, "f-" .. f, FILTER_TITLE[f]))
		end
	end
	return { tabs, ui.row(chips, { key = "filters", wrap = true }) }
end

local function rowKey(e: Entry): string
	return "r:" .. e.kind .. ":" .. e.id
end

local function statusText(s: State, e: Entry): string
	if e.status == "pending" and not State.busy(s) then
		return "not compared"
	end
	return LABEL[e.status] or e.status
end

local function rowNode(s: State, e: Entry, i: number, selected: boolean): Node
	local spans: { ui.SpanLike } = {
		ui.span(if selected then "▸ " else "  ", "strong"),
		ui.span(string.format("%-8s", statusText(s, e)), TONE[e.status]),
		" ",
	}
	if e.type then
		table.insert(spans, ui.span(e.type .. " ", "muted"))
	end
	table.insert(spans, ui.span(e.id, if selected then "code strong" else "code"))
	if e.note then
		table.insert(spans, ui.span("  " .. e.note, "muted"))
	end
	-- A click selects; a click on the selected row opens its detail.
	return ui.text(spans, { key = rowKey(e), actions = { click = (if selected then "open=" else "sel=") .. i } })
end

local function listNodes(s: State): { Node }
	local out: { Node } = {}
	local all = State.entries(s, s.kind)
	local visible = State.visible(s)
	if #visible == 0 then
		local why: string
		if s.result == nil then
			why = if State.busy(s) then "Preparing…" else "Nothing compared yet."
		elseif #all == 0 then
			why = if s.kind == "file" then "The project has no File Cabinet files." else "The project has no objects."
		else
			why = "Nothing matches the filter."
		end
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
		table.insert(rows, rowNode(s, visible[i], i, i == sel))
	end
	table.insert(out, ui.scroll("rows", rows, rowKey(visible[sel]), size))
	if last < #visible then
		table.insert(out, ui.muted(string.format("↓ %d below", #visible - last), { key = "below" }))
	end
	return out
end

local function detailNodes(s: State): { Node }
	local e = State.selectedEntry(s)
	if e == nil then
		return { ui.muted("Nothing selected.", { key = "empty" }) }
	end
	local out: { Node } = {
		ui.row({
			ui.badge(statusText(s, e), TONE[e.status] or "muted", { key = "status" }),
			ui.text({ ui.span(e.id, "code strong") }, { key = "id" }),
			ui.text({ ui.span(e.localPath or "", "muted") }, { key = "path" }),
		}, { key = "detail-head", wrap = true }),
	}
	if e.note then
		table.insert(out, ui.text({ ui.span(e.note, "muted") }, { key = "note" }))
	end
	if e.diff and e.diff ~= "" then
		table.insert(
			out,
			{ k = "diff", p = { key = "diff", text = e.diff, path = e.localPath or e.id, mode = "unified" } }
		)
		if e.truncated then
			table.insert(out, ui.muted("… diff cut at " .. (Compare.DIFF_BYTES // 1024) .. " KiB", { key = "cut" }))
		end
	end
	return out
end

local function pickNodes(s: State): { Node }
	local out: { Node } = {
		ui.text(
			{ ui.span("Compare with", "strong"), ui.span("  (Enter picks, Esc goes back)", "muted") },
			{ key = "pick-head" }
		),
	}
	local p = s.picker
	if p and p.loading then
		table.insert(
			out,
			ui.muted("Asking the CLI for its auth IDs (account:manageauth --list)…", { key = "pick-loading" })
		)
	end
	if p and p.error then
		table.insert(
			out,
			ui.text({ ui.span("account:manageauth --list failed: ", "error"), p.error }, { key = "pick-error" })
		)
	end
	local choices = State.choices(s)
	local sel = if p then p.selected else 1
	local rows: { Node } = {}
	for i, c in choices do
		local selected = i == sel
		local spans: { ui.SpanLike } = {
			ui.span(if selected then "▸ " else "  ", "strong"),
			ui.span(c.authId, if selected then "code strong" else "code"),
			"  ",
		}
		local row = ui.row({
			ui.text(spans, { key = "name" }),
			targetBadge(c.target, "badge", nil),
			ui.text({
				ui.span(
					(c.target.accountId or "")
						.. (if c.source == "project"
							then "  project.json"
							elseif c.source == "config" then "  config"
							else "  CLI")
						.. (if c.detail then "  " .. c.detail else "")
						.. (if c.authId == s.authId then "  (current)" else ""),
					"muted"
				),
			}, { key = "detail" }),
		}, { key = "c:" .. c.authId, actions = { click = "pick=" .. i } })
		table.insert(rows, row)
	end
	if #choices > 0 then
		table.insert(out, ui.scroll("choices", rows, "c:" .. choices[math.clamp(sel, 1, #choices)].authId, M.MAX_ROWS))
	end
	return out
end

local function heldNodes(s: State): { Node }
	local why = if s.heldFor == "target"
		then "A production account is picked: nothing has run against it yet (drift only reads it)."
		else "Opened from a link: nothing has run yet."
	return {
		ui.text({ ui.span(why, "warning strong") }, { key = "held" }),
		ui.text({
			ui.span("Press Enter", "strong"),
			ui.span(
				" to import the account's copies of this project's objects and files into a scratch project with the SuiteCloud CLI (it loads "
					.. (s.root or "?")
					.. "/suitecloud.config.js) and compare them, or q to close.",
				"muted"
			),
		}, { key = "held-how" }),
	}
end

local function keySpans(s: State): { ui.SpanLike }
	if s.view == "pick" then
		return { ui.span("enter", "key"), " pick  ", ui.span("esc", "key"), " back" }
	elseif s.view == "diff" then
		return {
			ui.span("n", "key"),
			"/",
			ui.span("N", "key"),
			" next/previous change  ",
			ui.span("j", "key"),
			"/",
			ui.span("k", "key"),
			" entries  ",
			ui.span("esc", "key"),
			" back",
		}
	elseif s.held then
		return { ui.span("enter", "key"), " compare  ", ui.span("p", "key"), " target  ", ui.span("q", "key"), " close" }
	end
	local keys: { ui.SpanLike } = {
		ui.span("enter", "key"),
		" diff  ",
		ui.span("n", "key"),
		" next change  ",
		ui.span("tab", "key"),
		" objects/files  ",
		ui.span("s", "key"),
		" status  ",
		ui.span("o", "key"),
		" account-only  ",
		ui.span("p", "key"),
		" target  ",
		ui.span("e", "key"),
		" open  ",
	}
	if State.busy(s) then
		table.insert(keys, ui.span("c", "key"))
		table.insert(keys, " cancel  ")
	else
		table.insert(keys, ui.span("r", "key"))
		table.insert(keys, " run  ")
	end
	table.insert(keys, ui.span("q", "key"))
	table.insert(keys, " close")
	return keys
end

local function dock(s: State): Node
	local children: { Node } = {}
	local m = s.message
	if m then
		table.insert(children, ui.text({ ui.span(m.text, m.tone) }, { key = "message" }))
	end
	table.insert(children, ui.text(keySpans(s), { key = "keys" }))
	return ui.col(children, { key = "dock" })
end

function M.view(s: State): { main: Node, dock: Node }
	local children: { Node } = { header(s) }
	local progress = runLine(s)
	if s.phase == "noproject" then
		table.insert(
			children,
			ui.text({
				ui.span(s.scanError or ((s.cwd or "this pane") .. " is not inside an SDF project"), "warning"),
				ui.span(" (no suitecloud.config.js in it or its parents)", "muted"),
			}, { key = "noproject" })
		)
	elseif s.project == nil then
		table.insert(children, ui.muted("Reading the project…", { key = "reading" }))
	elseif s.view == "pick" then
		for _, n in pickNodes(s) do
			table.insert(children, n)
		end
	elseif s.authId == nil then
		table.insert(
			children,
			ui.text({
				ui.span("project.json has no defaultAuthId", "warning strong"),
				ui.span(" — press p to pick an auth ID to compare with.", "muted"),
			}, { key = "noauth" })
		)
	else
		if progress then
			table.insert(children, progress)
		end
		for _, n in problems(s) do
			table.insert(children, n)
		end
		if s.held and s.result == nil then
			for _, n in heldNodes(s) do
				table.insert(children, n)
			end
		elseif s.view == "diff" then
			for _, n in detailNodes(s) do
				table.insert(children, n)
			end
		else
			if s.held then
				for _, n in heldNodes(s) do
					table.insert(children, n)
				end
			end
			for _, n in filters(s) do
				table.insert(children, n)
			end
			for _, n in listNodes(s) do
				table.insert(children, n)
			end
		end
	end
	return {
		main = ui.col(children, { key = "drift", role = "tern-netsuite.drift" }),
		dock = dock(s),
	}
end

function M.title(s: State): string
	local project = s.project
	local t = s.target
	local target = if t == nil then "" elseif t.production then " vs PROD" else " vs " .. t.label
	return "NetSuite Drift" .. (if project then " · " .. project.name .. target else "")
end

return table.freeze(M)
