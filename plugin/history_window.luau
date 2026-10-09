--!strict
-- Window glue for deploy history: the palette command opening the
-- `history` block, the `history` link area (a failed CI run's log in a
-- split pane; blocks cannot split), and a cached CI deploy state for the
-- status line (`ciSegment`). The segment only reads caches; window events
-- and a poll timer refresh them with read-only git and `gh run list` runs.

local Ci = require("./lib/history/ci")
local ConfigHost = require("./config_host")
local Git = require("./lib/history/git")
local Link = require("./lib/history/link")
local Settings = require("./lib/history/settings")

local log = tern.log

local M = {}

M.BLOCK = "tern-netsuite.history"
M.COMMAND = "plugin.tern-netsuite.history"
M.GIT_TIMEOUT_MS = 5000
-- How long a directory's repository/branch answer is reused.
M.REPO_TTL_MS = 30000
-- A `git push` usually starts a deploy run; ask again after this delay.
M.AFTER_PUSH_MS = 15000
M.MAX_REPOS = 256

type RepoInfo = { at: number, github: string?, branch: string? }
type Runs = { at: number, runs: { Ci.Run }?, error: string? }

local repos: { [string]: RepoInfo } = {}
local repoCount = 0
local runs: { [string]: Runs } = {}
local inflightRepo: { [string]: boolean } = {}
local inflightRuns: { [string]: boolean } = {}
local lastCwd: string? = nil

local function ci(): Settings.Ci?
	return Settings.of(ConfigHost.current()).ci
end

local function redraw()
	pcall(tern.chrome.refresh)
end

local function run(argv: { string }, opts: ProcessOptions, done: (ProcessResult) -> ())
	local ok, err = pcall(function()
		tern.process.run(argv, opts, done)
	end)
	if not ok then
		tern.timer(1, function()
			done({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end)
	end
end

local function fetchRuns(c: Settings.Ci, github: string, force: boolean)
	local cached = runs[github]
	if inflightRuns[github] then
		return
	end
	if not force and cached and tern.now() - cached.at < c.poll_seconds * 1000 then
		return
	end
	inflightRuns[github] = true
	run(Ci.argv(c, github), { timeout_ms = c.timeout_ms, stdin = "" }, function(r: ProcessResult)
		inflightRuns[github] = nil
		local list, why = nil, nil
		if r.status == 0 then
			list, why = Ci.parse(r.stdout, tern.json.decode)
		else
			why = Ci.errorText(r.status, r.stderr, r.timed_out)
		end
		-- Keep the last good list through a transient failure.
		local previous = runs[github]
		runs[github] = {
			at = tern.now(),
			runs = list or (if previous then previous.runs else nil),
			error = why,
		}
		if why then
			log.info("tern-netsuite history: gh run list failed", github, why)
		end
		redraw()
	end)
end

local function refresh(cwd: string?, force: boolean?)
	local c = ci()
	if c == nil or cwd == nil or string.sub(cwd, 1, 1) ~= "/" then
		return
	end
	lastCwd = cwd
	local known = repos[cwd]
	if known and tern.now() - known.at < M.REPO_TTL_MS then
		if known.github then
			fetchRuns(c, known.github, force == true)
		end
		return
	end
	if inflightRepo[cwd] then
		return
	end
	inflightRepo[cwd] = true
	run(Git.argv(cwd, false), { timeout_ms = M.GIT_TIMEOUT_MS }, function(r: ProcessResult)
		inflightRepo[cwd] = nil
		local info = Git.parse(r.stdout)
		local before = repos[cwd]
		if before == nil then
			if repoCount >= M.MAX_REPOS then
				table.clear(repos)
				repoCount = 0
			end
			repoCount += 1
		end
		local github = Git.github(info.remote)
		repos[cwd] = { at = tern.now(), github = github, branch = info.branch }
		if github then
			fetchRuns(c, github, force == true)
		end
		if before == nil or before.branch ~= info.branch or before.github ~= github then
			redraw()
		end
	end)
end

local function paneCwd(cx: WindowCx, pane: number?): string?
	local ok, info = pcall(function()
		local id = pane or cx.session:focused()
		return if id then cx.session:pane(id) else nil
	end)
	local cwd = if ok and info then info.cwd else nil
	return if cwd and cwd ~= "" then cwd else nil
end

local function guarded(what: string, fn: () -> ())
	local ok, err = pcall(function()
		fn()
	end)
	if not ok then
		log.warn("tern-netsuite history " .. what .. " failed", tostring(err))
	end
end

-- The focused repository's latest CI deploy on its current branch; nil
-- when CI runs are not configured or nothing is known yet. Reads caches only.
function M.ciSegment(pane: StatusPaneInfo): StatusSegment?
	local cwd = pane.cwd
	if ci() == nil or cwd == nil or cwd == "" then
		return nil
	end
	local repo = repos[cwd]
	if repo == nil or repo.github == nil then
		return nil
	end
	local known = runs[repo.github :: string]
	if known == nil or known.runs == nil then
		return nil
	end
	local seg = Ci.segment(Ci.latestCi(known.runs, repo.branch))
	if seg == nil then
		return nil
	end
	return { text = seg.text, tone = seg.tone, icon = "cloud", command = M.COMMAND }
end

function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local parsed = Link.parse(link.url)
	if parsed == nil then
		cx:toast("error", "Tern NetSuite: unknown history link", link.url)
		return { handled = true }
	end
	local c = ci()
	local command = Ci.logCommand(if c then c.gh else "gh", parsed.repo, parsed.run) .. " 2>&1 | less -R"
	local pane = cx.layout:split(link.pane, "right", { command = command, cwd = paneCwd(cx, link.pane) })
	if pane == nil then
		cx:copy(command)
		cx:toast("info", "Tern NetSuite: could not open a pane", "The command was copied: " .. command)
	end
	return { handled = true }
end

local function poll()
	local c = ci()
	local every = if c then c.poll_seconds * 1000 else 300000
	tern.timer(every, function()
		guarded("poll", function()
			refresh(lastCwd, true)
		end)
		poll()
	end)
end

function M.register()
	tern.command({
		id = "history",
		title = "Tern NetSuite: Deploy history",
		icon = "cloud",
		run = function(cx: WindowCx)
			local cwd = paneCwd(cx, nil)
			if cx:new_block(M.BLOCK, if cwd and string.sub(cwd, 1, 1) == "/" then { cwd } else {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})

	tern.on("window_start", function(cx: WindowCx)
		guarded("window_start", function()
			refresh(paneCwd(cx, nil))
		end)
	end)
	tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
		guarded("focus", function()
			refresh(paneCwd(cx, ev.pane))
		end)
	end)
	tern.on("cwd", function(ev: CwdEvent, _cx: WindowCx)
		guarded("cwd", function()
			refresh(ev.path)
		end)
	end)
	tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
		guarded("command_finished", function()
			local cwd = paneCwd(cx, ev.pane)
			-- The branch may have changed (checkout) and a push starts a run.
			local known = if cwd then repos[cwd] else nil
			if known then
				known.at = 0
			end
			refresh(cwd)
			if string.match(ev.line, "^%s*git%s+push") then
				tern.timer(M.AFTER_PUSH_MS, function()
					guarded("after push", function()
						refresh(cwd, true)
					end)
				end)
			end
		end)
	end)
	poll()
end

return M
