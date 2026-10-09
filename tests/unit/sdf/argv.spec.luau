--!strict
local Argv = require("../../../plugin/lib/sdf/argv")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function run(line: string): Argv.Run
	local words = Argv.words(line)
	local program = table.remove(words, 1) :: string
	return { program = program, args = words, line = line, typed = line }
end

local WRAPPERS = {
	{ prefix = "npm run validate", command = "project:validate" },
	{ prefix = "npm run deploy", command = "project:deploy" },
	{ prefix = "./scripts/sdf.sh validate", command = "project:validate" },
}

describe("recognizing a SuiteCloud command", function()
	it("reads the command and its options from a plain suitecloud run", function()
		local inv = Argv.parse(run("suitecloud project:validate --server --log /tmp/v.log")) :: Argv.Invocation
		expect(inv.command).toBe("project:validate")
		expect(inv.flags.server).toBe(true)
		expect(inv.flags.log).toBe("/tmp/v.log")
		expect(inv.launcher).toBe("suitecloud")
		expect(inv.viaWrapper).toBeNil()
	end)

	it("accepts the CLI by absolute path, as shells report it after alias expansion", function()
		local inv = Argv.parse({ program = "/Users/dev/.bun/bin/suitecloud", args = { "project:deploy" } })
		expect((inv :: Argv.Invocation).command).toBe("project:deploy")
	end)

	it("recognizes npx launches of the CLI, by bin name or by package", function()
		local a = Argv.parse(run("npx suitecloud project:validate")) :: Argv.Invocation
		expect(a.command).toBe("project:validate")
		expect(a.launcher).toBe("npx suitecloud")
		local b = Argv.parse(run("npx -y @oracle/suitecloud-cli@3.2.0 file:upload --paths /SuiteScripts/a.js"))
		expect((b :: Argv.Invocation).command).toBe("file:upload")
		expect((b :: Argv.Invocation).launcher).toBe("npx @oracle/suitecloud-cli")
		expect((b :: Argv.Invocation).flags.paths).toBe("/SuiteScripts/a.js")
	end)

	it("keeps every path of a multi-path upload", function()
		local inv = Argv.parse(run('suitecloud file:upload --paths "/SuiteScripts/a.js" "/SuiteScripts/b.js" -i'))
		expect((inv :: Argv.Invocation).flags.paths).toBe("/SuiteScripts/a.js /SuiteScripts/b.js")
		expect((inv :: Argv.Invocation).interactive).toBe(true)
	end)

	it("declines lines that are not a known SuiteCloud command, so the lens stays raw", function()
		expect(Argv.parse(run("suitecloud --help"))).toBeNil()
		expect(Argv.parse(run("suitecloud help project:deploy"))).toBeNil()
		expect(Argv.parse(run("suitecloud project:frobnicate"))).toBeNil()
		expect(Argv.parse(run("npx suitecloud-other project:validate"))).toBeNil()
		expect(Argv.parse(run("npx @oracle/suitecloud-cli-extra project:validate"))).toBeNil()
		expect(Argv.parse(run("echo suitecloud project:validate"))).toBeNil()
	end)

	it("keeps the npx launcher of runs Tern reports with the CLI as the program", function()
		local inv = Argv.parse({
			program = "suitecloud",
			args = { "project:validate" },
			line = "npx -y suitecloud project:validate",
			typed = "npx -y suitecloud project:validate",
		}) :: Argv.Invocation
		expect(inv.command).toBe("project:validate")
		expect(inv.launcher).toBe("npx suitecloud")
		local pkg = Argv.parse({ program = "@oracle/suitecloud-cli@3.2.0", args = { "project:deploy" } })
		expect((pkg :: Argv.Invocation).launcher).toBe("npx @oracle/suitecloud-cli")
		-- Tern reports `npx @oracle/suitecloud-cli@3.2.0 x` with the basename as program.
		local base = Argv.parse({ program = "suitecloud-cli@3.2.0", args = { "project:deploy" } })
		expect((base :: Argv.Invocation).command).toBe("project:deploy")
		expect((base :: Argv.Invocation).launcher).toBe("npx @oracle/suitecloud-cli")
	end)

	it("reads the program when the line starts with a shell builtin such as command", function()
		local inv = Argv.parse({
			program = "suitecloud",
			args = { "project:validate" },
			line = "command suitecloud project:validate",
		}) :: Argv.Invocation
		expect(inv.command).toBe("project:validate")
		expect(inv.launcher).toBe("suitecloud")
	end)
end)

describe("interactive and help runs", function()
	it("marks -i and --interactive runs: they prompt instead of printing a result", function()
		local a = Argv.parse(run("suitecloud project:deploy -i")) :: Argv.Invocation
		local b = Argv.parse(run("suitecloud project:deploy --interactive")) :: Argv.Invocation
		expect(a.interactive).toBe(true)
		expect(b.interactive).toBe(true)
		expect(Argv.renders(a)).toBe(false)
		expect(Argv.renders(b)).toBe(false)
	end)

	it("marks --help runs so their usage text stays raw", function()
		local inv = Argv.parse(run("suitecloud project:validate --help")) :: Argv.Invocation
		expect(inv.help).toBe(true)
		expect(Argv.renders(inv)).toBe(false)
		expect(Argv.renders(Argv.parse(run("suitecloud project:validate -h")) :: Argv.Invocation)).toBe(false)
	end)

	it("renders ordinary runs", function()
		expect(Argv.renders(Argv.parse(run("suitecloud project:validate")) :: Argv.Invocation)).toBe(true)
	end)
end)

describe("configured wrappers", function()
	it("maps a wrapper line to its configured command and reads the wrapper's own options", function()
		local inv = Argv.parse(run("npm run deploy --project billing --env sandbox"), WRAPPERS) :: Argv.Invocation
		expect(inv.command).toBe("project:deploy")
		expect(inv.viaWrapper).toBe("npm run deploy")
		expect(inv.project).toBe("billing")
		expect(inv.flags.env).toBe("sandbox")
	end)

	it("matches whole words only, so validate-all is not validate", function()
		expect(Argv.parse(run("npm run validate-all"), WRAPPERS)).toBeNil()
		expect(Argv.parse(run("npm run validat"), WRAPPERS)).toBeNil()
	end)

	it("matches a wrapper given with a path and skips VAR= prefixes of the typed line", function()
		local inv = Argv.parse({
			program = "/usr/local/bin/npm",
			args = { "run", "validate", "--project", "billing" },
			line = "FOO=1 npm run validate --project billing",
		}, WRAPPERS) :: Argv.Invocation
		expect(inv.command).toBe("project:validate")
		expect(inv.project).toBe("billing")
	end)

	it("prefers the longest matching prefix", function()
		local wrappers = {
			{ prefix = "make sdf", command = "project:validate" },
			{ prefix = "make sdf deploy", command = "project:deploy" },
		}
		expect((Argv.parse(run("make sdf deploy"), wrappers) :: Argv.Invocation).command).toBe("project:deploy")
		expect((Argv.parse(run("make sdf"), wrappers) :: Argv.Invocation).command).toBe("project:validate")
	end)

	it("still recognizes direct CLI runs when wrappers are configured", function()
		expect((Argv.parse(run("suitecloud project:package"), WRAPPERS) :: Argv.Invocation).command).toBe(
			"project:package"
		)
	end)
end)

describe("the server-side validation command offered after a run", function()
	it("re-runs the same launcher with --server and keeps the account-specific-values policy", function()
		local inv = Argv.parse(run("npx suitecloud project:deploy --accountspecificvalues WARNING")) :: Argv.Invocation
		expect(Argv.serverValidate(inv)).toBe(
			"npx suitecloud project:validate --server --accountspecificvalues WARNING"
		)
	end)

	it("falls back to the plain CLI for wrapped runs, whose flags suitecloud does not know", function()
		local inv = Argv.parse(run("npm run validate --project billing"), WRAPPERS) :: Argv.Invocation
		expect(Argv.serverValidate(inv)).toBe("suitecloud project:validate --server")
	end)
end)

describe("splitting a typed line", function()
	it("honors quotes and escapes the way a shell does", function()
		expect(Argv.words([[a 'b c' "d \"e\"" f\ g]])).toEqual({ "a", "b c", 'd "e"', "f g" })
		expect(Argv.words("  ")).toEqual({})
		expect(Argv.words("x ''")).toEqual({ "x", "" })
	end)
end)

return nil
