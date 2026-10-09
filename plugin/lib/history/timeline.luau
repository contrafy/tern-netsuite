--!strict
-- One newest-first timeline of local deploys (history.jsonl), guard
-- decisions (audit.log) and CI runs (gh). A guard decision made while a
-- recorded deploy ran in the same directory is that deploy's decision and
-- is folded into it; only decisions without a recorded command line (another
-- terminal, a wrapper outside Tern) get their own row.

local Ci = require("./ci")
local GuardLog = require("./guardlog")
local Record = require("./record")

export type Source = "local" | "guard" | "ci"

export type Account = { label: string, production: boolean? }

export type Item = {
	-- Stable across reloads; selection and click actions use it.
	key: string,
	source: Source,
	-- Unix seconds: finish (local), decision (guard), creation (CI).
	at: number,
	status: string,
	tone: string,
	project: string?,
	account: Account?,
	command: string?,
	line: string?,
	cwd: string?,
	log: string?,
	branch: string?,
	head: string?,
	dirty: boolean?,
	tookMs: number?,
	exit: number?,
	authId: string?,
	guard: GuardLog.Decision?,
	reason: string?,
	url: string?,
	runId: number?,
	repo: string?,
	title: string?,
	event: string?,
}

export type Filters = { project: string?, account: string?, source: string? }

export type Input = {
	records: { Record.Record },
	guards: { GuardLog.Entry },
	runs: { Ci.Run },
	-- owner/repo the runs belong to.
	repo: string?,
}

export type Day = { day: string, items: { Item } }

local M = {}

-- Seconds a guard decision may fall outside its command's run.
M.SLACK = 5

local function hash(s: string): string
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return string.format("%08x", h)
end

local function basename(path: string?): string?
	return if path then string.match(path, "([^/]+)/*$") else nil
end

-- macOS: /tmp and /var are links into /private, and the guard records the
-- physical directory.
local function sameDir(a: string?, b: string?): boolean
	if a == nil or b == nil then
		return false
	end
	local function norm(p: string): string
		p = string.gsub(p, "/+$", "")
		return (string.gsub(p, "^/private/(%a+)", "/%1"))
	end
	return norm(a) == norm(b)
end

local function localStatus(r: Record.Record, guard: GuardLog.Decision?): (string, string)
	if guard == "denied" then
		return "denied", "warning"
	elseif guard == "cancelled" then
		return "cancelled", "muted"
	elseif r.status == 0 then
		return "ok", "success"
	elseif r.status == 130 then
		return "interrupted", "warning"
	end
	return "failed", "error"
end

local GUARD_TONE: { [string]: string } = { approved = "info", denied = "warning", cancelled = "muted" }

local CI_TONE: { [string]: string } = {
	running = "info",
	ok = "success",
	failed = "error",
	cancelled = "muted",
	skipped = "muted",
}

local function localItem(r: Record.Record, g: GuardLog.Entry?): Item
	local status, tone = localStatus(r, if g then g.decision else nil)
	local account: Account? = nil
	if r.authId then
		local label = r.accountLabel or r.accountId or (r.authId .. "?")
		account = { label = label, production = r.production }
	end
	return {
		key = "l" .. r.at .. "-" .. hash(r.cwd .. "\0" .. r.line),
		source = "local",
		at = r.at,
		status = status,
		tone = tone,
		project = r.project,
		account = account,
		command = r.command,
		line = r.line,
		cwd = r.cwd,
		log = r.log,
		branch = r.branch,
		head = r.head,
		dirty = r.dirty,
		tookMs = r.tookMs,
		exit = r.status,
		authId = r.authId,
		guard = if g then g.decision else nil,
		reason = if g then g.reason else nil,
	}
end

local function guardItem(g: GuardLog.Entry): Item
	return {
		key = "g" .. g.at .. "-" .. hash((g.cwd or "") .. "\0" .. g.line),
		source = "guard",
		at = g.at,
		status = g.decision,
		tone = GUARD_TONE[g.decision],
		project = basename(g.cwd),
		account = { label = g.accountLabel or g.accountId or "unknown", production = g.production },
		command = g.command,
		line = g.line,
		cwd = g.cwd,
		branch = g.branch,
		head = g.head,
		dirty = g.dirty,
		authId = g.authId,
		guard = g.decision,
		reason = g.reason,
	}
end

local function ciItem(r: Ci.Run, repo: string?): Item
	local state = Ci.state(r)
	local took: number? = nil
	if r.status == "completed" and r.created and r.updated then
		took = (r.updated - r.created) * 1000
	end
	return {
		key = "c" .. r.id,
		source = "ci",
		at = r.created or 0,
		status = state,
		tone = CI_TONE[state],
		branch = r.branch,
		head = r.sha,
		tookMs = took,
		url = r.url,
		runId = r.id,
		repo = repo,
		title = r.title,
		event = r.event,
	}
end

local function matchGuard(r: Record.Record, guards: { GuardLog.Entry }, used: { [number]: boolean }): number?
	local best: number? = nil
	local bestGap = math.huge
	for i, g in guards do
		if
			not used[i]
			and g.command == r.command
			and sameDir(g.cwd, r.cwd)
			and g.at >= r.startedAt - M.SLACK
			and g.at <= r.at + M.SLACK
		then
			local gap = math.abs(r.at - g.at)
			if gap < bestGap then
				best, bestGap = i, gap
			end
		end
	end
	return best
end

function M.build(input: Input): { Item }
	local items: { Item } = {}
	local used: { [number]: boolean } = {}
	for _, r in input.records do
		local gi = matchGuard(r, input.guards, used)
		if gi then
			used[gi] = true
		end
		table.insert(items, localItem(r, if gi then input.guards[gi] else nil))
	end
	for i, g in input.guards do
		if not used[i] then
			table.insert(items, guardItem(g))
		end
	end
	for _, run in input.runs do
		table.insert(items, ciItem(run, input.repo))
	end
	table.sort(items, function(a: Item, b: Item): boolean
		if a.at ~= b.at then
			return a.at > b.at
		end
		return a.key > b.key
	end)
	return items
end

local function field(item: Item, name: string): string?
	if name == "account" then
		return if item.account then item.account.label else nil
	elseif name == "project" then
		return item.project
	elseif name == "source" then
		return item.source
	end
	return nil
end

function M.filter(items: { Item }, f: Filters): { Item }
	local out: { Item } = {}
	for _, item in items do
		if
			(f.project == nil or item.project == f.project)
			and (f.account == nil or (item.account ~= nil and item.account.label == f.account))
			and (f.source == nil or item.source == f.source)
		then
			table.insert(out, item)
		end
	end
	return out
end

-- Distinct values of `name` ("project", "account" or "source"), sorted.
function M.values(items: { Item }, name: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, item in items do
		local v = field(item, name)
		if v and not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	table.sort(out)
	return out
end

-- The value after `current` (nil = all), wrapping back to all.
function M.cycle(values: { string }, current: string?): string?
	if current == nil then
		return values[1]
	end
	local i = table.find(values, current)
	return if i then values[i + 1] else nil
end

function M.group(items: { Item }, dayOf: (number) -> string): { Day }
	local out: { Day } = {}
	local current: Day? = nil
	for _, item in items do
		local d = dayOf(item.at)
		if current == nil or current.day ~= d then
			local fresh: Day = { day = d, items = {} }
			table.insert(out, fresh)
			current = fresh
		end
		table.insert((current :: Day).items, item)
	end
	return out
end

return M
