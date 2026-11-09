--!strict
local CliSlot = require("../../../plugin/lib/sdf/cli_slot")
local Config = require("../../../plugin/lib/config")
local Resolve = require("../../../plugin/lib/account/resolve")
local Upload = require("../../../plugin/lib/explorer/upload")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local GUARD = "/opt/tern-netsuite/shell/tern-netsuite-guard"

local function owner(project: string, root: string, path: string, fc: string?): Upload.Owner
	return { project = project, root = root, path = path, fileCabinetPath = fc }
end

local function config(text: string?): Config.Config
	local cfg = Config.parse(text, json.decode)
	return cfg
end

describe("choosing the project a file is uploaded from", function()
	it("uploads straight from the only project that carries the file", function()
		local d = Upload.decide({
			owner("billing", "/repo/sdf/billing", "src/FileCabinet/SuiteScripts/b.js", "/SuiteScripts/b.js"),
		})
		expect(d.t).toBe("one")
		expect((d :: any).owner.project).toBe("billing")
	end)

	it("asks which project when several carry the same shared file", function()
		local d = Upload.decide({
			owner(
				"billing",
				"/repo/sdf/billing",
				"src/FileCabinet/SuiteScripts/lib/http.js",
				"/SuiteScripts/lib/http.js"
			),
			owner(
				"storefront",
				"/repo/sdf/storefront",
				"src/FileCabinet/SuiteScripts/x/http.js",
				"/SuiteScripts/x/http.js"
			),
		})
		expect(d.t).toBe("pick")
		expect(#(d :: any).owners).toBe(2)
	end)

	it("does not offer an upload for object XML, which only project:deploy sends", function()
		local d = Upload.decide({ owner("billing", "/repo/sdf/billing", "src/Objects/customlist_x.xml", nil) })
		expect(d.t).toBe("none")
		expect((d :: any).reason).toContain("project:deploy")
	end)

	it("explains when no scanned project carries the file", function()
		local d = Upload.decide({})
		expect(d.t).toBe("none")
		expect((d :: any).reason).toContain("no scanned SDF project")
	end)

	it("ignores object owners when a File Cabinet owner exists", function()
		local d = Upload.decide({
			owner("billing", "/repo/sdf/billing", "src/Objects/customlist_x.xml", nil),
			owner("storefront", "/repo/sdf/storefront", "src/FileCabinet/SuiteScripts/p.js", "/SuiteScripts/p.js"),
		})
		expect(d.t).toBe("one")
		expect((d :: any).owner.project).toBe("storefront")
	end)
end)

describe("the account an upload goes to", function()
	local now = 1000000

	it("treats a project without defaultAuthId as production, since the CLI target is unknown", function()
		local target = Upload.target(nil, { config = config(nil), cache = {}, now = now })
		expect(target.production).toBe(true)
		expect(target.source).toBe("none")
	end)

	it("treats an auth id nothing has resolved as production", function()
		local target = Upload.target("demo-sb", { config = config(nil), cache = {}, now = now })
		expect(target.production).toBe(true)
		expect(target.source).toBe("unknown")
	end)

	it("recognises a sandbox account the CLI reported", function()
		local cache: Resolve.Cache = { ["demo-sb"] = { authId = "demo-sb", accountId = "1234567_SB1", at = now } }
		local target = Upload.target("demo-sb", { config = config(nil), cache = cache, now = now })
		expect(target.production).toBe(false)
		expect(target.accountId).toBe("1234567_SB1")
	end)

	it("recognises a configured production account", function()
		local cfg =
			config('{"accounts":[{"id":"prod","account_id":"1234567","label":"Acme PROD","auth_ids":["acme-prod"]}]}')
		local target = Upload.target("acme-prod", { config = cfg, cache = {}, now = now })
		expect(target.production).toBe(true)
		expect(target.label).toBe("Acme PROD")
	end)
end)

describe("the command the upload pane runs", function()
	local LOCK = "/data/cli-slots/auth-demo-sb"
	local sandbox: Upload.Target =
		{ authId = "demo-sb", label = "1234567_SB1", accountId = "1234567_SB1", production = false, source = "cli" }
	local prod: Upload.Target = { authId = "PRODUCTION", label = "PRODUCTION", production = true, source = "unknown" }

	it("runs file:upload through the guard from the project root, which is where the CLI reads project.json", function()
		local launch = Upload.command(
			owner("billing", "/repo/sdf/billing", "src/FileCabinet/SuiteScripts/b.js", "/SuiteScripts/b.js"),
			GUARD,
			sandbox,
			LOCK
		)
		assert(launch, "launch")
		expect(launch.argv).toEqual({ GUARD, "suitecloud", "file:upload", "--paths", "/SuiteScripts/b.js" })
		expect(launch.cwd).toBe("/repo/sdf/billing")
		expect(launch.script).toContain("cd /repo/sdf/billing && sh -c ")
		expect(launch.script).toContain(GUARD .. " suitecloud file:upload --paths /SuiteScripts/b.js")
		expect(string.sub(launch.line, 1, 7)).toBe("sh -c '")
	end)

	it("waits in the auth ID's CLI slot, so a second upload or a browser listing never runs beside it", function()
		local launch = Upload.command(owner("b", "/r/b", "x", "/SuiteScripts/x.js"), GUARD, sandbox, LOCK)
		assert(launch, "launch")
		expect(launch.script).toContain(LOCK .. " 0 file:upload " .. GUARD .. " suitecloud file:upload")
	end)

	it("keeps the pane open with the exit status so a failed upload is visible", function()
		local launch = Upload.command(
			owner("b", "/r/b", "src/FileCabinet/SuiteScripts/b.js", "/SuiteScripts/b.js"),
			GUARD,
			sandbox,
			LOCK
		)
		assert(launch, "launch")
		expect(launch.script).toContain("s=$?; printf")
		expect(launch.script).toContain("exited %s")
		expect(launch.script).toContain('exit "$s"')
	end)

	it("quotes paths with spaces so the shell passes each as one word", function()
		local launch = Upload.command(
			owner("o'brien", "/repo/sdf/Billing app", "src/FileCabinet/SuiteScripts/a b.js", "/SuiteScripts/a b.js"),
			GUARD,
			prod,
			LOCK
		)
		assert(launch, "launch")
		expect(launch.script).toContain([[cd '/repo/sdf/Billing app' && ]])
		expect(launch.script).toContain([[--paths '/SuiteScripts/a b.js']])
		-- The whole script is one single-quoted sh -c argument.
		expect(launch.line).toBe("sh -c " .. CliSlot.quote(launch.script))
	end)

	it("refuses paths with backslashes or quotes: fish reads \\' inside single quotes as a quote", function()
		for _, fc in { "/SuiteScripts/a\\'; touch x; '.js", "/SuiteScripts/it's.js" } do
			local launch, err = Upload.command(owner("b", "/r/b", "src/FileCabinet" .. fc, fc), GUARD, sandbox, LOCK)
			expect(launch).toBeNil()
			expect(err).toContain("shell line")
		end
		local launch, err = Upload.command(owner("b", "/repo/O'Brien", "x", "/SuiteScripts/x.js"), GUARD, sandbox, LOCK)
		expect(launch).toBeNil()
		expect(err).toContain("shell line")
	end)

	it("refuses a File Cabinet path with a double quote: the CLI wraps --paths in double quotes unescaped", function()
		local launch, err = Upload.command(
			owner("b", "/r/b", 'src/FileCabinet/SuiteScripts/say "hi".js', '/SuiteScripts/say "hi".js'),
			GUARD,
			sandbox,
			LOCK
		)
		expect(launch).toBeNil()
		expect(err).toContain("double quote")
	end)

	it("refuses paths with control characters or dot segments that could aim the upload elsewhere", function()
		for _, fc in { "/SuiteScripts/a\nb.js", "/SuiteScripts/../x.js", "SuiteScripts/x.js", "/SuiteScripts/./x.js" } do
			local launch = Upload.command(owner("b", "/r/b", "src/FileCabinet" .. fc, fc), GUARD, sandbox, LOCK)
			expect(launch).toBeNil()
		end
		expect((Upload.command(owner("b", "relative/b", "x", "/SuiteScripts/x.js"), GUARD, sandbox, LOCK))).toBeNil()
		expect((Upload.command(owner("b", "/r/b", "x", "/SuiteScripts/x.js"), "guard", sandbox, LOCK))).toBeNil()
	end)

	it("names the target account and whether approval is needed in the pane title", function()
		local a = Upload.command(owner("b", "/r/b", "x", "/SuiteScripts/x.js"), GUARD, sandbox, LOCK)
		local b = Upload.command(owner("b", "/r/b", "x", "/SuiteScripts/x.js"), GUARD, prod, LOCK)
		assert(a and b, "launch")
		expect(a.title).toContain("1234567_SB1")
		expect(b.title).toContain("PRODUCTION")
		expect(b.title).toContain("approval")
	end)
end)

return nil
