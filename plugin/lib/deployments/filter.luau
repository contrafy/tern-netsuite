--!strict
-- Filters of the deployments view: free text (every word must appear in
-- the deployment id, title, script id, script name or record type) and one
-- value each of script type, status and log level, cycled through the
-- values present in the loaded rows.

local Query = require("./query")

type Deployment = Query.Deployment

local M = {}

export type Facet = "type" | "status" | "level"

M.FACETS = table.freeze({ "type", "status", "level" } :: { Facet })

export type Filter = {
	text: string,
	words: { string },
	type: string?,
	status: string?,
	level: string?,
}

function M.new(): Filter
	return { text = "", words = {}, type = nil, status = nil, level = nil }
end

function M.withText(f: Filter, text: string): Filter
	local out = table.clone(f)
	out.text = text
	out.words = {}
	for w in string.gmatch(string.lower(text), "%S+") do
		table.insert(out.words, w)
	end
	return out
end

function M.value(d: Deployment, facet: Facet): string
	if facet == "type" then
		return d.scriptType or ""
	elseif facet == "status" then
		return if d.deployed == false then "NOT DEPLOYED" else d.status
	end
	return d.logLevel
end

function M.isEmpty(f: Filter): boolean
	return #f.words == 0 and f.type == nil and f.status == nil and f.level == nil
end

function M.matches(d: Deployment, f: Filter): boolean
	for _, facet in M.FACETS do
		local want = (f :: any)[facet]
		if want ~= nil and M.value(d, facet :: Facet) ~= want then
			return false
		end
	end
	if #f.words == 0 then
		return true
	end
	local hay =
		string.lower(table.concat({ d.scriptId, d.title, d.script or "", d.scriptName or "", d.recordType or "" }, " "))
	for _, w in f.words do
		if not string.find(hay, w, 1, true) then
			return false
		end
	end
	return true
end

-- The distinct values of `facet` in `rows`, sorted.
function M.values(rows: { Deployment }, facet: Facet): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, d in rows do
		local v = M.value(d, facet)
		if v ~= "" and not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	table.sort(out)
	return out
end

-- The value after `current` in `values`; nil (no filter) after the last.
function M.cycle(values: { string }, current: string?): string?
	if current == nil then
		return values[1]
	end
	local i = table.find(values, current)
	return if i then values[i + 1] else nil
end

return table.freeze(M)
