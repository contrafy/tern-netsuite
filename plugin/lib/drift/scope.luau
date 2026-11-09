--!strict
-- Which account objects count as "account only" for a project: objects
-- `object:list` reports whose script id starts like one of the project's
-- own (the type prefix and the next word: customscript_acme_ from
-- customscript_acme_orders_ue) and that the project does not have. A
-- script id with fewer than two underscores is its own prefix. The list is
-- filtered here rather than with `object:list --scriptid`, which takes one
-- substring per command.

local Listing = require("../sdf/listing")

local M = {}

function M.prefix(scriptId: string): string
	local p = string.match(scriptId, "^([^_]*_[^_]*_)")
	return p or scriptId
end

-- Unique prefixes of `scriptIds`, sorted.
function M.prefixes(scriptIds: { string }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, id in scriptIds do
		local p = M.prefix(string.lower(id))
		if not seen[p] then
			seen[p] = true
			table.insert(out, p)
		end
	end
	table.sort(out)
	return out
end

local function matches(id: string, prefixes: { string }): boolean
	local lower = string.lower(id)
	for _, p in prefixes do
		if string.sub(lower, 1, #p) == p then
			return true
		end
	end
	return false
end

-- Listed objects under `prefixes` that `projectIds` (lowercase) lacks, in
-- the CLI's order.
function M.accountOnly(
	listed: { Listing.Object },
	prefixes: { string },
	projectIds: { [string]: boolean }
): { Listing.Object }
	local out: { Listing.Object } = {}
	for _, o in listed do
		if not projectIds[string.lower(o.scriptId)] and matches(o.scriptId, prefixes) then
			table.insert(out, o)
		end
	end
	return out
end

return table.freeze(M)
