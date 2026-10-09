--!strict
local Manageauth = require("../../../plugin/lib/account/manageauth")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("manageauth --list", function()
	local entries = Manageauth.parseList(fixtures.lines("suitecloud/manageauth/list.txt")) :: { Manageauth.Entry }

	it("lists every auth id, even with the spinner's escape codes in front of the first one", function()
		expect(entries ~= nil).toBe(true)
		expect(#entries).toBe(2)
		expect(entries[1].authId).toBe("demo-prod")
		expect(entries[2].authId).toBe("demo-sb")
	end)

	it("splits role and company, which the CLI joins with @", function()
		expect(entries[1].role).toBe("Example : Developer")
		expect(entries[1].accountName).toBe("Example Corp")
		expect(entries[2].role).toBe("Administrator")
	end)

	it("derives the sandbox account id from its account-specific domain", function()
		expect(entries[2].domain).toBe("1234567-sb1.app.netsuite.com")
		expect(entries[2].accountId).toBe("1234567_SB1")
		expect(entries[2].kind).toBe("Sandbox")
	end)

	it("leaves the account of a production auth id unknown: the CLI prints no domain for it", function()
		expect(entries[1].domain).toBeNil()
		expect(entries[1].accountId).toBeNil()
		expect(entries[1].kind).toBeNil()
	end)

	it("keeps a domain that names no account without inventing an account id", function()
		local e = Manageauth.parseList({ "x | Admin @ Co | system.eu2.netsuite.com" }) :: { Manageauth.Entry }
		expect(e[1].domain).toBe("system.eu2.netsuite.com")
		expect(e[1].accountId).toBeNil()
	end)

	it("returns nil for output that is not a list, so the caller shows it raw", function()
		expect(Manageauth.parseList(fixtures.lines("suitecloud/manageauth/info-missing.txt"))).toBeNil()
		expect(Manageauth.parseList({})).toBeNil()
	end)
end)

describe("manageauth --info", function()
	it("reads every field of a sandbox auth id", function()
		local info = Manageauth.parseInfo(fixtures.lines("suitecloud/manageauth/info-sandbox.txt")) :: Manageauth.Info
		expect(info).toEqual({
			authId = "demo-sb",
			accountName = "Example Corp",
			accountId = "1234567_SB1",
			role = "Administrator",
			domain = "1234567-sb1.app.netsuite.com",
			kind = "Sandbox",
		})
	end)

	it("returns nil for an unknown auth id's error, so it is never mistaken for an account", function()
		expect(Manageauth.parseInfo(fixtures.lines("suitecloud/manageauth/info-missing.txt"))).toBeNil()
	end)

	it("extracts the CLI's reason from an error so the doctor can show it", function()
		expect(Manageauth.errorText(fixtures.lines("suitecloud/manageauth/info-missing.txt"))).toBe(
			'The "demo-missing" authentication ID is not available. Check your authentication credentials and try again.'
		)
	end)

	it("upper-cases the account id, as config and classification compare them", function()
		local info = Manageauth.parseInfo({ "Authentication ID: a", "Account ID: 1234567_sb2" }) :: Manageauth.Info
		expect(info.accountId).toBe("1234567_SB2")
	end)
end)

describe("account ids from domains", function()
	it("maps hyphens back to underscores", function()
		expect(Manageauth.accountFromDomain("1234567-rp.app.netsuite.com")).toBe("1234567_RP")
		expect(Manageauth.accountFromDomain("tstdrv123.app.netsuite.com")).toBe("TSTDRV123")
	end)

	it("returns nil for non account-specific hosts", function()
		expect(Manageauth.accountFromDomain("system.netsuite.com")).toBeNil()
		expect(Manageauth.accountFromDomain("")).toBeNil()
	end)
end)

describe("lines the parsers do not read", function()
	it("are returned for --list, so a native view can still show warnings and notices", function()
		local lines = {
			"(node:123) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.",
			"\27[2K\27[1Gdemo-sb | Administrator @ Example Corp | 1234567-sb1.app.netsuite.com",
			"",
		}
		expect(Manageauth.unrecognizedList(lines)).toEqual({
			"(node:123) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.",
		})
		expect(Manageauth.unrecognizedList(fixtures.lines("suitecloud/manageauth/list.txt"))).toEqual({})
	end)

	it("are returned for --info, including fields it has no name for", function()
		local lines = fixtures.lines("suitecloud/manageauth/info-sandbox.txt")
		expect(Manageauth.unrecognizedInfo(lines)).toEqual({})
		table.insert(lines, "Role ID: 3")
		table.insert(lines, "A notice without a colon")
		expect(Manageauth.unrecognizedInfo(lines)).toEqual({ "Role ID: 3", "A notice without a colon" })
	end)
end)

return nil
