--!strict
-- "Upload this file": which project uploads a source file, the account it
-- goes to, and the command line of the pane that runs it. The command always
-- goes through the deploy guard core (shell/tern-netsuite-guard): it runs
-- non-production targets at once and asks for approval in Tern for
-- production or unknown ones, failing closed. The account resolved here only
-- labels the pane; the guard resolves it again itself.
--
-- The SuiteCloud CLI reads project.json from its working directory only and
-- `file:upload` has no --authid or --project option (CLI 3.2.0), so the pane
-- must `cd` into the project root.

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

-- One POSIX shell word: bare when it has only safe characters, else single
-- quoted with each ' written as '\''.
function M.quote(s: string): string
	if s ~= "" and string.find(s, "^[%w%-_%./:=@+,]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function printable(s: string): string
	return (string.gsub(s, "%c", "?"))
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

function M.command(owner: Owner, guard: string, target: Target): (Launch?, string?)
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
	local quoted: { string } = {}
	for i, w in argv do
		quoted[i] = M.quote(w)
	end
	local title = string.format(
		"tern-netsuite upload %s -> %s%s",
		printable(fc),
		printable(target.label),
		if target.production then " (production: approval required)" else ""
	)
	local script = table.concat({
		"printf '\\033]0;%s\\007' " .. M.quote(title),
		"printf 'tern-netsuite: %s\\n' " .. M.quote(
			string.format(
				"uploading %s from %s to %s",
				printable(fc),
				printable(owner.project),
				printable(target.label)
			)
		),
		"cd " .. M.quote(owner.root) .. " && " .. table.concat(quoted, " "),
		"s=$?",
		"printf '\\ntern-netsuite: file:upload exited %s; press Enter to close\\n' \"$s\"",
		"read -r _",
		'exit "$s"',
	}, "; ")
	return {
		argv = argv,
		cwd = owner.root,
		script = script,
		line = "sh -c " .. M.quote(script),
		title = title,
	},
		nil
end

return table.freeze(M)
