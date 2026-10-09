--!strict
local Encoding = require("../../../plugin/lib/ns/encoding")
local Endpoints = require("../../../plugin/lib/ns/endpoints")
local Oauth1 = require("../../../plugin/lib/ns/oauth1")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("percent and form encoding", function()
	it("leaves only RFC 3986 unreserved characters literal, as OAuth signatures require", function()
		expect(Encoding.percent("aZ09-._~")).toBe("aZ09-._~")
		expect(Encoding.percent("a b+c/d=e&f*g!")).toBe("a%20b%2Bc%2Fd%3De%26f%2Ag%21")
		expect(Encoding.percent("é")).toBe("%C3%A9")
	end)

	it("form-encodes token request fields the way NetSuite's token endpoint parses them", function()
		expect(Encoding.form({ { "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" } })).toBe(
			"client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"
		)
		expect(Encoding.form({ { "a", "x y*~" }, { "b", "" } })).toBe("a=x+y*%7E&b=")
	end)

	it("decodes escapes and, for form data, plus signs", function()
		expect(Encoding.decode("a+b%20c%2B")).toBe("a+b c+")
		expect(Encoding.decode("a+b%20c%2B", true)).toBe("a b c+")
	end)
end)

describe("base64", function()
	it("matches RFC 4648 test vectors", function()
		local cases = { "", "f", "fo", "foo", "foob", "fooba", "foobar" }
		local want = { "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy" }
		for i, s in cases do
			expect(Encoding.base64(s)).toBe(want[i])
		end
	end)

	it("produces unpadded URL-safe segments for JWTs, also from openssl's wrapped output", function()
		expect(Encoding.base64url(string.char(0xfb, 0xff, 0xbf))).toBe("-_-_")
		expect(Encoding.base64url("fo")).toBe("Zm8")
		expect(Encoding.toBase64Url("ab+/\ncd==\n")).toBe("ab-_cd")
	end)
end)

describe("account endpoints", function()
	it("spells the realm upper case with an underscore and the host lower case with a dash", function()
		expect(Endpoints.realm("1234567_sb1")).toBe("1234567_SB1")
		expect(Endpoints.realm("1234567-SB1")).toBe("1234567_SB1")
		expect(Endpoints.host("1234567_SB1")).toBe("1234567-sb1")
		expect(Endpoints.host("1234567")).toBe("1234567")
	end)

	it("builds the REST SuiteQL, RESTlet and token URLs on the account's own host", function()
		expect(Endpoints.suiteql("1234567_SB1", 1000, 2000)).toBe(
			"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=1000&offset=2000"
		)
		expect(Endpoints.restlet("1234567_SB1", "customscript_x", "customdeploy_x")).toBe(
			"https://1234567-sb1.restlets.api.netsuite.com/app/site/hosting/restlet.nl?script=customscript_x&deploy=customdeploy_x"
		)
		expect(Endpoints.token("TSTDRV1234567")).toBe(
			"https://tstdrv1234567.suitetalk.api.netsuite.com/services/rest/auth/oauth2/v1/token"
		)
	end)

	it("refuses account ids that could redirect a signed request to another host", function()
		expect(Endpoints.valid("1234567_SB1")).toBe(true)
		expect(Endpoints.valid("evil.example.com/x")).toBe(false)
		expect(Endpoints.valid("1234567@evil")).toBe(false)
		expect(Endpoints.valid("")).toBe(false)
		expect(function()
			Endpoints.host("a.b")
		end).toThrow("invalid NetSuite account id")
	end)
end)

describe("OAuth 1.0a TBA signing", function()
	local ref = json.decode(fixtures.read("ns/oauth1/reference.json"))

	it("reproduces the signature in NetSuite's own documentation example", function()
		local base =
			Oauth1.baseString("GET", "https://123456.suitetalk.api.netsuite.com/services/rest/record/v1/employee/40", {
				oauth_consumer_key = ref.credentials.consumer_key,
				oauth_nonce = "fjaLirsIcCGVZWzBX0pg",
				oauth_signature_method = "HMAC-SHA256",
				oauth_timestamp = "1508242306",
				oauth_token = ref.credentials.token_id,
				oauth_version = "1.0",
			})
		expect(base).toBe(
			"GET&https%3A%2F%2F123456.suitetalk.api.netsuite.com%2Fservices%2Frest%2Frecord%2Fv1%2Femployee%2F40&"
				.. "oauth_consumer_key%3Def40afdd8abaac111b13825dd5e5e2ddddb44f86d5a0dd6dcf38c20aae6b67e4%26"
				.. "oauth_nonce%3DfjaLirsIcCGVZWzBX0pg%26oauth_signature_method%3DHMAC-SHA256%26"
				.. "oauth_timestamp%3D1508242306%26"
				.. "oauth_token%3D2b0ce516420110bcbd36b69e99196d1b7f6de3c6234c5afb799b73d87569f5cc%26oauth_version%3D1.0"
		)
	end)

	it("includes RESTlet query parameters in the base string, sorted, as NetSuite verifies them", function()
		local base = Oauth1.baseString(
			"post",
			"https://123456.restlets.api.netsuite.com/app/site/hosting/restlet.nl?script=6&deploy=1&customParam=someValue&testParam=someOtherValue",
			{
				oauth_consumer_key = ref.credentials.consumer_key,
				oauth_nonce = "fjaLirsIcCGVZWzBX0pg",
				oauth_signature_method = "HMAC-SHA256",
				oauth_timestamp = "1508242306",
				oauth_token = ref.credentials.token_id,
				oauth_version = "1.0",
			}
		)
		expect(base).toBe(
			"POST&https%3A%2F%2F123456.restlets.api.netsuite.com%2Fapp%2Fsite%2Fhosting%2Frestlet.nl&"
				.. "customParam%3DsomeValue%26deploy%3D1%26"
				.. "oauth_consumer_key%3Def40afdd8abaac111b13825dd5e5e2ddddb44f86d5a0dd6dcf38c20aae6b67e4%26"
				.. "oauth_nonce%3DfjaLirsIcCGVZWzBX0pg%26oauth_signature_method%3DHMAC-SHA256%26"
				.. "oauth_timestamp%3D1508242306%26"
				.. "oauth_token%3D2b0ce516420110bcbd36b69e99196d1b7f6de3c6234c5afb799b73d87569f5cc%26"
				.. "oauth_version%3D1.0%26script%3D6%26testParam%3DsomeOtherValue"
		)
	end)

	it("produces exactly the Authorization header a Python client (requests-oauthlib) sends", function()
		for _, case in ref.cases do
			local header = Oauth1.header({
				method = case.method,
				url = case.url,
				realm = case.realm,
				credentials = ref.credentials,
				nonce = case.nonce,
				timestamp = case.timestamp,
			})
			expect(header).toBe(case.authorization)
		end
	end)

	it("never reuses a nonce within a VM, so NetSuite does not reject a replay", function()
		local seen: { [string]: boolean } = {}
		for i = 1, 200 do
			local n = Oauth1.nonce("seed", i)
			expect(seen[n]).toBeNil()
			seen[n] = true
			expect(#n).toBe(32)
		end
		expect(Oauth1.nonce("a", 1) == Oauth1.nonce("b", 1)).toBe(false)
	end)
end)

return nil
