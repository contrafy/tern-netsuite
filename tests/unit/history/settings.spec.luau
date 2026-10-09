--!strict
local Settings = require("../../../plugin/lib/history/settings")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Diag = { level: string, path: string, message: string }

local function parse(raw: any): (Settings.Settings, { Diag })
	local diags: { Diag } = {}
	local s = Settings.parse(raw, function(level: string, path: string, message: string)
		table.insert(diags, { level = level, path = path, message = message })
	end)
	return s, diags
end

describe("history settings", function()
	it("work without any history section: local history on, CI off", function()
		local s, diags = parse(nil)
		expect(s.max_entries).toBe(500)
		expect(s.ci).toBeNil()
		expect(#diags).toBe(0)
	end)

	it("turn CI runs on with just a workflow", function()
		local s = parse({ ci = { workflow = "sdf-deploy.yml" } })
		expect(s.ci).toEqual({
			gh = "gh",
			workflow = "sdf-deploy.yml",
			limit = 20,
			timeout_ms = 20000,
			poll_seconds = 300,
		})
	end)

	it("refuse CI without a workflow, saying why", function()
		local s, diags = parse({ ci = { gh = "/opt/homebrew/bin/gh" } })
		expect(s.ci).toBeNil()
		expect(diags[1].path).toBe("history.ci.workflow")
	end)

	it("keep limits in range and warn about typos", function()
		local s, diags = parse({ max_entries = 5, ci = { workflow = "w.yml", limit = 1000, wokflow = "x" } })
		expect(s.max_entries).toBe(500)
		expect((s.ci :: Settings.Ci).limit).toBe(20)
		local paths: { string } = {}
		for _, d in diags do
			table.insert(paths, d.path)
		end
		table.sort(paths)
		expect(paths).toEqual({ "history.ci.limit", "history.ci.wokflow", "history.max_entries" })
	end)

	it("are read from a parsed config, falling back to the defaults while the config has no history key", function()
		expect(Settings.of({}).ci).toBeNil()
		local s = Settings.of({ history = parse({ ci = { workflow = "w.yml" } }) })
		expect((s.ci :: Settings.Ci).workflow).toBe("w.yml")
	end)
end)

return nil
