--!strict
-- Window glue for the account indicator: a status-line segment naming the
-- account the focused pane's SDF project deploys to (plus that account's
-- health badge, pushed by health_window.luau), and the Doctor command.
-- The formatter only reads the caches below; window events fill them
-- (project.json reads, `manageauth --info` for auth ids the config does not
-- list) and then redraw the chrome.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local Manageauth = require("./lib/account/manageauth")
local Resolve = require("./lib/account/resolve")
local Status = require("./lib/account/status")

local log = tern.log

local M = {}

M.DOCTOR_BLOCK = "tern-netsuite.doctor"
M.INFO_TIMEOUT_MS = 60000
M.MAX_PROJECT_BYTES = 65536
-- Bounds the per-directory cache; it is rebuilt from events when cleared.
M.MAX_CONTEXTS = 256

-- cwd -> its project (nil inside: the cwd is in none).
type Known = { ctx: Context.Context? }
local contexts: { [string]: Known } = {}
local contextCount = 0
local cache: Resolve.Cache = {}
local inflight: { [string]: boolean } = {}
-- Upper-case account id -> health badge text.
local healthBadges: { [string]: string } = {}

local lookup: Context.Lookup = {
	exists = function(path: string): boolean
		local ok, present = pcall(tern.fs.exists, path)
		return ok and present == true
	end,
	read = function(path: string): string?
		local ok, text = pcall(tern.fs.read, path, M.MAX_PROJECT_BYTES)
		return if ok then text else nil
	end,
	decode = tern.json.decode,
}

local function redraw()
	pcall(tern.chrome.refresh)
end

local function resolveOpts(): Resolve.Options
	return { config = ConfigHost.current(), cache = cache, now = tern.now() }
end

local function lookupAuth(authId: string)
	if inflight[authId] or not Resolve.needsLookup(authId, resolveOpts()) then
		return
	end
	inflight[authId] = true
	local program = ConfigHost.current().suitecloud.program
	local function done(entry: Resolve.CacheEntry)
		inflight[authId] = nil
		cache = Resolve.store(cache, entry)
		redraw()
	end
	local ok, err = pcall(function()
		tern.process.run(
			{ program, "account:manageauth", "--info", authId },
			{ timeout_ms = M.INFO_TIMEOUT_MS },
			function(r: ProcessResult)
				local info = if r.status == 0 then Manageauth.parseInfo(Manageauth.lines(r.stdout)) else nil
				if info and info.accountId then
					done(Resolve.fromInfo(info, tern.now()))
					return
				end
				local why = if r.timed_out
					then "timed out"
					else Manageauth.errorText(Manageauth.lines(r.stderr .. "\n" .. r.stdout))
				done(Resolve.fromError(authId, why or ("exit " .. r.status), tern.now()))
			end
		)
	end)
	if not ok then
		log.warn("tern-netsuite: could not run " .. program, tostring(err))
		done(Resolve.fromError(authId, tostring(err), tern.now()))
	end
end

local function refresh(cwd: string?)
	if cwd == nil or string.sub(cwd, 1, 1) ~= "/" then
		return
	end
	local ctx = Context.forCwd(cwd, lookup)
	local known = contexts[cwd]
	if known == nil then
		if contextCount >= M.MAX_CONTEXTS then
			table.clear(contexts)
			contextCount = 0
		end
		contextCount += 1
	end
	contexts[cwd] = { ctx = ctx }
	if ctx and ctx.authId then
		lookupAuth(ctx.authId)
	end
	local before = if known then known.ctx else nil
	local changed = known == nil
		or (before == nil) ~= (ctx == nil)
		or (before ~= nil and ctx ~= nil and (before.authId ~= ctx.authId or before.projectRoot ~= ctx.projectRoot))
	if changed then
		redraw()
	end
end

local function paneCwd(cx: WindowCx, pane: number?): string?
	local ok, info = pcall(function()
		local id = pane or cx.session:focused()
		return if id then cx.session:pane(id) else nil
	end)
	return if ok and info then info.cwd else nil
end

local function guarded(what: string, fn: () -> ())
	local ok, err = pcall(function()
		fn()
	end)
	if not ok then
		log.warn("tern-netsuite status " .. what .. " failed", tostring(err))
	end
end

-- Other features append cache-only segments (e.g. the CI deploy state);
-- a provider that raises is skipped so the account segment always shows.
type Provider = (pane: StatusPaneInfo) -> StatusSegment?
local providers: { Provider } = {}

function M.addProvider(fn: Provider)
	table.insert(providers, fn)
end

function M.segments(pane: StatusPaneInfo): { StatusSegment }?
	local cwd = pane.cwd
	if cwd == nil or cwd == "" then
		return nil
	end
	local known = contexts[cwd]
	local out: { StatusSegment } = {}
	if known and known.ctx then
		out = Status.segments(known.ctx, resolveOpts(), healthBadges) or {}
	end
	for _, fn in providers do
		local ok, seg = pcall(fn, pane)
		if ok and seg then
			table.insert(out, seg)
		end
	end
	return if #out > 0 then out else nil
end

-- Replaces the health badges; the caller redraws the chrome.
function M.setHealthBadges(badges: { [string]: string })
	healthBadges = badges
end

function M.register()
	tern.chrome.status(M.segments)

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
	-- A command may have run account:setup or rewritten project.json.
	tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
		guarded("command_finished", function()
			refresh(paneCwd(cx, ev.pane))
		end)
	end)

	tern.command({
		id = "doctor",
		title = "Tern NetSuite: Doctor",
		icon = "cloud",
		run = function(cx: WindowCx)
			local cwd = paneCwd(cx, nil)
			local args = if cwd and string.sub(cwd, 1, 1) == "/" then { cwd } else {}
			if cx:new_block(M.DOCTOR_BLOCK, args, "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
end

return M
