--!strict
-- NetSuite OAuth 2.0 client credentials (machine-to-machine) flow: a JWT
-- client assertion signed with the private key of the certificate mapped to
-- the integration, exchanged at the account's token endpoint for a bearer
-- access token (valid 60 minutes). NetSuite accepts PS256/384/512 and
-- ES256/384/512 assertions; this client signs PS256 (RSA-PSS, SHA-256, salt
-- length 32) with `openssl` in the adapter, since Luau has no RSA.

local Encoding = require("./encoding")
local Endpoints = require("./endpoints")
local Errors = require("./errors")
local Transport = require("./transport")

local M = {}

type NsError = Errors.NsError
type HttpRequest = Transport.HttpRequest

export type Credentials = {
	client_id: string,
	certificate_id: string,
	-- PEM private key of the mapped certificate.
	private_key: string,
}

export type Token = {
	access_token: string,
	-- os.time() seconds.
	expires_at: number,
}

M.ALG = "PS256"
M.SCOPES = { "restlets", "rest_webservices" }
-- The assertion only has to survive the token request; NetSuite rejects
-- exp more than 60 minutes after iat.
M.ASSERTION_TTL = 300
-- Tokens are renewed this long before they expire, so a query never starts
-- with a token that lapses in flight.
M.RENEW_MARGIN = 120

export type ClaimsInput = {
	client_id: string,
	account_id: string,
	-- os.time() seconds.
	now: number,
	-- Unique per assertion.
	jti: string,
}

function M.claims(input: ClaimsInput): { [string]: any }
	return {
		iss = input.client_id,
		scope = table.clone(M.SCOPES),
		aud = Endpoints.token(input.account_id),
		iat = input.now,
		exp = input.now + M.ASSERTION_TTL,
		jti = input.jti,
	}
end

-- `base64url(header).base64url(claims)`, the bytes the key signs.
function M.signingInput(certificateId: string, claims: { [string]: any }): string
	local header = { alg = M.ALG, typ = "JWT", kid = certificateId }
	return Encoding.base64url(Encoding.json(header)) .. "." .. Encoding.base64url(Encoding.json(claims))
end

-- The compact JWT from the signing input and the signature as standard
-- base64 (what `openssl base64 -A` prints).
function M.assertion(signingInput: string, signatureBase64: string): string
	return signingInput .. "." .. Encoding.toBase64Url(signatureBase64)
end

-- argv that signs the file at `inputPath` with a PEM key read from stdin
-- and prints the signature as one line of base64. The key never touches
-- the disk or the process list.
function M.signArgv(inputPath: string): { string }
	return {
		"/bin/sh",
		"-c",
		'openssl dgst -sha256 -sign /dev/stdin -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 "$1" '
			.. "| openssl base64 -A",
		"sh",
		inputPath,
	}
end

function M.tokenRequest(accountId: string, assertion: string): HttpRequest
	return {
		method = "POST",
		url = Endpoints.token(accountId),
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
			Accept = "application/json",
		},
		body = Encoding.form({
			{ "grant_type", "client_credentials" },
			{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
			{ "client_assertion", assertion },
		}),
	}
end

-- The token in a token endpoint answer received at `now` (os.time seconds).
function M.parseToken(res: Errors.HttpResult, decode: (string) -> any, now: number): (Token?, NsError?)
	local err = Errors.fromHttp(res, decode)
	if err then
		-- Every token endpoint refusal (bad assertion, unknown kid, revoked
		-- mapping) is an authentication problem, whatever its status.
		if err.kind ~= "network" and err.kind ~= "rate_limit" and err.kind ~= "server" then
			return nil, Errors.new("auth", err.message, err.code, err.status)
		end
		return nil, err
	end
	local ok, doc = pcall(decode, res.body)
	local token = if ok and type(doc) == "table" then doc.access_token else nil
	if type(token) ~= "string" or token == "" then
		return nil,
			Errors.new("auth", "the token endpoint answered without an access token", Errors.BAD_RESPONSE, res.status)
	end
	local ttl = tonumber(doc.expires_in) or 3600
	return { access_token = token, expires_at = now + ttl }, nil
end

-- Whether `token` can still be used at `now`.
function M.fresh(token: Token?, now: number): boolean
	return token ~= nil and token.expires_at - M.RENEW_MARGIN > now
end

return M
