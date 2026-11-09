--!strict
-- "Upload this file": which project uploads a source file, the account it
-- goes to, and the command line of the pane that runs it. The command always
-- goes through the deploy guard core (shell/tern-netsuite-guard): it runs
-- non-production targets at once and asks for approval in Tern for
-- production or unknown ones, failing closed. The account resolved here only
-- labels the pane; the guard resolves it again itself.
--
-- The pane waits in the auth ID's machine-wide CLI slot
-- (lib/sdf/cli_slot.luau) before the guard starts, so a second upload or a
-- browser listing for the same auth ID never runs beside it; the pane says
-- what it waits for. The slot is held through the guard's approval.
--
-- The SuiteCloud CLI reads project.json from its working directory only and
-- `file:upload` has no --authid or --project option (CLI 3.2.0), so the pane
-- must `cd` into the project root.

local CliSlot = require("../sdf/cli_slot")
local Resolve = require("../account/resolve")
local Symlinks = require("../sdf/symlinks")

export type Owner = Symlinks.Owner

export type Decision = {
	t: "none" | "one" | "pick",
	-- one: the owner; pick: every File Cabinet owner (sorted by project).
	owner: Owner?,
	owners: { Owner },
	-- none: why nothing can be uploaded.
	reason: string?,
}

export type Target = {
	authId: string?,
	label: string,
	accountId: string?,
	-- Unknown targets count as production.
	production: boolean,
	source: "configured" | "cli" | "unknown" | "none",
}

export type Launch = {
	-- What the guard is asked to run (for display).
	argv: { string },
	cwd: string,
	-- The POSIX script; `line` is `sh -c <script>`.
	script: string,
	line: string,
	title: string,
}

local M = {}

function M.decide(owners: { Owner }): Decision
	local files: { Owner } = {}
	local objects = 0
	for _, o in owners do
		if o.fileCabinetPath then
			table.insert(files, o)
		else
			objects += 1
		end
	end
	if #files == 1 then
		return { t = "one", owner = files[1], owners = files, reason = nil }
	elseif #files > 1 then
		return { t = "pick", owner = nil, owners = files, reason = nil }
	end
	local reason = if objects > 0
		then "it is an SDF object, not a File Cabinet file: send it with project:deploy"
		else "no scanned SDF project carries it in its File Cabinet"
	return { t = "none", owner = nil, owners = files, reason = reason }
end

function M.target(authId: string?, opts: Resolve.Options): Target
	if authId == nil then
		return { authId = nil, label = "no auth id", accountId = nil, production = true, source = "none" }
	end
	local r = Resolve.resolve(authId, opts)
	return {
		authId = authId,
		label = r.label,
		accountId = r.accountId,
		production = r.production,
		source = r.source,
	}
end

local function badPath(path: string, what: string): string?
	if string.sub(path, 1, 1) ~= "/" then
		return what .. " is not absolute"
	end
	if string.find(path, "%c") then
		return what .. " contains control characters"
	end
	for part in string.gmatch(path, "[^/]+") do
		if part == "." or part == ".." then
			return what .. " contains a . or .. segment"
		end
	end
	return nil
end

-- The upload pane of `owner`'s file, waiting in the CLI slot `lock` (see
-- CliSlotHost.lock) of the project's auth ID.
function M.command(owner: Owner, guard: string, target: Target, lock: string): (Launch?, string?)
	local fc = owner.fileCabinetPath
	if fc == nil then
		return nil, owner.path .. " is not a File Cabinet file"
	end
	local why = badPath(owner.root, "project root") or badPath(guard, "guard path") or badPath(fc, "File Cabinet path")
	if why then
		return nil, why
	end
	if string.find(fc, '"', 1, true) then
		return nil,
			"the SuiteCloud CLI wraps --paths in double quotes and cannot upload a path containing a double quote"
	end
	local argv = { guard, "suitecloud", "file:upload", "--paths", fc }
	local title = string.format(
		"tern-netsuite upload %s -> %s%s",
		fc,
		target.label,
		if target.production then " (production: approval required)" else ""
	)
	local script, err = CliSlot.paneScript({
		title = title,
		intro = string.format("uploading %s from %s to %s", fc, owner.project, target.label),
		cwd = owner.root,
		lock = lock,
		argv = argv,
	})
	if script == nil then
		return nil, (err or "") .. "; upload it from a terminal"
	end
	return {
		argv = argv,
		cwd = owner.root,
		script = script,
		line = CliSlot.paneLine(script),
		title = CliSlot.printable(title),
	},
		nil
end

return table.freeze(M)
