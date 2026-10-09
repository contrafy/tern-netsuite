--!strict
-- The history block: loads local deploys, guard decisions and (with
-- `history.ci`) the repository's CI runs, and handles keys and clicks. The
-- adapter runs the effects and feeds every answer back as a message; answers
-- to an older load (before `r`) are dropped by generation.

local Ci = require("./ci")
local Git = require("./git")
local GuardLog = require("./guardlog")
local Record = require("./record")
local Settings = require("./settings")
local Store = require("./store")
local Timeline = require("./timeline")

export type Load = "loading" | "ok" | "error" | "off"

export type State = {
	gen: number,
	cwd: string?,
	settings: Settings.Settings,
	decode: (string) -> any,
	records: { Record.Record },
	guards: { GuardLog.Entry },
	runs: { Ci.Run },
	localLoad: Load,
	guardLoad: Load,
	ciLoad: Load,
	localError: string?,
	ciError: string?,
	-- Why CI runs are not shown, when they are off.
	ciNote: string?,
	repo: string?,
	branch: string?,
	items: { Timeline.Item },
	filters: Timeline.Filters,
	sel: string?,
	detail: boolean,
}

export type EffectKind = "read_local" | "read_guard" | "git" | "ci" | "open" | "log" | "copy" | "exit"

export type Effect = {
	t: EffectKind,
	gen: number?,
	cwd: string?,
	argv: { string }?,
	timeoutMs: number?,
	-- open: an https URL or an absolute file path.
	url: string?,
	repo: string?,
	runId: number?,
	text: string?,
}

export type Msg = {
	t: string,
	gen: number?,
	text: string?,
	error: string?,
	stdout: string?,
	stderr: string?,
	status: number?,
	timedOut: boolean?,
	name: string?,
	act: string?,
	value: string?,
}

export type Init = { cwd: string?, settings: Settings.Settings, decode: (string) -> any }

local M = {}

-- Rows moved by pageup/pagedown.
M.PAGE = 10
-- Audit-log lines read; the guard never rotates that file.
M.MAX_GUARD_LINES = 1000

local KEYS: { [string]: boolean } = {}
for _, k in
	{
		"j",
		"k",
		"down",
		"up",
		"pagedown",
		"pageup",
		"g",
		"G",
		"home",
		"end",
		"enter",
		"escape",
		"backspace",
		"r",
		"p",
		"a",
		"s",
		"x",
		"o",
		"l",
		"c",
	}
do
	KEYS[k] = true
end

-- Whether the block uses this key (others reach Tern).
function M.handles(name: string): boolean
	return KEYS[name] == true
end

local function load(s: State): { Effect }
	s.gen += 1
	s.localLoad = "loading"
	s.guardLoad = "loading"
	local effects: { Effect } = { { t = "read_local", gen = s.gen }, { t = "read_guard", gen = s.gen } }
	if s.settings.ci == nil then
		s.ciLoad = "off"
		s.ciNote = "set history.ci in the config to list CI deploy runs"
	elseif s.cwd == nil then
		s.ciLoad = "off"
		s.ciNote = "no working directory to find a repository in"
	else
		s.ciLoad = "loading"
		s.ciError = nil
		table.insert(effects, { t = "git", gen = s.gen, cwd = s.cwd })
	end
	return effects
end

function M.visible(s: State): { Timeline.Item }
	return Timeline.filter(s.items, s.filters)
end

function M.selected(s: State): Timeline.Item?
	if s.sel == nil then
		return nil
	end
	for _, item in s.items do
		if item.key == s.sel then
			return item
		end
	end
	return nil
end

local function indexOf(items: { Timeline.Item }, key: string?): number?
	if key == nil then
		return nil
	end
	for i, item in items do
		if item.key == key then
			return i
		end
	end
	return nil
end

-- Keeps the selection when it is still shown, else selects the first row.
local function settle(s: State)
	local items = M.visible(s)
	if indexOf(items, s.sel) == nil then
		s.sel = if items[1] then items[1].key else nil
		s.detail = false
	end
end

local function rebuild(s: State)
	s.items = Timeline.build({ records = s.records, guards = s.guards, runs = s.runs, repo = s.repo })
	settle(s)
end

function M.init(opts: Init): (State, { Effect })
	local s: State = {
		gen = 0,
		cwd = opts.cwd,
		settings = opts.settings,
		decode = opts.decode,
		records = {},
		guards = {},
		runs = {},
		localLoad = "loading",
		guardLoad = "loading",
		ciLoad = "off",
		items = {},
		filters = {},
		detail = false,
	}
	return s, load(s)
end

local function move(s: State, by: number?, to: number?)
	local items = M.visible(s)
	if #items == 0 then
		return
	end
	local i = to or ((indexOf(items, s.sel) or 1) + (by :: number))
	s.sel = items[math.clamp(i, 1, #items)].key
end

local function cycle(s: State, name: string)
	local f = s.filters :: any
	f[name] = Timeline.cycle(Timeline.values(s.items, name), f[name])
	settle(s)
end

local function openTarget(item: Timeline.Item?): string?
	if item == nil then
		return nil
	end
	return item.url or item.log
end

local function key(s: State, name: string): { Effect }
	local item = M.selected(s)
	if name == "j" or name == "down" then
		move(s, 1)
	elseif name == "k" or name == "up" then
		move(s, -1)
	elseif name == "pagedown" then
		move(s, M.PAGE)
	elseif name == "pageup" then
		move(s, -M.PAGE)
	elseif name == "g" or name == "home" then
		move(s, nil, 1)
	elseif name == "G" or name == "end" then
		move(s, nil, #M.visible(s))
	elseif name == "enter" then
		s.detail = item ~= nil
	elseif name == "escape" or name == "backspace" then
		if s.detail then
			s.detail = false
		elseif name == "escape" then
			return { { t = "exit" } }
		end
	elseif name == "r" then
		return load(s)
	elseif name == "p" then
		cycle(s, "project")
	elseif name == "a" then
		cycle(s, "account")
	elseif name == "s" then
		cycle(s, "source")
	elseif name == "x" then
		s.filters = {}
		settle(s)
	elseif name == "o" then
		local target = openTarget(item)
		if target then
			return { { t = "open", url = target } }
		end
	elseif name == "l" then
		if item and item.runId and item.repo and item.status == "failed" then
			return { { t = "log", repo = item.repo, runId = item.runId } }
		end
	elseif name == "c" then
		local text = if item then item.line or item.url else nil
		if text then
			return { { t = "copy", text = text } }
		end
	end
	return {}
end

local KEY_OF_ACTION: { [string]: string } = {
	back = "escape",
	open = "o",
	log = "l",
	copy = "c",
	refresh = "r",
	clear = "x",
	close = "escape",
}

local FILTER_KEY: { [string]: string } = { project = "p", account = "a", source = "s" }

local function action(s: State, act: string, value: string?): { Effect }
	if act == "sel" and value then
		if s.sel == value then
			s.detail = true
		elseif indexOf(M.visible(s), value) then
			s.sel = value
		end
		return {}
	elseif act == "filter" and value and FILTER_KEY[value] then
		return key(s, FILTER_KEY[value])
	elseif act == "back" then
		s.detail = false
		return {}
	end
	local k = KEY_OF_ACTION[act]
	return if k then key(s, k) else {}
end

local function loaded(s: State, msg: Msg)
	local t = msg.t
	if t == "local" then
		s.localLoad = if msg.error then "error" else "ok"
		s.localError = msg.error
		local records: { Record.Record } = {}
		for _, line in Store.lines(msg.text, s.settings.max_entries) do
			local r = Record.decode(line, s.decode)
			if r then
				table.insert(records, r)
			end
		end
		if msg.error == nil then
			s.records = records
		end
	elseif t == "guard" then
		s.guardLoad = "ok"
		s.guards = GuardLog.parse(table.concat(Store.lines(msg.text, M.MAX_GUARD_LINES), "\n"), s.decode)
	elseif t == "ci" then
		if msg.status == 0 then
			local runs, err = Ci.parse(msg.stdout or "", s.decode)
			if runs then
				s.runs = runs
				s.ciLoad = "ok"
				s.ciError = nil
			else
				s.ciLoad = "error"
				s.ciError = err
			end
		else
			s.ciLoad = "error"
			s.ciError = Ci.errorText(msg.status or -1, msg.stderr or "", msg.timedOut == true)
		end
	end
	rebuild(s)
end

local function git(s: State, stdout: string): { Effect }
	local info = Git.parse(stdout)
	local ci = s.settings.ci
	s.branch = info.branch
	s.repo = Git.github(info.remote)
	if ci == nil then
		return {}
	end
	if info.root == nil then
		s.ciLoad, s.ciNote = "off", "not in a git repository"
		return {}
	end
	local repo = s.repo
	if repo == nil then
		s.ciLoad, s.ciNote = "off", "the repository's origin is not on GitHub"
		return {}
	end
	return { { t = "ci", gen = s.gen, argv = Ci.argv(ci, repo), timeoutMs = ci.timeout_ms } }
end

function M.update(s: State, msg: Msg): (State, { Effect })
	local t = msg.t
	if t == "key" then
		return s, key(s, msg.name or "")
	elseif t == "action" then
		return s, action(s, msg.act or "", msg.value)
	elseif t == "recorded" then
		return s, { { t = "read_local", gen = s.gen } }
	end
	if msg.gen ~= s.gen then
		return s, {}
	end
	if t == "git" then
		return s, git(s, msg.stdout or "")
	end
	loaded(s, msg)
	return s, {}
end

function M.title(s: State): string
	local n = #M.visible(s)
	return if n > 0 then string.format("Deploy history (%d)", n) else "Deploy history"
end

return M
