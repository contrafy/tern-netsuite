--!strict
local Credentials = require("../../../plugin/lib/ns/credentials")
local Encoding = require("../../../plugin/lib/ns/encoding")
local Oauth2 = require("../../../plugin/lib/ns/oauth2")
local Spool = require("../../../plugin/lib/ns/spool")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local B64URL: { [string]: number } = {}
for i = 1, 64 do
	B64URL[string.sub("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", i, i)] = i - 1
end

local function unb64url(s: string): string
	local out, bits, n = {}, 0, 0
	for i = 1, #s do
		bits = bits * 64 + B64URL[string.sub(s, i, i)]
		n += 6
		if n >= 8 then
			n -= 8
			table.insert(out, string.char(math.floor(bits / 2 ^ n) % 256))
			bits %= 2 ^ n
		end
	end
	return table.concat(out)
end

describe("OAuth 2.0 client credentials assertions", function()
	local claims = Oauth2.claims({ client_id = "client-123", account_id = "1234567_SB1", now = 1791500000, jti = "j1" })

	it("addresses the account's token endpoint and stays well inside NetSuite's 60-minute limit", function()
		expect(claims.aud).toBe("https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/auth/oauth2/v1/token")
		expect(claims.iss).toBe("client-123")
		expect(claims.scope).toEqual({ "restlets", "rest_webservices" })
		expect(claims.exp - claims.iat <= 3600).toBe(true)
		expect(claims.exp > claims.iat).toBe(true)
	end)

	it("signs a PS256 header naming the certificate id, in base64url segments", function()
		local input = Oauth2.signingInput("cert-abc", claims)
		local head, body = string.match(input, "^([%w%-_]+)%.([%w%-_]+)$")
		assert(head and body, "not a two-segment signing input")
		expect(json.decode(unb64url(head))).toEqual({ alg = "PS256", typ = "JWT", kid = "cert-abc" })
		expect(json.decode(unb64url(body)).jti).toBe("j1")
		local jwt = Oauth2.assertion(input, "ab+/cd==\n")
		expect(jwt).toBe(input .. ".ab-_cd")
	end)

	it("posts the assertion form-encoded, as the token endpoint requires", function()
		local req = Oauth2.tokenRequest("1234567_SB1", "h.p.s")
		expect(req.headers["Content-Type"]).toBe("application/x-www-form-urlencoded")
		expect(req.body).toBe(
			"grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=h.p.s"
		)
	end)

	it("never puts the private key on the command line", function()
		local argv = Oauth2.signArgv("/data/ns/x.jwt")
		for _, a in argv do
			expect((string.find(a, "PRIVATE KEY", 1, true))).toBeNil()
		end
		expect(argv[#argv]).toBe("/data/ns/x.jwt")
	end)
end)

describe("access token cache", function()
	it("keeps a token until shortly before it expires", function()
		local tok = Oauth2.parseToken(
			{ status = 200, body = '{"access_token":"tok","expires_in":"3600","token_type":"Bearer"}' },
			json.decode,
			1000
		)
		assert(tok, "no token")
		expect(tok.expires_at).toBe(4600)
		expect(Oauth2.fresh(tok, 1000)).toBe(true)
		expect(Oauth2.fresh(tok, 4600 - Oauth2.RENEW_MARGIN)).toBe(false)
		expect(Oauth2.fresh(nil, 0)).toBe(false)
	end)

	it("reports token refusals as authentication errors", function()
		local tok, e = Oauth2.parseToken(
			{ status = 400, body = fixtures.read("ns/errors/token-400-invalid-grant.json") },
			json.decode,
			0
		)
		expect(tok).toBeNil()
		expect(e and e.kind).toBe("auth")
		local _, missing = Oauth2.parseToken({ status = 200, body = "{}" }, json.decode, 0)
		expect(missing and missing.kind).toBe("auth")
	end)
end)

describe("host-window spool protocol", function()
	local id = "0123456789abcdef0123"

	it("puts only the random id in links, never SQL or credentials", function()
		local link = Spool.link("query", id)
		expect(link).toBe("tern-netsuite://ns/query?id=" .. id)
		local action, got = Spool.parseLink(link)
		expect(action).toBe("query")
		expect(got).toBe(id)
	end)

	it("rejects links it did not produce", function()
		expect((Spool.parseLink("tern-netsuite://ns/query?id=../../etc"))).toBeNil()
		expect((Spool.parseLink("tern-netsuite://ns/drop?id=" .. id))).toBeNil()
		expect((Spool.parseLink("tern-netsuite://ns/query?id=abc"))).toBeNil()
		expect((Spool.parseLink("tern-netsuite://ns/query?id=" .. id .. "&sql=x"))).toBeNil()
	end)

	it("writes files with umask 077 and an atomic rename, secrets on stdin only", function()
		local argv = Spool.writeArgv("/d/ns", Spool.path("/d/ns", "cred", id))
		expect(argv[3]).toContain("umask 077")
		expect(argv[3]).toContain("mv -f")
		expect(argv[#argv]).toBe("/d/ns/" .. id .. ".cred.json")
	end)

	it("refuses stale or mismatched requests, so a leftover file is never replayed", function()
		local text = Encoding.json({ v = 1, id = id, connection = "c", sql = "SELECT 1 FROM DUAL", at = 1000 })
		expect((Spool.decodeQuery(text, id, 1010, json.decode))).toEqual({
			v = 1,
			id = id,
			connection = "c",
			sql = "SELECT 1 FROM DUAL",
			params = {},
			max_rows = nil,
			at = 1000,
		})
		local _, stale = Spool.decodeQuery(text, id, 1000 + Spool.STALE_SECONDS + 1, json.decode)
		expect(stale).toContain("stale")
		local _, other = Spool.decodeQuery(text, "fedcba9876543210fedc", 1010, json.decode)
		expect(other).toContain("does not belong")
	end)

	it("turns an unreadable answer into a server error rather than empty rows", function()
		local r = Spool.decodeResponse("not json", id, json.decode)
		expect(r.ok).toBe(false)
		expect(r.error and r.error.kind).toBe("server")
	end)

	it("shrinks an oversized answer by dropping rows and marking it truncated", function()
		local rows = {}
		for i = 1, 1000 do
			rows[i] = { id = i, title = string.rep("x", 100) }
		end
		local resp = { v = 1, id = id, ok = true, rows = rows, truncated = false }
		local fitted, text = Spool.fit(resp, Encoding.json, 20000)
		expect(#text <= 20000).toBe(true)
		expect(fitted.truncated).toBe(true)
		expect(#(fitted.rows :: { any }) < 1000).toBe(true)
		expect(#rows).toBe(1000)
	end)
end)

describe("credential handling", function()
	it("names keychain entries <connection-id>.<field>", function()
		expect(Credentials.secretName("sandbox-restlet", "token_secret")).toBe("sandbox-restlet.token_secret")
		expect(Credentials.secretName("Sandbox", "token_secret")).toBeNil()
		expect(Credentials.unstorable("Sandbox", "tba")).toContain("lower-case")
		expect(Credentials.unstorable("sandbox", "tba")).toBeNil()
	end)

	it("requires every field and reports the field, never the value", function()
		local values = { consumer_key = " ck ", consumer_secret = "cs", token_id = "ti", token_secret = "" }
		local out, err = Credentials.validate("tba", values)
		expect(out).toBeNil()
		expect(err).toBe("Token secret is empty")
		values.token_secret = "ts-secret value"
		local _, spaced = Credentials.validate("tba", values)
		expect(spaced).toContain("Token secret")
		expect((string.find(spaced or "", "ts-secret", 1, true))).toBeNil()
		values.token_secret = "ts"
		local ok = Credentials.validate("tba", values)
		expect(ok and ok.consumer_key).toBe("ck")
	end)

	it("accepts a pasted PEM key for machine-to-machine connections", function()
		local pem = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----"
		local ok = Credentials.validate("oauth2_m2m", { client_id = "c", certificate_id = "k", private_key = pem })
		expect(ok and ok.private_key).toBe(pem .. "\n")
		local _, bad = Credentials.validate("oauth2_m2m", { client_id = "c", certificate_id = "k", private_key = "x" })
		expect(bad).toContain("PEM")
	end)

	it("masks typed values by length only", function()
		expect(Credentials.mask("abcd")).toBe("••••")
		expect(Credentials.mask(string.rep("a", 64))).toBe("•••••••• (64 characters)")
	end)
end)

return nil
