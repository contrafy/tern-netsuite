--!strict
-- Test-only JSON decoder mimicking `tern.json.decode`, so pure modules can be
-- fed the same tables they get in Tern:
--   * object members whose value is null are dropped;
--   * arrays decode to plain sequences (Tern's array tag is not observable here);
--   * null array items and a top-level null decode to the `null` sentinel
--     (stands in for `tern.json.null`; pass it to modules under test as their
--     injected null);
--   * all numbers decode to Luau numbers.
-- Malformed input raises an error naming the byte offset.

local null = table.freeze({})

local function decodeError(text: string, pos: number, what: string): never
	local near = string.sub(text, pos, pos + 15)
	error(string.format("json: %s at byte %d near %q", what, pos, near), 0)
end

local function skipWhitespace(text: string, pos: number): number
	local _, last = string.find(text, "^[ \t\r\n]*", pos)
	return (last :: number) + 1
end

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

local function parseString(text: string, pos: number): (string, number)
	local parts = {}
	local i = pos + 1
	while true do
		local chunkEnd = string.find(text, '["\\%c]', i)
		if not chunkEnd then
			return decodeError(text, pos, "unterminated string")
		end
		table.insert(parts, string.sub(text, i, chunkEnd - 1))
		local c = string.sub(text, chunkEnd, chunkEnd)
		if c == '"' then
			return table.concat(parts), chunkEnd + 1
		elseif c == "\\" then
			local e = string.sub(text, chunkEnd + 1, chunkEnd + 1)
			if e == "u" then
				local hex = string.match(text, "^%x%x%x%x", chunkEnd + 2)
				if not hex then
					return decodeError(text, chunkEnd, "invalid unicode escape")
				end
				local code = tonumber(hex, 16) :: number
				i = chunkEnd + 6
				if code >= 0xD800 and code <= 0xDBFF then
					local low = string.match(text, "^\\u(%x%x%x%x)", i)
					local lowCode = if low then tonumber(low, 16) :: number else 0
					if lowCode < 0xDC00 or lowCode > 0xDFFF then
						decodeError(text, chunkEnd, "unpaired surrogate")
					end
					code = 0x10000 + (code - 0xD800) * 0x400 + (lowCode - 0xDC00)
					i += 6
				elseif code >= 0xDC00 and code <= 0xDFFF then
					decodeError(text, chunkEnd, "unpaired surrogate")
				end
				table.insert(parts, utf8.char(code))
			else
				local replacement = ESCAPES[e]
				if not replacement then
					return decodeError(text, chunkEnd, "invalid escape")
				end
				table.insert(parts, replacement)
				i = chunkEnd + 2
			end
		else
			decodeError(text, chunkEnd, "control character in string")
		end
	end
end

local parseValue: (text: string, pos: number) -> (any, number)

-- Set while decodeTracking runs: records every decoded array so callers can
-- tell `[]` from `{}` the way Tern's array tag does.
local tracked: { [any]: true }? = nil

local function parseArray(text: string, pos: number): ({ any }, number)
	local result = {}
	if tracked then
		tracked[result] = true
	end
	local i = skipWhitespace(text, pos + 1)
	if string.sub(text, i, i) == "]" then
		return result, i + 1
	end
	while true do
		local value
		value, i = parseValue(text, i)
		table.insert(result, value)
		i = skipWhitespace(text, i)
		local c = string.sub(text, i, i)
		if c == "]" then
			return result, i + 1
		elseif c ~= "," then
			decodeError(text, i, "expected ',' or ']'")
		end
		i = skipWhitespace(text, i + 1)
	end
end

local function parseObject(text: string, pos: number): ({ [string]: any }, number)
	local result = {}
	local i = skipWhitespace(text, pos + 1)
	if string.sub(text, i, i) == "}" then
		return result, i + 1
	end
	while true do
		if string.sub(text, i, i) ~= '"' then
			decodeError(text, i, "expected object key")
		end
		local key
		key, i = parseString(text, i)
		i = skipWhitespace(text, i)
		if string.sub(text, i, i) ~= ":" then
			decodeError(text, i, "expected ':'")
		end
		local value
		value, i = parseValue(text, skipWhitespace(text, i + 1))
		if value ~= null then
			result[key] = value
		end
		i = skipWhitespace(text, i)
		local c = string.sub(text, i, i)
		if c == "}" then
			return result, i + 1
		elseif c ~= "," then
			decodeError(text, i, "expected ',' or '}'")
		end
		i = skipWhitespace(text, i + 1)
	end
end

local LITERALS: { [string]: any } = { ["true"] = true, ["false"] = false, ["null"] = null }

function parseValue(text: string, pos: number): (any, number)
	local c = string.sub(text, pos, pos)
	if c == "{" then
		return parseObject(text, pos)
	elseif c == "[" then
		return parseArray(text, pos)
	elseif c == '"' then
		return parseString(text, pos)
	end
	local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
	if number and string.match(number, "^-?0%d") == nil then
		local value = tonumber(number)
		if value then
			return value, pos + #number
		end
	end
	for word, value in LITERALS do
		if string.sub(text, pos, pos + #word - 1) == word then
			return value, pos + #word
		end
	end
	return decodeError(text, pos, "unexpected token")
end

local function decode(text: string): any
	local value, pos = parseValue(text, skipWhitespace(text, 1))
	pos = skipWhitespace(text, pos)
	if pos <= #text then
		decodeError(text, pos, "trailing data")
	end
	return value
end

local function decodeTracking(text: string): (any, { [any]: true })
	local arrays: { [any]: true } = {}
	tracked = arrays
	local ok, value = pcall(decode, text)
	tracked = nil
	if not ok then
		error(value, 0)
	end
	return value, arrays
end

return {
	decode = decode,
	decodeTracking = decodeTracking,
	null = null,
}
