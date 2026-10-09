--!strict
-- Scanning adapter for lib/sdf/project.luau, usable from either half: finds
-- SDF projects, lists their files with find(1) (following symlinks per
-- config `projects.follow_symlinks`), resolves symlink targets with
-- realpath(1) and reads config, manifest, deploy and object XML with capped
-- tern.fs.read across timer ticks. Results arrive through callbacks as a
-- Snapshot; nothing here decides what is shown.
--
-- Processes cannot be killed: a newer scan of the same root, or cancel(),
-- only makes the older scan's results be dropped without a callback.

local ConfigHost = require("./config_host")
local Project = require("./lib/sdf/project")
local Snapshot = require("./lib/sdf/snapshot")

type Snapshot = Snapshot.Snapshot
type SnapshotFile = Snapshot.SnapshotFile
type Problem = Snapshot.Problem
type Project = Project.Project

export type ScanOpts = {
	-- Defaults: config projects.max_files / projects.follow_symlinks.
	maxFiles: number?,
	followSymlinks: boolean?,
	maxFileBytes: number?,
	timeoutMs: number?,
}

export type Scan = { cancel: () -> () }

local M = {}

M.CONFIG = "suitecloud.config.js"
M.MAX_FILE_BYTES = 4 * 1024 * 1024
M.TIMEOUT_MS = 30000
M.CHUNK_FILES = 100
M.CHUNK_MS = 50
-- Deep enough for <repo>/<root>/<group>/<project>/suitecloud.config.js.
M.DISCOVER_DEPTH = 4

local function firstLine(text: string): string
	return (string.match(text, "^%s*([^\n]*)") or "") :: string
end

local function failure(what: string, result: ProcessResult): string
	if result.timed_out then
		return what .. " timed out"
	end
	local detail = firstLine(result.stderr)
	return string.format("%s exited %d%s", what, result.status, if detail ~= "" then ": " .. detail else "")
end

-- Runs argv; spawn failures are reported like process failures.
local function run(argv: { string }, opts: ProcessOptions, cb: (ProcessResult) -> ())
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(result: ProcessResult)
			cb(result)
		end)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

local function normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	return if d == nil or d == "" then "/" else d
end

-- realpath(1) for each path in one process; missing entries failed.
local function resolve(paths: { string }, timeoutMs: number, cb: ({ [string]: string }) -> ())
	local argv = { "sh", "-c", 'for f; do printf "%s\\0" "$(realpath "$f" 2>/dev/null)"; done', "sh" }
	table.move(paths, 1, #paths, #argv + 1, argv)
	run(argv, { timeout_ms = timeoutMs }, function(result)
		local out: { [string]: string } = {}
		for i, target in string.split(result.stdout, "\0") do
			if paths[i] and target ~= "" then
				out[paths[i]] = target
			end
		end
		cb(out)
	end)
end

local function readCapped(path: string, cap: number): (string?, string?)
	local ok, text = pcall(tern.fs.read, path, cap)
	if ok then
		return text, nil
	end
	return nil, tostring(text)
end

-- Nearest ancestor of cwd (cwd included) containing suitecloud.config.js.
function M.find(cwd: string, cb: (root: string?) -> ())
	local dir = normalize(cwd)
	while true do
		local ok, present = pcall(tern.fs.exists, dir .. "/" .. M.CONFIG)
		if ok and present then
			cb(dir)
			return
		end
		if dir == "/" then
			cb(nil)
			return
		end
		dir = dirname(dir)
	end
end

-- Lists regular files under `dir` with sizes and, when following symlinks,
-- realpath targets. find -exec batches arguments, so each batch prints its
-- names, then wc(1) output (sizes keyed by name), then realpath(1) output
-- (one line per name, in order); "N", "W" and "R" markers cannot collide
-- with the absolute names.
local LIST_SCRIPT = [[
dir=$1 mode=$2
find "$mode" "$dir" -type f -exec sh -c '
printf "N\0"
for f do printf "%s\0" "$f"; done
printf "W\0"
wc -c "$@" 2>/dev/null
printf "\0R\0"
if [ "$0" = -L ]; then realpath "$@" 2>/dev/null; fi
printf "\0"
' "$mode" {} +
]]

type Listing = { path: string, size: number, real: string? }

local function parseListing(stdout: string, problems: { Problem }): { Listing }
	local out: { Listing } = {}
	local tokens = string.split(stdout, "\0")
	local i = 1
	while i <= #tokens do
		if tokens[i] ~= "N" then
			i += 1
			continue
		end
		i += 1
		local names: { string } = {}
		while i <= #tokens and tokens[i] ~= "W" do
			table.insert(names, tokens[i])
			i += 1
		end
		local wc = tokens[i + 1] or ""
		local reals = tokens[i + 3] or ""
		i += 4
		local sizes: { [string]: number } = {}
		for line in string.gmatch(wc, "[^\n]+") do
			local n, name = string.match(line, "^%s*(%d+) (.+)$")
			if n and name then
				sizes[name] = tonumber(n) :: number
			end
		end
		local realList: { string } = {}
		for line in string.gmatch(reals, "[^\n]+") do
			table.insert(realList, line)
		end
		local paired = #realList == #names
		if reals ~= "" and not paired then
			table.insert(problems, {
				path = nil,
				message = string.format("symlink targets of %d files could not be resolved", #names),
			})
		end
		for k, name in names do
			table.insert(out, { path = name, size = sizes[name] or 0, real = if paired then realList[k] else nil })
		end
	end
	return out
end

type Listener = { cb: (snapshot: Snapshot?, err: string?) -> (), cancelled: boolean }
type ScanState = { listeners: { Listener }, done: boolean }

-- The running scan per root. A newer scan of the root takes over the older
-- one's listeners, so every caller gets exactly one (the newest) result.
local running: { [string]: ScanState } = {}

-- Builds a Snapshot of the project at `root` (the directory containing
-- suitecloud.config.js). The snapshot keeps root as given; a file's `real`
-- is set whenever its realpath differs, a symlinked ancestor of root
-- (macOS /tmp) included, so either spelling of a path finds its owners.
--
-- `cb` runs exactly once unless the handle is cancelled. A newer scan of
-- the same root supersedes this one: `cb` then receives the newer scan's
-- result. `cb` never runs inside a timer callback.
function M.scan(root: string, opts: ScanOpts?, cb: (snapshot: Snapshot?, err: string?) -> ()): Scan
	local cfg = ConfigHost.current().projects
	local o: ScanOpts = opts or {}
	local maxFiles = o.maxFiles or cfg.max_files
	local follow = if o.followSymlinks == nil then cfg.follow_symlinks else o.followSymlinks
	local cap = o.maxFileBytes or M.MAX_FILE_BYTES
	local timeoutMs = o.timeoutMs or M.TIMEOUT_MS

	local given = normalize(root)
	local me: Listener = { cb = cb, cancelled = false }
	local state: ScanState = { listeners = { me }, done = false }
	local previous = running[given]
	if previous and not previous.done then
		previous.done = true
		table.move(previous.listeners, 1, #previous.listeners, 2, state.listeners)
	end
	running[given] = state

	local function live(): boolean
		if state.done then
			return false
		end
		for _, l in state.listeners do
			if not l.cancelled then
				return true
			end
		end
		return false
	end
	local function finish(snapshot: Snapshot?, err: string?)
		if state.done then
			return
		end
		state.done = true
		if running[given] == state then
			running[given] = nil
		end
		for _, l in state.listeners do
			if not l.cancelled then
				local ok, e = pcall(l.cb :: any, snapshot, err)
				if not ok then
					tern.log.warn("tern-netsuite project scan callback failed", given, tostring(e))
				end
			end
		end
	end
	-- A step that raises still answers every listener.
	local function guarded<A...>(fn: (A...) -> ()): (A...) -> ()
		return function(...: A...)
			local ok, e = pcall(fn :: any, ...)
			if not ok then
				finish(nil, "scan failed: " .. tostring(e))
			end
		end
	end

	local problems: { Problem } = {}
	local configPath = given .. "/" .. M.CONFIG
	local projectJson = given .. "/project.json"

	resolve(
		{ configPath, projectJson },
		timeoutMs,
		guarded(function(resolved: { [string]: string })
			if not live() then
				return
			end
			if resolved[configPath] == nil then
				finish(nil, string.format("%s has no readable %s", given, M.CONFIG))
				return
			end
			local configText, configErr = readCapped(resolved[configPath], cap)
			if configText == nil then
				table.insert(problems, { path = M.CONFIG, message = "not read: " .. tostring(configErr) })
			end
			local jsonText: string? = nil
			if resolved[projectJson] then
				local text, err = readCapped(resolved[projectJson], cap)
				jsonText = text
				if text == nil then
					table.insert(problems, { path = "project.json", message = "not read: " .. tostring(err) })
				end
			end
			local folder = Project.projectFolder(configText)
			local files: { SnapshotFile } = {}
			table.insert(files, {
				path = M.CONFIG,
				size = if configText then #configText else 0,
				text = configText,
				real = if resolved[configPath] ~= configPath then resolved[configPath] else nil,
			})
			if resolved[projectJson] then
				table.insert(files, {
					path = "project.json",
					size = if jsonText then #jsonText else 0,
					text = jsonText,
					real = if resolved[projectJson] ~= projectJson then resolved[projectJson] else nil,
				})
			end

			local dir = given .. "/" .. folder
			-- -H still follows a symlinked project folder itself.
			local mode = if follow then "-L" else "-H"
			run(
				{ "sh", "-c", LIST_SCRIPT, "sh", dir, mode },
				{ timeout_ms = timeoutMs },
				guarded(function(result)
					if not live() then
						return
					end
					if result.timed_out then
						finish(nil, failure("find " .. dir, result))
						return
					end
					if result.status ~= 0 then
						-- find exits nonzero after symlink loops or unreadable entries
						-- but still lists everything else.
						table.insert(problems, { path = folder, message = failure("find " .. dir, result) })
					end
					local listing = parseListing(result.stdout, problems)
					local prefix = given .. "/"
					local byRel: { [string]: Listing } = {}
					local rels: { string } = {}
					for _, entry in listing do
						if string.sub(entry.path, 1, #prefix) == prefix then
							local rel = string.sub(entry.path, #prefix + 1)
							byRel[rel] = entry
							table.insert(rels, rel)
						end
					end
					local kept, truncated = Snapshot.limit(rels, folder, maxFiles)
					if truncated then
						table.insert(problems, {
							path = folder,
							message = string.format(
								"%d files found; %d were scanned (projects.max_files %d; manifest, deploy and object XML "
									.. "are always scanned)",
								#rels,
								#kept,
								maxFiles
							),
						})
					end
					local pending: { SnapshotFile } = {}
					for _, rel in kept do
						local entry = byRel[rel]
						local real = entry.real
						table.insert(pending, {
							path = rel,
							size = entry.size,
							real = if real and real ~= entry.path then real else nil,
							text = nil,
						})
					end

					local i = 0
					local tick: (fromTimer: boolean) -> ()
					tick = guarded(function(fromTimer: boolean)
						if not live() then
							return
						end
						local t0 = tern.now()
						local n = 0
						while i < #pending and n < M.CHUNK_FILES and tern.now() - t0 < M.CHUNK_MS do
							i += 1
							local f = pending[i]
							if Snapshot.wantsText(f.path, folder) then
								n += 1
								if f.size > cap then
									table.insert(problems, {
										path = f.path,
										message = string.format(
											"not read: %d bytes is over the %d byte limit",
											f.size,
											cap
										),
									})
								else
									local text, err = readCapped(f.real or prefix .. f.path, cap)
									if text then
										f.text = text
									else
										table.insert(
											problems,
											{ path = f.path, message = "not read: " .. tostring(err) }
										)
									end
								end
							end
							table.insert(files, f)
						end
						if i < #pending then
							tern.timer(0, function()
								tick(true)
							end)
							return
						end
						local snapshot: Snapshot =
							{ root = given, files = files, truncated = truncated, problems = problems }
						if not fromTimer then
							finish(snapshot, nil)
							return
						end
						-- Consumers parse every object in the callback, and one slow
						-- timer callback disables the VM's timers: answer from a
						-- process callback instead.
						run({ "true" }, { timeout_ms = timeoutMs }, function()
							finish(snapshot, nil)
						end)
					end)
					tick(false)
				end)
			)
		end)
	)

	return {
		cancel = function()
			me.cancelled = true
		end,
	}
end

-- Project roots (directories containing suitecloud.config.js) under each of
-- `roots` (absolute, or relative to repoRoot; repoRoot itself when empty),
-- sorted. node_modules and .git are not searched. Symlinked roots and
-- config files count; symlinked directories below are followed when config
-- projects.follow_symlinks is on.
function M.discover(repoRoot: string, roots: { string }?, cb: (projectRoots: { string }, err: string?) -> ())
	local base = normalize(repoRoot)
	local dirs: { string } = {}
	local given: { string } = roots or {}
	for _, r in given do
		table.insert(dirs, if string.sub(r, 1, 1) == "/" then normalize(r) else normalize(base .. "/" .. r))
	end
	if #dirs == 0 then
		dirs = { base }
	end
	local argv = { "find", if ConfigHost.current().projects.follow_symlinks then "-L" else "-H" }
	table.move(dirs, 1, #dirs, #argv + 1, argv)
	for _, a in
		{
			"-maxdepth",
			tostring(M.DISCOVER_DEPTH),
			"(",
			"-name",
			"node_modules",
			"-o",
			"-name",
			".git",
			")",
			"-prune",
			"-o",
			"(",
			"-type",
			"f",
			"-o",
			"-type",
			"l",
			")",
			"-name",
			M.CONFIG,
			"-print",
		}
	do
		table.insert(argv, a)
	end
	run(argv, { timeout_ms = M.TIMEOUT_MS }, function(result)
		local seen: { [string]: boolean } = {}
		local out: { string } = {}
		for line in string.gmatch(result.stdout, "[^\n]+") do
			local d = dirname(line)
			if not seen[d] then
				seen[d] = true
				table.insert(out, d)
			end
		end
		table.sort(out)
		local err = if result.status ~= 0 then failure("find", result) else nil
		cb(out, err)
	end)
end

-- Scans and builds each project root in turn. A root that cannot be scanned
-- or built is reported in `errors` and left out; `cb` always runs once.
function M.projects(
	roots: { string },
	opts: ScanOpts?,
	cb: (projects: { Project }, errors: { { root: string, message: string } }) -> ()
)
	local projects: { Project } = {}
	local errors: { { root: string, message: string } } = {}
	local i = 0
	local function nextRoot()
		i += 1
		local root = roots[i]
		if root == nil then
			cb(projects, errors)
			return
		end
		M.scan(root, opts, function(snapshot: Snapshot?, err: string?)
			if snapshot then
				local ok, built = pcall(Project.build, snapshot)
				if ok then
					table.insert(projects, built)
				else
					table.insert(errors, { root = root, message = "could not model the project: " .. tostring(built) })
				end
			else
				table.insert(errors, { root = root, message = err or "scan failed" })
			end
			nextRoot()
		end)
	end
	nextRoot()
end

return table.freeze(M)
