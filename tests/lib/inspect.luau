--!strict
-- Deterministic value rendering and structural comparison for assertions.

local MAX_DEPTH = 6

local function isIdentifier(s: string): boolean
	return string.match(s, "^[%a_][%w_]*$") ~= nil
end

local function sortedKeys(t: { [any]: any }): { any }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: any, b: any): boolean
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function isSequence(t: { [any]: any }): boolean
	local n = 0
	for _ in t do
		n += 1
	end
	return n == #t
end

local function formatValue(value: any, depth: number, seen: { [any]: boolean }): string
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	end
	if kind ~= "table" then
		return tostring(value)
	end
	if seen[value] then
		return "<cycle>"
	end
	if depth >= MAX_DEPTH then
		return "{...}"
	end
	if next(value) == nil then
		return "{}"
	end
	seen[value] = true
	local parts = {}
	if isSequence(value) then
		for _, v in ipairs(value) do
			table.insert(parts, formatValue(v, depth + 1, seen))
		end
	else
		for _, k in sortedKeys(value) do
			local key = if type(k) == "string" and isIdentifier(k)
				then k
				else "[" .. formatValue(k, depth + 1, seen) .. "]"
			table.insert(parts, key .. " = " .. formatValue(value[k], depth + 1, seen))
		end
	end
	seen[value] = nil
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function format(value: any): string
	return formatValue(value, 0, {})
end

local function childPath(path: string, key: any): string
	if type(key) == "string" and isIdentifier(key) then
		return path .. "." .. key
	end
	return path .. "[" .. format(key) .. "]"
end

local function diff(actual: any, expected: any, path: string, seen: { [any]: any }): string?
	if actual == expected then
		return nil
	end
	if type(actual) ~= "table" or type(expected) ~= "table" then
		return path
	end
	if seen[actual] == expected then
		return nil
	end
	seen[actual] = expected
	for _, k in sortedKeys(expected) do
		local found = diff(actual[k], expected[k], childPath(path, k), seen)
		if found then
			return found
		end
	end
	for _, k in sortedKeys(actual) do
		if expected[k] == nil then
			return childPath(path, k)
		end
	end
	return nil
end

-- Returns the path of the first structural difference, or nil when equal.
local function firstDifference(actual: any, expected: any): string?
	return diff(actual, expected, "<root>", {})
end

return {
	format = format,
	firstDifference = firstDifference,
}
