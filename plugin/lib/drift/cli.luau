--!strict
-- The SuiteCloud CLI commands a drift run starts in its scratch project
-- (CLI 3.2.0 non-interactive flags) and what their output says.
--
-- object:import runs more than 8 script ids as parallel SDK calls (its
-- NUMBER_OF_SCRIPTS = 8, MAX_PARALLEL_EXECUTIONS = 4), and parallel calls
-- for one auth ID race on its token refresh, so each command imports at
-- most 8 objects of one type: one SDK call per command. Output (stdout,
-- captured in a sandbox):
--   The following objects have been imported:
--       - customlist:customlist_acme_sizes
--   The following objects have not been imported:
--       - customlist:customlist_acme_missing failed: Record does not exist.
--       - restlet:customscript_x failed: You cannot download the XML file for this object because it is locked..
--   The following objects failed with reason "<why>":     (a failed SDK call)
--       - customlist_acme_a
-- file:import prints
--   The following files were imported:
--   /SuiteScripts/a.js
--   The following files were not imported:
--   /SuiteScripts/b.js, INVALID FILE PATH: /SuiteScripts/b.js
-- and refuses SuiteApp projects. Exit statuses are not reliable (a run
-- where every object failed exits 1, one where every file failed exits 0),
-- so the output decides.

local CliSlot = require("../sdf/cli_slot")
local Listing = require("../sdf/listing")

local M = {}

M.OBJECT_BATCH = 8
M.FILE_BATCH = 25
M.OBJECTS_FOLDER = "/Objects"
M.REAUTH_MARKER = "Starting the browser-based authentication"
-- Failure reasons that mean "not in the account".
M.MISSING_OBJECT = "Record does not exist"
M.MISSING_FILE = "INVALID FILE PATH"

export type ObjectRef = { type: string, scriptId: string }
export type ObjectBatch = { type: string, scriptIds: { string } }

export type Imported = {
	-- Script ids (objects) or File Cabinet paths (files).
	imported: { [string]: boolean },
	failed: { [string]: string },
	-- Some line was an import result.
	recognized: boolean,
}

local function chunks(items: { string }, size: number): { { string } }
	local out: { { string } } = {}
	for i = 1, #items, size do
		table.insert(out, table.move(items, i, math.min(i + size - 1, #items), 1, {}))
	end
	return out
end

-- Batches in the order types first appear in `objects`.
function M.objectBatches(objects: { ObjectRef }): { ObjectBatch }
	local order: { string } = {}
	local byType: { [string]: { string } } = {}
	for _, o in objects do
		local ids = byType[o.type]
		if ids == nil then
			ids = {}
			byType[o.type] = ids
			table.insert(order, o.type)
		end
		table.insert(ids :: { string }, o.scriptId)
	end
	local out: { ObjectBatch } = {}
	for _, ty in order do
		for _, ids in chunks(byType[ty], M.OBJECT_BATCH) do
			table.insert(out, { type = ty, scriptIds = ids })
		end
	end
	return out
end

function M.fileBatches(paths: { string }): { { string } }
	return chunks(paths, M.FILE_BATCH)
end

-- `appId` (publisherid.projectid) for a SuiteApp project; --excludefiles is
-- only accepted for account customization projects.
function M.objectArgv(program: string, batch: ObjectBatch, appId: string?): { string }
	local argv = { program, "object:import", "--type", batch.type, "--scriptid" }
	table.move(batch.scriptIds, 1, #batch.scriptIds, #argv + 1, argv)
	table.insert(argv, "--destinationfolder")
	table.insert(argv, M.OBJECTS_FOLDER)
	if appId then
		table.insert(argv, "--appid")
		table.insert(argv, appId)
	else
		table.insert(argv, "--excludefiles")
	end
	return argv
end

function M.fileArgv(program: string, paths: { string }): { string }
	local argv = { program, "file:import", "--paths" }
	table.move(paths, 1, #paths, #argv + 1, argv)
	table.insert(argv, "--excludeproperties")
	return argv
end

function M.listArgv(program: string, appId: string?): { string }
	local argv = { program, "object:list" }
	if appId then
		table.insert(argv, "--appid")
		table.insert(argv, appId)
	end
	return argv
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

-- The CLI's "{0}:{1} failed: {2}." adds a period after the SDK message
-- ("... it is locked.." for a message that has one).
local function reason(s: string): string
	return (string.gsub(trim(s), "%.$", ""))
end

function M.parseObjectImport(stdout: string, stderr: string): Imported
	local r: Imported = { imported = {}, failed = {}, recognized = false }
	local section: string? = nil
	local batchReason: string? = nil
	for _, raw in Listing.split(stdout .. "\n" .. stderr) do
		local line = trim(raw)
		if line == "The following objects have been imported:" then
			section, r.recognized = "ok", true
		elseif line == "The following objects have not been imported:" then
			section, r.recognized = "failed", true
		elseif string.match(line, '^The following objects failed with reason "') then
			section, r.recognized = "batch", true
			batchReason = string.match(line, '^The following objects failed with reason "(.*)":$') or "unknown reason"
		elseif string.sub(line, 1, 2) == "- " and section then
			local item = string.sub(line, 3)
			if section == "ok" then
				local id = string.match(item, "^[%w_]+:([%w_%.%-]+)$")
				if id then
					r.imported[id] = true
				end
			elseif section == "failed" then
				local id, why = string.match(item, "^[%w_]+:([%w_%.%-]+) failed: (.*)$")
				if id and why then
					r.failed[id] = reason(why)
				end
			else
				local id = string.match(item, "^([%w_%.%-]+)$")
				if id then
					r.failed[id] = batchReason or "unknown reason"
				end
			end
		elseif line ~= "" then
			-- Item lines (referenced files too) start with "- "; anything else ends a section.
			section = nil
		end
	end
	return r
end

-- `asked`: the paths the command named, to split "<path>, <message>" when
-- a path contains ", ".
function M.parseFileImport(stdout: string, stderr: string, asked: { string }): Imported
	local r: Imported = { imported = {}, failed = {}, recognized = false }
	local section: string? = nil
	for _, raw in Listing.split(stdout .. "\n" .. stderr) do
		local line = trim(raw)
		if line == "The following files were imported:" then
			section, r.recognized = "ok", true
		elseif line == "The following files were not imported:" then
			section, r.recognized = "failed", true
		elseif section == "ok" and string.sub(line, 1, 1) == "/" then
			r.imported[line] = true
		elseif section == "failed" and string.sub(line, 1, 1) == "/" then
			local matched = false
			for _, p in asked do
				if string.sub(line, 1, #p + 2) == p .. ", " then
					r.failed[p] = string.sub(line, #p + 3)
					matched = true
					break
				end
			end
			if not matched then
				local p, why = string.match(line, "^(/.-), (.*)$")
				if p and why then
					r.failed[p] = why
				end
			end
		elseif line ~= "" then
			section = nil
		end
	end
	return r
end

function M.isMissing(why: string?): boolean
	if why == nil then
		return false
	end
	return string.find(why, M.MISSING_OBJECT, 1, true) == 1 or string.find(why, M.MISSING_FILE, 1, true) == 1
end

-- Why a command failed, in one line for the view.
function M.failure(
	status: number,
	stdout: string,
	stderr: string,
	timedOut: boolean,
	timeoutMs: number,
	authId: string
): string
	if string.find(stdout .. stderr, M.REAUTH_MARKER, 1, true) then
		return string.format(
			"the CLI wants a browser login for auth ID %s (its credentials expired); run a suitecloud command for it in a terminal, then press r",
			authId
		)
	end
	if timedOut then
		return string.format("timed out after %d s (suitecloud.timeout_ms)", math.floor(timeoutMs / 1000))
	end
	if status == CliSlot.BUSY_STATUS then
		local line = Listing.errorText(Listing.split(stderr))
		return (
			if line then string.gsub(line, "^tern%-netsuite: ", "") else "another SuiteCloud command holds this auth ID"
		)
	end
	return Listing.errorText(Listing.split(stderr .. "\n" .. stdout)) or ("exited " .. status .. " without output")
end

function M.unsafeScriptId(id: string): string?
	if #id > 128 or not string.find(id, "^[%w_][%w_%.%-]*$") then
		return "the script ID " .. CliSlot.printable(id) .. " is malformed"
	end
	return nil
end

-- Why a File Cabinet path cannot be passed to file:import, or nil.
function M.unsafePath(path: string): string?
	local why = CliSlot.unsafe(path)
	if why then
		return CliSlot.printable(path) .. " " .. why
	end
	if string.sub(path, 1, 1) ~= "/" or string.find(path, "//", 1, true) or #path > 1024 then
		return path .. " is not a plain absolute File Cabinet path"
	end
	for part in string.gmatch(path, "[^/]+") do
		if part == "." or part == ".." then
			return path .. " is not a plain absolute File Cabinet path"
		end
	end
	return nil
end

return table.freeze(M)
