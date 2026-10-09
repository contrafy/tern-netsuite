--!strict
local Protocol = require("../../../plugin/lib/guard/protocol")
local encode = require("./encode")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local NONCE = "0123456789abcdef0123456789abcdef"
local SPOOL = "/Users/me/Library/Application Support/tern/plugins/tern-netsuite/spool"
local PATH = SPOOL .. "/req-" .. NONCE .. ".json"
local FP = string.rep("ab", 32)
local SHA = string.rep("0f", 32)

local function doc(over: { [string]: any }?): { [string]: any }
	local d: { [string]: any } = {
		version = 1,
		nonce = NONCE,
		argv = { "suitecloud", "project:deploy", "--log", "my logs/deploy.log" },
		command = "project:deploy",
		program = "/opt/bin/suitecloud",
		cwd = "/work/sdf/billing",
		folder = "/work/sdf/billing/src",
		auth_id = "prod",
		account_id = "1234567",
		account_name = "Example Co",
		account_type = "Production",
		pane = "4294967309",
		git = {
			root = "/work",
			branch = "feature/x",
			head = string.rep("1", 40),
			dirty = true,
			upstream = "origin/feature/x",
			ahead = 2,
			behind = 1,
			default_branch = "main",
		},
		notes = { "suitecloud.config.js defines a beforeExecuting hook" },
		files = {
			{ path = "/work/sdf/billing/src/deploy.xml", sha256 = SHA },
			{ path = "/work/sdf/billing/project.json", sha256 = SHA },
		},
		fingerprint = FP,
		created_at = 1791476707,
		timeout_s = 600,
	}
	if over then
		for k, v in over do
			d[k] = v
		end
	end
	return d
end

local function parse(d: { [string]: any }, path: string?)
	return Protocol.parse(path or PATH, encode(d), json.decode)
end

describe("recognising guard request files", function()
	it("claims only request files in a tern-netsuite spool, so other opens keep their editor", function()
		expect(Protocol.isRequestPath(PATH)).toBe(true)
		expect(Protocol.isRequestPath("/tmp/tern-netsuite/spool/req-" .. NONCE .. ".json")).toBe(true)
		expect(Protocol.isRequestPath(SPOOL .. "/resp-" .. NONCE .. ".env")).toBe(false)
		expect(Protocol.isRequestPath(SPOOL .. "/req-xyz.json")).toBe(false)
		expect(Protocol.isRequestPath("/tmp/tern-kube/spool/req-" .. NONCE .. ".json")).toBe(false)
		expect(Protocol.isRequestPath("relative/tern-netsuite/spool/req-" .. NONCE .. ".json")).toBe(false)
	end)
end)

describe("parsing a guard request", function()
	it("keeps everything the approver must see", function()
		local r = parse(doc())
		assert(r, "request")
		expect(r.dir).toBe(SPOOL)
		expect(r.nonce).toBe(NONCE)
		expect(r.argv).toEqual({ "suitecloud", "project:deploy", "--log", "my logs/deploy.log" })
		expect(r.command).toBe("project:deploy")
		expect(r.authId).toBe("prod")
		expect(r.accountId).toBe("1234567")
		expect(r.accountName).toBe("Example Co")
		expect(r.pane).toBe("4294967309")
		expect(#r.files).toBe(2)
		expect(r.notes).toEqual({ "suitecloud.config.js defines a beforeExecuting hook" })
		local git = r.git
		assert(git, "git")
		expect(git.branch).toBe("feature/x")
		expect(git.dirty).toBe(true)
		expect(git.ahead).toBe(2)
		expect(git.behind).toBe(1)
		expect(git.defaultBranch).toBe("main")
	end)

	it("accepts an unknown target: the approver still decides, seeing that it is unknown", function()
		local d = doc()
		d.auth_id = nil
		d.account_id = nil
		d.account_name = nil
		d.account_type = nil
		d.git = nil
		local r = parse(d)
		assert(r, "request")
		expect(r.authId).toBeNil()
		expect(r.accountId).toBeNil()
		expect(r.git).toBeNil()
	end)

	it("refuses a request whose nonce differs from its file name (the response would go astray)", function()
		local r, err = parse(doc({ nonce = string.rep("f", 32) }))
		expect(r).toBeNil()
		expect(err).toContain("nonce")
	end)

	it("refuses requests outside the request file naming scheme", function()
		local r, err = parse(doc(), SPOOL .. "/other.json")
		expect(r).toBeNil()
		expect(err).toContain("req-")
	end)

	it("refuses a request that does not run suitecloud", function()
		local r = parse(doc({ argv = { "rm", "-rf", "/" } }))
		expect(r).toBeNil()
	end)

	it("refuses a request whose command differs from the argv's", function()
		local r = parse(doc({ command = "file:upload" }))
		expect(r).toBeNil()
	end)

	it("refuses malformed fingerprints, file digests and times", function()
		expect((parse(doc({ fingerprint = "abc" })))).toBeNil()
		expect((parse(doc({ files = { { path = "relative.js", sha256 = SHA } } })))).toBeNil()
		expect((parse(doc({ files = { { path = "/a.js", sha256 = "xyz" } } })))).toBeNil()
		expect((parse(doc({ timeout_s = 0 })))).toBeNil()
		expect((parse(doc({ created_at = "now" })))).toBeNil()
		expect((parse(doc({ pane = "" })))).toBeNil()
	end)

	it("reports invalid JSON instead of raising", function()
		local r, err = Protocol.parse(PATH, "{", json.decode)
		expect(r).toBeNil()
		expect(err).toContain("JSON")
	end)
end)

describe("the fingerprint canonical string", function()
	local input: Protocol.FingerprintInput = {
		argv = { "suitecloud", "file:upload", "--paths", "/SuiteScripts/a b.js" },
		cwd = "/work/p",
		folder = "/work/p/src",
		authId = "prod",
		accountId = "1234567",
		files = {
			{ path = "/work/p/src/b.js", sha256 = SHA },
			{ path = "/work/p/project.json", sha256 = string.rep("AA", 32) },
		},
	}

	it("matches the byte format the shell guard hashes (shell/PROTOCOL.md)", function()
		local text = Protocol.canonical(input)
		expect(text).toBe(table.concat({
			"tern-netsuite/fp/v1",
			"argv 4",
			"10:suitecloud",
			"11:file:upload",
			"7:--paths",
			"20:/SuiteScripts/a b.js",
			"cwd 7:/work/p",
			"folder 11:/work/p/src",
			"authid 4:prod",
			"account 7:1234567",
			"files 2",
			"20:/work/p/project.json " .. string.rep("aa", 32),
			"16:/work/p/src/b.js " .. SHA,
			"",
		}, "\n"))
	end)

	it("marks an unknown auth ID and account so they cannot collide with a real value", function()
		local text = Protocol.canonical({ argv = { "suitecloud" }, cwd = "/p", folder = "/p", files = {} })
		expect(text).toContain("\nauthid -\naccount -\nfiles 0\n")
	end)

	it("counts lengths in bytes, as the shell does", function()
		local text = Protocol.canonical({ argv = { "suitecloud", "ü" }, cwd = "/p", folder = "/p", files = {} })
		expect(text).toContain("\n2:ü\n")
	end)

	it("refuses a file listed twice (the shell de-duplicates)", function()
		local text, err = Protocol.canonical({
			argv = { "suitecloud" },
			cwd = "/p",
			folder = "/p",
			files = { { path = "/p/a", sha256 = SHA }, { path = "/p/a", sha256 = SHA } },
		})
		expect(text).toBeNil()
		expect(err).toContain("twice")
	end)
end)

describe("the response file", function()
	it("carries the decision in the key=value lines the guard verifies", function()
		local text = Protocol.response({
			nonce = NONCE,
			decision = "approve",
			fingerprint = FP,
			account = "1234567",
			at = 1791476710,
		})
		expect(text).toBe(
			"nonce="
				.. NONCE
				.. "\ndecision=approve\nfingerprint="
				.. FP
				.. "\naccount=1234567\napproved_at=1791476710\n"
		)
	end)

	it("writes '-' for an unknown account, as the guard expects", function()
		local text = Protocol.response({ nonce = NONCE, decision = "deny", fingerprint = FP, at = 1 })
		expect(text).toContain("\naccount=-\n")
	end)

	it("keeps a deny reason on one line so it cannot forge another key", function()
		local text = Protocol.response({
			nonce = NONCE,
			decision = "deny",
			fingerprint = FP,
			at = 1,
			reason = "bad\ndecision=approve",
		})
		expect(text).toContain("reason=bad decision=approve\n")
		expect(select(2, string.gsub(text, "decision=", ""))).toBe(2)
	end)
end)

return nil
