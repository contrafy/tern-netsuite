--!strict
-- Window glue for the SDF explorer: the palette commands "SDF explorer" and
-- "Upload this file", and the `explorer` link area, through which the
-- explorer block asks for an upload pane with a single-use grant
-- (lib/explorer/link.luau).
--
-- An upload always runs in a new split as
-- `cd <project> && <plugin>/shell/tern-netsuite-guard suitecloud file:upload
-- --paths <path>` (lib/explorer/upload.luau): the guard core runs it at once
-- for non-production accounts and asks for approval in Tern otherwise. When
-- the guard core is missing nothing runs.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local Link = require("./lib/explorer/link")
local Manageauth = require("./lib/account/manageauth")
local ProjectHost = require("./project_host")
local Resolve = require("./lib/account/resolve")
local Symlinks = require("./lib/sdf/symlinks")
local Upload = require("./lib/explorer/upload")

local log = tern.log

local M = {}

M.BLOCK = "tern-netsuite.explorer"
M.GUARD = "shell/tern-netsuite-guard"
M.CONFIG_FILE = "suitecloud.config.js"
M.INFO_TIMEOUT_MS = 60000
M.PICK_FLAG = "--pick"

local cache: Resolve.Cache = {}
-- Latest "Upload this file" request; an older one still scanning is dropped.
local requestGen = 0

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	return if d == nil or d == "" then "/" else d
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function guarded(what: string, fn: () -> ())
	local ok, err = pcall(function()
		fn()
	end)
	if not ok then
		log.warn("tern-netsuite explorer " .. what .. " failed", tostring(err))
	end
end

-- Runs `fn` with a fresh WindowCx: async callbacks of project_host carry
-- none, and a timer callback does.
local function withCx(fn: (WindowCx) -> ())
	tern.timer(0, function(cx: WindowCx?)
		if cx == nil then
			log.warn("tern-netsuite explorer: no window for an upload answer")
			return
		end
		guarded("upload", function()
			fn(cx)
		end)
	end)
end

local function launch(cx: WindowCx, pane: number?, owner: Upload.Owner, target: Upload.Target)
	local fc = owner.fileCabinetPath or owner.path
	local guard = tern.plugin.dir .. "/" .. M.GUARD
	if not exists(guard) then
		cx:toast(
			"error",
			"Tern NetSuite: upload refused (" .. target.label .. ")",
			string.format(
				"The deploy guard core %s is missing. Run `cd %s && suitecloud file:upload --paths %s` in a guarded terminal.",
				guard,
				Upload.quote(owner.root),
				Upload.quote(fc)
			)
		)
		return
	end
	if not exists(owner.root .. "/" .. M.CONFIG_FILE) or not exists(owner.root .. "/" .. owner.path) then
		cx:toast("error", "Tern NetSuite: upload refused", owner.root .. "/" .. owner.path .. " is gone; rescan")
		return
	end
	local l, err = Upload.command(owner, guard, target)
	if l == nil then
		cx:toast("error", "Tern NetSuite: upload refused", err)
		return
	end
	local at = pane or cx.session:focused()
	local opened = if at then cx.layout:split(at, "down", { command = l.line, cwd = owner.root }) else nil
	log.info("tern-netsuite upload", owner.project, fc, target.label, "pane=" .. tostring(opened))
	if opened == nil then
		cx:toast("error", "Tern NetSuite: could not open a pane for the upload", "Nothing was run")
		return
	end
	cx:toast(
		"info",
		"Tern NetSuite: uploading " .. fc,
		if target.production
			then owner.project .. " -> " .. target.label .. ": production or unknown account, approve it in Tern"
			else owner.project .. " -> " .. target.label
	)
end

-- The account of `authId`, asking the CLI (`manageauth --info`) when the
-- config does not list it; `cb` gets a fresh WindowCx.
local function resolveTarget(authId: string?, cb: (WindowCx, Upload.Target) -> ())
	local cfg = ConfigHost.current()
	local function answer(cx: WindowCx)
		cb(cx, Upload.target(authId, { config = cfg, cache = cache, now = tern.now() }))
	end
	if authId == nil or not Resolve.needsLookup(authId, { config = cfg, cache = cache, now = tern.now() }) then
		withCx(answer)
		return
	end
	local ok, err = pcall(function()
		tern.process.run(
			{ cfg.suitecloud.program, "account:manageauth", "--info", authId },
			{ timeout_ms = M.INFO_TIMEOUT_MS },
			function(r: ProcessResult, cx: WindowCx?)
				local info = if r.status == 0 then Manageauth.parseInfo(Manageauth.lines(r.stdout)) else nil
				if info and info.accountId then
					cache = Resolve.store(cache, Resolve.fromInfo(info, tern.now()))
				else
					local why = if r.timed_out
						then "timed out"
						else Manageauth.errorText(Manageauth.lines(r.stderr .. "\n" .. r.stdout))
					cache = Resolve.store(cache, Resolve.fromError(authId, why or ("exit " .. r.status), tern.now()))
				end
				if cx then
					guarded("upload", function()
						answer(cx)
					end)
				else
					withCx(answer)
				end
			end
		)
	end)
	if not ok then
		log.warn("tern-netsuite: could not run " .. cfg.suitecloud.program, tostring(err))
		cache = Resolve.store(cache, Resolve.fromError(authId, tostring(err), tern.now()))
		withCx(answer)
	end
end

local function focusedPane(cx: WindowCx): (number?, PaneInfo?)
	local ok, id, info = pcall(function()
		local focused = cx.session:focused()
		return focused, if focused then cx.session:pane(focused) else nil
	end)
	if not ok then
		return nil, nil
	end
	return id, info
end

local function focusedCwd(cx: WindowCx): string?
	local _, info = focusedPane(cx)
	local cwd = if info then info.cwd else nil
	return if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil
end

-- "Upload this file": finds every project that carries the focused file
-- (symlinks included), then uploads from the only one or opens the
-- explorer on a picker.
local function uploadFocused(cx: WindowCx)
	local pane, info = focusedPane(cx)
	if info and info.kind == "plugin" and info.block == M.BLOCK then
		cx:toast("info", "Tern NetSuite: in the explorer, select a File Cabinet file and press u")
		return
	end
	local path = if info and info.kind == "file" then info.path else nil
	if path and string.sub(path, 1, 1) ~= "/" and info and info.cwd and info.cwd ~= "" then
		path = info.cwd .. "/" .. path
	end
	if path == nil or string.sub(path, 1, 1) ~= "/" then
		cx:toast("info", "Tern NetSuite: focus a file to upload", "Or press u on a file in the SDF explorer")
		return
	end
	local file = Symlinks.normalize(path)
	local cfg = ConfigHost.load().config
	local dir = dirname(file)
	local repo = Context.repoRoot(dir, exists)
	local project = Context.findRoot(dir, exists)
	local base = repo or (if project then dirname(project) else dir)
	local roots = if repo and #cfg.projects.roots > 0 then cfg.projects.roots else nil
	requestGen += 1
	local gen = requestGen
	cx:toast("info", "Tern NetSuite: finding the projects that carry " .. basename(file))

	ProjectHost.discover(base, roots, function(found: { string }, _err: string?)
		if gen ~= requestGen then
			return
		end
		local list = table.clone(found)
		if project and not table.find(list, project) then
			table.insert(list, project)
		end
		ProjectHost.projects(list, nil, function(projects, _errors)
			if gen ~= requestGen then
				return
			end
			local d = Upload.decide(Symlinks.owners(Symlinks.index(projects), file))
			if d.t == "none" then
				withCx(function(wcx: WindowCx)
					wcx:toast("info", "Tern NetSuite: nothing to upload", basename(file) .. ": " .. (d.reason or ""))
				end)
			elseif d.t == "pick" then
				withCx(function(wcx: WindowCx)
					if wcx:new_block(M.BLOCK, { dir, M.PICK_FLAG, file }, "beside") == nil then
						wcx:toast("error", "Tern NetSuite is not loaded on this host")
					end
				end)
			else
				local owner = d.owner :: Upload.Owner
				local authId: string? = nil
				for _, p in projects do
					if p.root == owner.root then
						authId = p.defaultAuthId
					end
				end
				resolveTarget(authId, function(wcx: WindowCx, target: Upload.Target)
					launch(wcx, pane, owner, target)
				end)
			end
		end)
	end)
end

-- `tern-netsuite://explorer/upload?grant=<id>` from the explorer block.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action, id = Link.parse(link.url)
	if action == nil or id == nil then
		cx:toast("error", "Tern NetSuite: invalid explorer link", link.url)
		return { handled = true }
	end
	local grant, rest, why = Link.takeGrant(tern.kv.get(Link.GRANTS_KEY), id, os.time())
	tern.kv.set(Link.GRANTS_KEY, rest)
	if grant == nil then
		cx:toast("error", "Tern NetSuite: upload not started", why)
		return { handled = true }
	end
	launch(cx, link.pane, {
		project = grant.project,
		root = grant.root,
		path = grant.path,
		fileCabinetPath = grant.fileCabinetPath,
	}, {
		authId = grant.authId,
		label = grant.label,
		accountId = grant.accountId,
		production = grant.production,
		source = if grant.accountId then "cli" else "unknown",
	})
	return { handled = true }
end

function M.register()
	tern.command({
		id = "explorer",
		title = "Tern NetSuite: SDF explorer",
		icon = "cloud",
		run = function(cx: WindowCx)
			local cwd = focusedCwd(cx)
			if cx:new_block(M.BLOCK, if cwd then { cwd } else {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
	tern.command({
		id = "upload-file",
		title = "Tern NetSuite: Upload this file",
		icon = "cloud",
		run = function(cx: WindowCx)
			uploadFocused(cx)
		end,
	})
end

return M
