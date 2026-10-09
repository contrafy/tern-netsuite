--!strict
-- Host/window adapter for plugin/lib/config.luau: finds, reads and caches
-- the user's config file. The file is read when this module is first
-- required (plugin load, in each half) and again by `load()`, which blocks
-- and palette commands call before acting. Lens callbacks
-- (open/line/finish/view/event) and chrome formatters must only call
-- `current()`: it never touches the disk.

local Config = require("./lib/config")

type Config = Config.Config
type Diagnostic = Config.Diagnostic

export type Status = "loaded" | "missing" | "unreadable" | "nopath" | "resolving"

export type Snapshot = {
	config: Config,
	diagnostics: { Diagnostic },
	path: string?,
	status: Status,
}

local M = {}

-- Far above any real config; bounds what a mistaken path can make us read.
M.MAX_BYTES = 262144

local function env(name: string): string?
	local v = tern.getenv(name)
	return if v == "" then nil else v
end

local function unreadable(path: string, err: any): Diagnostic
	return {
		level = "error",
		path = "",
		message = string.format(
			"could not read %s: %s. The file must be a regular file of at most %d bytes; "
				.. "using the defaults for every setting.",
			path,
			tostring(err),
			M.MAX_BYTES
		),
	}
end

-- Symlinked dotfiles (stow, chezmoi, home-manager) are common, but a capped
-- tern.fs.read refuses symlinks. realpath(1) resolves the link off the load
-- path; the target is then read with the same cap. false = resolution failed.
local resolved: { [string]: string | false } = {}
local resolving: { [string]: boolean } = {}

local function resolve(path: string)
	if resolving[path] then
		return
	end
	resolving[path] = true
	local ok = pcall(tern.process.run, { "realpath", path }, { timeout_ms = 2000 }, function(result: ProcessResult)
		resolving[path] = nil
		local target: string | false = (result.status == 0 and string.match(result.stdout, "^(/[^\n]+)")) or false
		if target ~= resolved[path] then
			resolved[path] = target
			M.load()
		end
	end)
	if not ok then
		resolving[path] = nil
		resolved[path] = false
	end
end

local function read(path: string): (string?, Status, Diagnostic?)
	local exists, present = pcall(tern.fs.exists, path)
	if exists and not present then
		return nil, "missing", nil
	end
	local ok, text = pcall(tern.fs.read, path, M.MAX_BYTES)
	if ok then
		return text, "loaded", nil
	end
	if not string.find(tostring(text), "non-symlink", 1, true) then
		return nil, "unreadable", unreadable(path, text)
	end
	local known = resolved[path]
	resolve(path)
	if known == nil then
		return nil,
			"resolving",
			{
				level = "info",
				path = "",
				message = string.format("%s is a symlink; defaults apply until its target is resolved.", path),
			}
	elseif known == false then
		return nil, "unreadable", unreadable(path, "symlink target could not be resolved with realpath")
	end
	local target = known :: string
	local tok, ttext = pcall(tern.fs.read, target, M.MAX_BYTES)
	if tok then
		return ttext, "loaded", nil
	end
	return nil, "unreadable", unreadable(target, ttext)
end

local function logChanges(previous: { Diagnostic }?, diags: { Diagnostic }, path: string?)
	local function key(list: { Diagnostic }): string
		local parts: { string } = {}
		for i, d in list do
			parts[i] = d.message
		end
		return table.concat(parts, "\n")
	end
	if previous and key(previous) == key(diags) then
		return
	end
	for _, d in diags do
		local where = if d.path == "" then "" else d.path .. ": "
		local line = string.format("tern-netsuite config %s: %s%s", path or "(no path)", where, d.message)
		if d.level == "error" or d.level == "warning" then
			tern.log.warn(line)
		else
			tern.log.info(line)
		end
	end
end

local snapshot: Snapshot
local lastText: string? = nil
local listeners: { () -> () } = {}

-- Re-reads the file. Call from plugin load or a block's init, never from a
-- lens callback. Listeners run when the file's text or read status changed.
function M.load(): Snapshot
	local path = Config.path({ XDG_CONFIG_HOME = env("XDG_CONFIG_HOME"), HOME = env("HOME") })
	local text: string?, status: Status, failure: Diagnostic? = nil, "nopath", nil
	if path then
		text, status, failure = read(path)
	end
	local changed = snapshot ~= nil and (text ~= lastText or status ~= snapshot.status or path ~= snapshot.path)
	lastText = text
	local config, diags = Config.parse(text, tern.json.decode)
	if failure then
		table.insert(diags, 1, failure)
	end
	local previous = if snapshot then snapshot.diagnostics else nil
	snapshot = table.freeze({ config = config, diagnostics = table.freeze(diags), path = path, status = status })
	logChanges(previous, diags, path)
	if changed then
		for _, fn in listeners do
			local ok, err = pcall(function()
				fn()
			end)
			if not ok then
				tern.log.warn("tern-netsuite config listener failed", tostring(err))
			end
		end
	end
	return snapshot
end

-- Runs `fn` after every load() that found a changed config file.
function M.onChange(fn: () -> ())
	table.insert(listeners, fn)
end

-- The cached config; no I/O.
function M.current(): Config
	return snapshot.config
end

-- The cached config with its diagnostics, path and read status; no I/O.
function M.snapshot(): Snapshot
	return snapshot
end

M.load()

return M
