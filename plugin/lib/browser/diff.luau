--!strict
-- What the account has against what the project has: each object (by
-- scriptid, case-insensitive like NetSuite) and File Cabinet file (by path,
-- within the folders that were listed) is in the account only, in both, or
-- local only. Plus the browser's filters over those entries.

local Listing = require("../sdf/listing")
local Project = require("../sdf/project")

type Project = Project.Project

export type Kind = "object" | "file"
export type Where = "account" | "both" | "local"
export type WhereFilter = Where | "all"

export type Entry = {
	kind: Kind,
	-- Scriptid, or File Cabinet path ("/SuiteScripts/x.js").
	id: string,
	-- Object type (account's spelling when both have it).
	type: string?,
	where: Where,
	-- The project's file, relative to its root.
	localPath: string?,
	-- File Cabinet paths a local object references (script files).
	fileReferences: { string }?,
}

export type Filter = {
	where: WhereFilter,
	-- nil: every type.
	type: string?,
	query: string,
}

export type Counts = { all: number, account: number, both: number, ["local"]: number }

local M = {}

M.DEFAULT_FOLDER = "/SuiteScripts"

local function sortEntries(entries: { Entry })
	table.sort(entries, function(a: Entry, b: Entry): boolean
		local ta, tb = string.lower(a.type or ""), string.lower(b.type or "")
		if ta ~= tb then
			return ta < tb
		end
		local ia, ib = string.lower(a.id), string.lower(b.id)
		if ia ~= ib then
			return ia < ib
		end
		return a.id < b.id
	end)
end

function M.objects(account: { Listing.Object }, project: Project): { Entry }
	local locals: { [string]: Project.SdfObject } = {}
	for _, o in project.objects do
		locals[string.lower(o.scriptId)] = o
	end
	local seen: { [string]: boolean } = {}
	local out: { Entry } = {}
	for _, a in account do
		local key = string.lower(a.scriptId)
		if seen[key] then
			continue
		end
		seen[key] = true
		local l = locals[key]
		local refs: { string }? = nil
		if l then
			refs = {}
			for _, r in l.fileReferences do
				table.insert(refs :: { string }, r.path)
			end
		end
		table.insert(out, {
			kind = "object",
			id = a.scriptId,
			type = a.type,
			where = if l then "both" else "account",
			localPath = if l then l.path else nil,
			fileReferences = refs,
		})
	end
	for key, l in locals do
		if not seen[key] then
			local refs: { string } = {}
			for _, r in l.fileReferences do
				table.insert(refs, r.path)
			end
			table.insert(out, {
				kind = "object",
				id = l.scriptId,
				type = l.type,
				where = "local",
				localPath = l.path,
				fileReferences = refs,
			})
		end
	end
	sortEntries(out)
	return out
end

-- The top File Cabinet folders the project ships files to ("/SuiteScripts").
function M.folders(project: Project): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, f in project.files do
		local top = string.match(f.fileCabinetPath, "^(/[^/]+)/")
		if top and not seen[top] then
			seen[top] = true
			table.insert(out, top)
		end
	end
	if #out == 0 then
		return { M.DEFAULT_FOLDER }
	end
	table.sort(out)
	return out
end

local function within(path: string, folders: { string }): boolean
	local lower = string.lower(path)
	for _, f in folders do
		local prefix = string.lower(f) .. "/"
		if string.sub(lower, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- Account files (every listed folder) against the project's files in them.
function M.files(account: { string }, folders: { string }, project: Project): { Entry }
	local locals: { [string]: Project.File } = {}
	for _, f in project.files do
		if within(f.fileCabinetPath, folders) then
			locals[string.lower(f.fileCabinetPath)] = f
		end
	end
	local seen: { [string]: boolean } = {}
	local out: { Entry } = {}
	for _, path in account do
		local key = string.lower(path)
		if seen[key] then
			continue
		end
		seen[key] = true
		local l = locals[key]
		table.insert(out, {
			kind = "file",
			id = path,
			where = if l then "both" else "account",
			localPath = if l then l.path else nil,
		})
	end
	for key, l in locals do
		if not seen[key] then
			table.insert(out, { kind = "file", id = l.fileCabinetPath, where = "local", localPath = l.path })
		end
	end
	sortEntries(out)
	return out
end

function M.counts(entries: { Entry }): Counts
	local c: Counts = { all = #entries, account = 0, both = 0, ["local"] = 0 }
	for _, e in entries do
		c[e.where] += 1
	end
	return c
end

-- Every type present, alphabetically (case-insensitive).
function M.types(entries: { Entry }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, e in entries do
		local ty = e.type
		if ty and not seen[ty] then
			seen[ty] = true
			table.insert(out, ty)
		end
	end
	table.sort(out, function(a: string, b: string): boolean
		return string.lower(a) < string.lower(b)
	end)
	return out
end

local function words(query: string): { string }
	local out: { string } = {}
	for w in string.gmatch(string.lower(query), "%S+") do
		table.insert(out, w)
	end
	return out
end

function M.apply(entries: { Entry }, f: Filter): { Entry }
	local terms = words(f.query)
	local out: { Entry } = {}
	for _, e in entries do
		if f.where ~= "all" and e.where ~= f.where then
			continue
		end
		if f.type and e.type ~= f.type then
			continue
		end
		local hay = string.lower(e.id .. " " .. (e.type or ""))
		local ok = true
		for _, w in terms do
			if not string.find(hay, w, 1, true) then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, e)
		end
	end
	return out
end

local WHERE_ORDER: { WhereFilter } = { "all", "account", "both", "local" }

function M.nextWhere(w: WhereFilter): WhereFilter
	local i = table.find(WHERE_ORDER, w) or 1
	return WHERE_ORDER[i % #WHERE_ORDER + 1]
end

-- The type after (step 1) or before (step -1) `current`; nil is "every type"
-- and sits between the last and the first.
function M.nextType(types: { string }, current: string?, step: number): string?
	if #types == 0 then
		return nil
	end
	if current == nil then
		return if step > 0 then types[1] else types[#types]
	end
	local i = table.find(types, current)
	if i == nil then
		return nil
	end
	local j = i + (if step > 0 then 1 else -1)
	return types[j]
end

return table.freeze(M)
