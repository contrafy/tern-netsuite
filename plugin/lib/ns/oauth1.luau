--!strict
-- OAuth 1.0a request signing as NetSuite token-based authentication (TBA)
-- requires it: HMAC-SHA256 (HMAC-SHA1 support ended in 2023.1), the account
-- id as realm, and the query string (never a JSON body) in the base string.
-- The header layout matches requests-oauthlib's, so a request signed here
-- is byte-for-byte what a Python client using requests-oauthlib sends.

local Crypto = require("./crypto")
local Encoding = require("./encoding")

local M = {}

export type Credentials = {
	consumer_key: string,
	consumer_secret: string,
	token_id: string,
	token_secret: string,
}

export type Request = {
	method: string,
	url: string,
	-- The account id; normalized to NetSuite's realm spelling by the caller
	-- (lib/ns/endpoints.luau realm()).
	realm: string,
	credentials: Credentials,
	nonce: string,
	timestamp: number,
}

local function splitUrl(url: string): (string, string)
	local q = string.find(url, "?", 1, true)
	local base = if q then string.sub(url, 1, q - 1) else url
	local query = if q then string.sub(url, q + 1) else ""
	base = string.gsub(base, "#.*$", "")
	query = string.gsub(query, "#.*$", "")
	-- RFC 5849 3.4.1.2: scheme and host are lower case, default ports dropped.
	local s, a, p = string.match(base, "^(%a[%w+.-]*)://([^/]+)(.*)$")
	if s == nil or a == nil or p == nil then
		error(string.format("not an absolute URL: %q", url), 3)
	end
	local scheme: string = string.lower(s)
	local authority: string = string.lower(a)
	local path: string = p
	if
		(scheme == "https" and string.sub(authority, -4) == ":443")
		or (scheme == "http" and string.sub(authority, -3) == ":80")
	then
		authority = string.gsub(authority, ":%d+$", "")
	end
	if path == "" then
		path = "/"
	end
	return scheme .. "://" .. authority .. path, query
end

-- RFC 5849 section 3.4.1: the signature base string.
function M.baseString(method: string, url: string, oauth: { [string]: string }): string
	local base, query = splitUrl(url)
	local params: { { string } } = {}
	for part in string.gmatch(query, "[^&]+") do
		local eq = string.find(part, "=", 1, true)
		local name = if eq then string.sub(part, 1, eq - 1) else part
		local value = if eq then string.sub(part, eq + 1) else ""
		table.insert(
			params,
			{ Encoding.percent(Encoding.decode(name, true)), Encoding.percent(Encoding.decode(value, true)) }
		)
	end
	for name, value in oauth do
		table.insert(params, { Encoding.percent(name), Encoding.percent(value) })
	end
	table.sort(params, function(a: { string }, b: { string }): boolean
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	local joined = table.create(#params)
	for i, p in params do
		joined[i] = p[1] .. "=" .. p[2]
	end
	return string.upper(method) .. "&" .. Encoding.percent(base) .. "&" .. Encoding.percent(table.concat(joined, "&"))
end

-- The Authorization header value for `req`.
function M.header(req: Request): string
	local c = req.credentials
	local timestamp = string.format("%d", req.timestamp)
	local oauth = {
		oauth_consumer_key = c.consumer_key,
		oauth_nonce = req.nonce,
		oauth_signature_method = "HMAC-SHA256",
		oauth_timestamp = timestamp,
		oauth_token = c.token_id,
		oauth_version = "1.0",
	}
	local key = Encoding.percent(c.consumer_secret) .. "&" .. Encoding.percent(c.token_secret)
	local signature = Encoding.base64(Crypto.hmacSha256(key, M.baseString(req.method, req.url, oauth)))
	local fields = {
		{ "realm", req.realm },
		{ "oauth_nonce", req.nonce },
		{ "oauth_timestamp", timestamp },
		{ "oauth_version", "1.0" },
		{ "oauth_signature_method", "HMAC-SHA256" },
		{ "oauth_consumer_key", c.consumer_key },
		{ "oauth_token", c.token_id },
		{ "oauth_signature", signature },
	}
	local parts = table.create(#fields)
	for i, f in fields do
		parts[i] = string.format('%s="%s"', f[1], Encoding.percent(f[2]))
	end
	return "OAuth " .. table.concat(parts, ", ")
end

-- A nonce unique per (seed, counter): the adapter seeds it once per VM with
-- clock and PRNG entropy and counts requests. TBA nonces only need to be
-- unique per token and timestamp; they are not secrets.
function M.nonce(seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256(seed .. ":" .. tostring(counter))), 1, 32)
end

return M
