--!strict
-- The last complete drift result per project root and auth ID, kept as one
-- JSON file under the plugin's data directory so reopening the block shows
-- it (with its time) without running the CLI. `decode` rebuilds a Result
-- from plain JSON fields only and refuses anything else.

local Compare = require("./compare")
local Crypto = require("../ns/crypto")
local Snapshot = require("../sdf/snapshot")

type Entry = Compare.Entry

export type Result = {
	root: string,
	authId: string,
	-- Account id or label shown with the result, and whether it is production.
	account: string?,
	production: boolean,
	-- os.time() when the run finished.
	at: number,
	objects: { Entry },
	files: { Entry },
	-- Account-only objects; nil until listed.
	accountOnly: { Entry }?,
	-- Run-level notes (skipped steps, scan limits).
	problems: { string },
}

local M = {}

M.VERSION = 1
M.DIR = "drift/cache"

function M.fileName(root: string, authId: string): string
	return string.sub(Crypto.hex(Crypto.sha256(root .. "\n" .. authId)), 1, 32) .. ".json"
end

-- The project root with symlinks resolved, so one project has one cache
-- however its directory was reached (macOS /tmp is /private/tmp). Scan
-- files carry `real` when their resolved path differs: every file under a
-- symlinked ancestor, and files symlinked in from elsewhere. The root most
-- files agree on wins; files symlinked in are the minority.
function M.resolvedRoot(root: string, files: { Snapshot.SnapshotFile }): string
	local votes: { [string]: number } = {}
	local best, bestVotes = root, 0
	for _, f in files do
		local real = f.real
		local tail = "/" .. f.path
		local r = if real == nil
			then root
			elseif #real > #tail and string.sub(real, -#tail) == tail then string.sub(real, 1, #real - #tail)
			else nil
		if r then
			local n = (votes[r] or 0) + 1
			votes[r] = n
			if n > bestVotes then
				best, bestVotes = r, n
			end
		end
	end
	return best
end

local STATUSES: { [string]: boolean } =
	{ pending = true, identical = true, changed = true, missing = true, account = true, error = true }

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function entries(v: any, kind: string?): { Entry }?
	if type(v) ~= "table" then
		return nil
	end
	local out: { Entry } = {}
	for _, raw in v do
		if type(raw) ~= "table" then
			return nil
		end
		local k = str(raw.kind)
		local id, status = str(raw.id), str(raw.status)
		if
			(k ~= "object" and k ~= "file")
			or (kind and k ~= kind)
			or id == nil
			or status == nil
			or not STATUSES[status]
		then
			return nil
		end
		table.insert(out, {
			kind = k :: any,
			id = id,
			type = str(raw.type),
			localPath = str(raw.localPath),
			status = status :: any,
			note = str(raw.note),
			diff = str(raw.diff),
			truncated = if raw.truncated == true then true else nil,
		})
	end
	return out
end

function M.encode(r: Result): any
	return {
		v = M.VERSION,
		root = r.root,
		authId = r.authId,
		account = r.account,
		production = r.production,
		at = r.at,
		objects = r.objects,
		files = r.files,
		accountOnly = r.accountOnly,
		problems = r.problems,
	}
end

-- The cached result for `root` and `authId`, or nil when `v` is anything
-- else (another version, another project, malformed).
function M.decode(v: any, root: string, authId: string): Result?
	if type(v) ~= "table" or v.v ~= M.VERSION or v.root ~= root or v.authId ~= authId or type(v.at) ~= "number" then
		return nil
	end
	local objects, files = entries(v.objects, "object"), entries(v.files, "file")
	if objects == nil or files == nil then
		return nil
	end
	local accountOnly: { Entry }? = nil
	if v.accountOnly ~= nil then
		accountOnly = entries(v.accountOnly, "object")
		if accountOnly == nil then
			return nil
		end
	end
	local problems: { string } = {}
	if type(v.problems) == "table" then
		for _, p in v.problems do
			if type(p) == "string" then
				table.insert(problems, p)
			end
		end
	end
	return {
		root = root,
		authId = authId,
		account = str(v.account),
		production = v.production ~= false,
		at = v.at,
		objects = objects,
		files = files,
		accountOnly = accountOnly,
		problems = problems,
	}
end

return table.freeze(M)
