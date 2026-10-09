--!strict
-- Byte-level encodings NetSuite's auth schemes need: RFC 3986 percent
-- encoding (OAuth 1.0a signature base strings), HTML form encoding (OAuth 2.0
-- token requests) and base64 / base64url (signatures, JWT segments).

local M = {}

local function hexByte(c: string): string
	return string.format("%%%02X", string.byte(c))
end

-- RFC 3986 section 2.3: everything but ALPHA / DIGIT / "-" / "." / "_" / "~"
-- is encoded, as OAuth 1.0a (RFC 5849 section 3.6) requires.
function M.percent(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", hexByte))
end

-- Decodes %XX escapes; `plus` also turns "+" into a space (form encoding).
function M.decode(s: string, plus: boolean?): string
	if plus then
		s = string.gsub(s, "+", " ")
	end
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

-- application/x-www-form-urlencoded (URL spec 5.1 serializer): space is "+",
-- only ALPHA / DIGIT / "*-._" stay literal.
function M.form(pairs: { { string } }): string
	local parts = table.create(#pairs)
	for i, p in pairs do
		local function enc(s: string): string
			return (string.gsub(string.gsub(s, "[^%w%*%-%._ ]", hexByte), " ", "+"))
		end
		parts[i] = enc(p[1]) .. "=" .. enc(p[2])
	end
	return table.concat(parts, "&")
end

-- A URL query string, each name and value percent-encoded.
function M.query(pairs: { { string } }): string
	local parts = table.create(#pairs)
	for i, p in pairs do
		parts[i] = M.percent(p[1]) .. "=" .. M.percent(p[2])
	end
	return table.concat(parts, "&")
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local SYMBOLS: { string } = {}
for i = 1, 64 do
	SYMBOLS[i - 1] = string.sub(ALPHABET, i, i)
end

-- Standard base64 with padding.
function M.base64(bytes: string): string
	local out = table.create(math.ceil(#bytes / 3) * 4)
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		table.insert(out, SYMBOLS[bit32.extract(n, 18, 6)])
		table.insert(out, SYMBOLS[bit32.extract(n, 12, 6)])
		table.insert(out, if b then SYMBOLS[bit32.extract(n, 6, 6)] else "=")
		table.insert(out, if c then SYMBOLS[bit32.extract(n, 0, 6)] else "=")
	end
	return table.concat(out)
end

-- Converts standard base64 (as `openssl base64` prints it) to unpadded
-- base64url (RFC 4648 section 5), the JWT segment encoding.
function M.toBase64Url(b64: string): string
	local s = string.gsub(b64, "%s", "")
	s = string.gsub(s, "=+$", "")
	s = string.gsub(s, "[+/]", { ["+"] = "-", ["/"] = "_" })
	return s
end

-- Unpadded base64url of `bytes`.
function M.base64url(bytes: string): string
	return M.toBase64Url(M.base64(bytes))
end

local JSON_ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function jsonString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return JSON_ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

-- Deterministic JSON for request bodies and JWT segments: object keys sorted,
-- a table with no string keys is an array (an empty table is `[]`). lib/ is
-- pure (no tern.json), and a fixed key order keeps signatures reproducible.
function M.json(value: any): string
	local tv = type(value)
	if tv == "string" then
		return jsonString(value)
	elseif tv == "boolean" then
		return if value then "true" else "false"
	elseif tv == "number" then
		if value ~= value or math.abs(value) == math.huge then
			error("cannot encode a non-finite number as JSON", 2)
		end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	elseif tv == "nil" then
		return "null"
	elseif tv == "table" then
		local keys: { string } = {}
		for k in value do
			if type(k) == "string" then
				table.insert(keys, k)
			end
		end
		if #keys == 0 then
			local parts = table.create(#value)
			for i, v in ipairs(value) do
				parts[i] = M.json(v)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		table.sort(keys)
		local parts = table.create(#keys)
		for i, k in keys do
			parts[i] = jsonString(k) .. ":" .. M.json(value[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot encode a " .. tv .. " as JSON", 2)
end

return M
