--!strict
-- The I/O-free input of lib/sdf/project.luau: what a scan of one SDF project
-- directory produced. plugin/project_host.luau builds it; specs build it
-- from fixtures.

export type SnapshotFile = {
	-- Relative to the snapshot root, "/"-separated, e.g. "src/Objects/x.xml".
	path: string,
	-- Absolute symlink-resolved target, only when it differs from root/path.
	real: string?,
	size: number,
	-- Contents of the files wantsText() selects; nil for every other file and
	-- for selected files that could not be read (see problems).
	text: string?,
}

export type Problem = {
	path: string?,
	message: string,
}

export type Snapshot = {
	-- Absolute project directory, the one containing suitecloud.config.js.
	root: string,
	files: { SnapshotFile },
	-- More files existed than the scan was allowed to list.
	truncated: boolean?,
	-- What the scan could not do (unreadable files, failed commands).
	problems: { Problem }?,
}

-- Whether a scan reads `path` (relative to the root): the root config files,
-- manifest.xml, deploy.xml and object XML under the project folder.
local function wantsText(path: string, projectFolder: string): boolean
	if path == "suitecloud.config.js" or path == "project.json" then
		return true
	end
	local prefix = projectFolder .. "/"
	if string.sub(path, 1, #prefix) ~= prefix then
		return false
	end
	local rest = string.sub(path, #prefix + 1)
	return rest == "manifest.xml"
		or rest == "deploy.xml"
		or (string.sub(rest, 1, 8) == "Objects/" and string.lower(string.sub(rest, -4)) == ".xml")
end

-- Applies projects.max_files to relative paths: every wantsText() path is
-- kept (without them the project cannot be modelled at all), the others
-- fill what is left of the limit in sorted order. Returns the kept paths,
-- sorted, and whether any were dropped.
local function limit(paths: { string }, projectFolder: string, maxFiles: number): ({ string }, boolean)
	local sorted = table.clone(paths)
	table.sort(sorted)
	if #sorted <= maxFiles then
		return sorted, false
	end
	local wanted = 0
	for _, p in sorted do
		if wantsText(p, projectFolder) then
			wanted += 1
		end
	end
	local budget = maxFiles - wanted
	local kept: { string } = {}
	for _, p in sorted do
		if wantsText(p, projectFolder) then
			table.insert(kept, p)
		elseif budget > 0 then
			budget -= 1
			table.insert(kept, p)
		end
	end
	return kept, #kept < #sorted
end

return table.freeze({ wantsText = wantsText, limit = limit })
