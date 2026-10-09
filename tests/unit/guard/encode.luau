--!strict
-- Minimal JSON encoder for the guard specs (tests/lib/json.luau only
-- decodes): builds request files the way the shell guard writes them.

local function quote(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			if c == '"' then
				return '\\"'
			elseif c == "\\" then
				return "\\\\"
			elseif c == "\n" then
				return "\\n"
			end
			return string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function encode(v: any): string
	local tv = type(v)
	if tv == "string" then
		return quote(v)
	elseif tv == "number" then
		return if v == math.floor(v) then string.format("%d", v) else tostring(v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "table" then
		if #v > 0 or next(v) == nil then
			local parts: { string } = {}
			for i, item in ipairs(v) do
				parts[i] = encode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys: { string } = {}
		for k in v do
			table.insert(keys, k)
		end
		table.sort(keys)
		local parts: { string } = {}
		for i, k in keys do
			parts[i] = quote(k) .. ":" .. encode(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("encode: unsupported " .. tv)
end

return encode
