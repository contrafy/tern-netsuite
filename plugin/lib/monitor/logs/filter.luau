--!strict
-- The text filter of the log tail. Whitespace-separated terms, all required,
-- case-insensitive, matched as plain text:
--   ns:<prefix>      title namespace starts with <prefix>
--   script:<text>    script id or name contains <text>, or numeric id equals it
--   anything else    title or detail contains it

local Entry = require("./entry")

local M = {}

export type Filter = {
	words: { string },
	ns: { string },
	scripts: { string },
}

function M.parse(text: string): Filter
	local f: Filter = { words = {}, ns = {}, scripts = {} }
	for term in string.gmatch(string.lower(text), "%S+") do
		local ns = string.match(term, "^ns:(.+)$")
		local script = string.match(term, "^script:(.+)$")
		if ns then
			table.insert(f.ns, ns)
		elseif script then
			table.insert(f.scripts, script)
		else
			table.insert(f.words, term)
		end
	end
	return f
end

function M.isEmpty(f: Filter): boolean
	return #f.words == 0 and #f.ns == 0 and #f.scripts == 0
end

local function scriptMatches(e: Entry.Entry, want: string): boolean
	if e.script and string.format("%d", e.script) == want then
		return true
	end
	if e.scriptId and string.find(e.scriptId, want, 1, true) then
		return true
	end
	return e.scriptName ~= nil and string.find(string.lower(e.scriptName), want, 1, true) ~= nil
end

-- Whether `e` passes `f` at minimum level rank `minRank`.
function M.matches(e: Entry.Entry, f: Filter, minRank: number): boolean
	if e.rank < minRank then
		return false
	end
	for _, w in f.words do
		if not string.find(e.hay, w, 1, true) then
			return false
		end
	end
	for _, prefix in f.ns do
		local ns = e.namespace
		if ns == nil or string.sub(string.lower(ns), 1, #prefix) ~= prefix then
			return false
		end
	end
	for _, s in f.scripts do
		if not scriptMatches(e, s) then
			return false
		end
	end
	return true
end

return M
