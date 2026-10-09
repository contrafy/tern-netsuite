--!strict
local Argv = require("../../../plugin/lib/sdf/argv")
local Config = require("../../../plugin/lib/config")
local Output = require("../../../plugin/lib/sdf/output")
local LogsLink = require("../../../plugin/lib/monitor/logs/link")
local View = require("../../../plugin/lib/lens/view")
local Viewstate = require("../../../plugin/lib/lens/viewstate")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Node = any

local DEFAULTS = Config.defaults()

local function inv(line: string): Argv.Invocation
	local words = Argv.words(line)
	local program = table.remove(words, 1) :: string
	return Argv.parse({ program = program, args = words, line = line }) :: Argv.Invocation
end

local function capture(name: string, line: string): (Output.Result, Argv.Invocation)
	local status = tonumber((string.gsub(fixtures.read("suitecloud/" .. name .. ".exit"), "%s", ""))) :: number
	local i = inv(line)
	return Output.parse(i, fixtures.lines("suitecloud/" .. name .. ".txt"), status) :: Output.Result, i
end

local function opts(cfg: Config.Config?): View.Options
	return { cfg = cfg or DEFAULTS, cwd = "/work/proj/clean", projectDir = "/work/proj/clean/src", line = nil }
end

-- Depth-first walk of every node.
local function walk(node: Node, visit: (Node) -> ())
	visit(node)
	for _, c in node.c or {} do
		walk(c, visit)
	end
end

local function find(node: Node, pred: (Node) -> boolean): Node?
	local found: Node? = nil
	walk(node, function(n)
		if found == nil and pred(n) then
			found = n
		end
	end)
	return found
end

local function byKey(node: Node, key: string): Node?
	return find(node, function(n)
		return n.p ~= nil and n.p.key == key
	end)
end

-- All visible text: spans, badge texts, card heads.
local function textOf(node: Node): string
	local parts: { string } = {}
	walk(node, function(n)
		local p = n.p or {}
		if type(p.text) == "string" then
			table.insert(parts, p.text)
		end
		for _, field in { "spans", "head" } do
			for _, s in p[field] or {} do
				table.insert(parts, s.t)
			end
		end
		for _, item in p.items or {} do
			for _, s in item.k do
				table.insert(parts, s.t)
			end
			for _, s in item.v do
				table.insert(parts, s.t)
			end
		end
	end)
	return table.concat(parts, "\n")
end

local function actionsOf(node: Node): { string }
	local out: { string } = {}
	walk(node, function(n)
		local a = n.p and n.p.actions
		if a and a.click then
			table.insert(out, a.click)
		end
	end)
	return out
end

local function render(name: string, line: string, vs: Viewstate.ViewState?, cfg: Config.Config?): Node
	local r, i = capture(name, line)
	return View.render(r, i, vs or Viewstate.default(), opts(cfg)) :: Node
end

describe("the header", function()
	it("shows the outcome, the command and that a local validation contacted no account", function()
		local node = render("validate/ok", "suitecloud project:validate")
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Valid")
		expect((byKey(node, "outcome") :: Node).p.tone).toBe("success")
		expect((byKey(node, "target") :: Node).p.text).toBe("local")
	end)

	it("shows a sandbox target muted", function()
		local node = render("validate/server-ok", "suitecloud project:validate --server")
		local target = byKey(node, "target") :: Node
		expect(target.p.text).toBe("1234567_SB1")
		expect(target.p.tone).toBe("muted")
	end)

	it("marks a production deploy target in the error tone so it cannot be mistaken", function()
		local node = render("deploy/ok-production", "suitecloud project:deploy")
		local target = byKey(node, "target") :: Node
		expect(target.p.text).toBe("PROD 1234567")
		expect(target.p.tone).toBe("error")
	end)

	it("uses the configured label of a known account", function()
		local cfg = Config.parse(
			[[{"accounts":[{"id":"prod","label":"PROD","account_id":"1234567","auth_ids":["prod"]},
			{"id":"sb","label":"SB1","account_id":"1234567_SB1","auth_ids":["sb"]}]}]],
			json.decode
		)
		expect((byKey(render("deploy/ok-production", "suitecloud project:deploy", nil, cfg), "target") :: Node).p.text).toBe(
			"PROD"
		)
		expect((byKey(render("deploy/ok", "suitecloud project:deploy", nil, cfg), "target") :: Node).p.text).toBe("SB1")
	end)

	it("says the account is unknown when a deploy log names none, instead of guessing", function()
		local r =
			Output.parse(inv("suitecloud project:deploy"), { "The deployment process has finished successfully." }, 0)
		local node =
			View.render(r :: Output.Result, inv("suitecloud project:deploy"), Viewstate.default(), opts()) :: Node
		local target = byKey(node, "target") :: Node
		expect(target.p.text).toBe("account unknown")
		expect(target.p.tone).toBe("warning")
	end)

	it("classifies by a configured auth id when only the auth id is known", function()
		local cfg =
			Config.parse([[{"accounts":[{"id":"prod","account_id":"7654321","auth_ids":["live"]}]}]], json.decode)
		local i = inv("suitecloud project:deploy")
		local r = Output.parse(i, {
			'Deploying project "x" with auth ID "live"...',
			"The deployment process has finished successfully.",
		}, 0) :: Output.Result
		local tv = View.targetView(r, i, cfg)
		expect(tv.production).toBe(true)
		expect(tv.tone).toBe("error")
	end)

	it("marks a failed run in the error tone", function()
		local node = render("validate/malformed-xml", "suitecloud project:validate")
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Validation failed")
		expect((byKey(node, "outcome") :: Node).p.tone).toBe("error")
	end)
end)

describe("diagnostics", function()
	it("shows each failing object as an error card linking to its file, relative to the project", function()
		local node = render("validate/missing-file", "suitecloud project:validate")
		local card = byKey(node, "g:customscript_tns_demo") :: Node
		expect(card.k).toBe("card")
		expect(card.p.tone).toBe("error")
		local head = card.p.head
		expect(head[1].t).toBe("customscript_tns_demo")
		local link = find(card, function(n)
			for _, s in (n.p and n.p.spans) or {} do
				if s.href then
					return true
				end
			end
			return false
		end) :: Node
		local span = link.p.spans[1]
		expect(span.href).toBe("file:///work/proj/missingfile/src/Objects/customscript_tns_demo.xml#L9")
		expect(textOf(card)).toContain('"scriptfile" is missing')
	end)

	it("links server paths (~/...) into the project folder", function()
		local node = render("validate/server-missing-file", "suitecloud project:validate --server")
		local card = byKey(node, "g:customscript_tns_demo") :: Node
		expect(card.p.head[3].t).toBe("~/Objects/customscript_tns_demo.xml")
		expect(card.p.head[3].href).toBe("file:///work/proj/clean/src/Objects/customscript_tns_demo.xml")
	end)

	it("keeps warnings collapsed until asked, so errors stay in view", function()
		local closed = render("validate/warnings", "suitecloud project:validate")
		expect(byKey(closed, "g:customscript_tns_demo")).toBeNil()
		expect((byKey(closed, "warnings-toggle") :: Node).p.text).toBe("Show 1 warning")
		local open = render("validate/warnings", "suitecloud project:validate", Viewstate.decode("w:1"))
		expect((byKey(open, "g:customscript_tns_demo") :: Node).p.tone).toBe("warning")
	end)

	it("shows output lines it could not place, so native and raw say the same", function()
		local node = render("validate/deploy-path-crash", "suitecloud project:validate")
		expect(textOf(byKey(node, "unknown") :: Node)).toContain("java.util.Collection.iterator()")
	end)
end)

describe("chips", function()
	it("offers copying the errors and the server-side validation command", function()
		local node = render("validate/malformed-xml", "suitecloud project:validate")
		local actions = actionsOf(node)
		expect(actions).toContain("copy=errors")
		expect(actions).toContain("copy=rerun")
		local r, i = capture("validate/malformed-xml", "suitecloud project:validate")
		expect(View.copyText(r, i, "rerun")).toBe("suitecloud project:validate --server")
		expect(View.copyText(r, i, "errors")).toContain("must be terminated")
		expect(View.copyText(r, i, "warnings")).toBeNil()
	end)

	it("carries the next view state in every toggle, so a reloaded lens restores it", function()
		local node = render("validate/server-warnings", "suitecloud project:validate --server", Viewstate.decode("s:1"))
		local actions = actionsOf(node)
		expect(actions).toContain("v=w:1;s:1")
		expect(actions).toContain("v=")
	end)
end)

describe("results", function()
	it("lists deployed objects and files, collapsing long lists", function()
		local node = render("deploy/ok", "suitecloud project:deploy")
		local text = textOf(byKey(node, "items") :: Node)
		expect(text).toContain("customscript_tns_demo")
		expect(text).toContain("~/FileCabinet/SuiteScripts/tns_demo.js")
		expect(textOf(byKey(node, "counts") :: Node)).toBe("3 objects · 1 file · 15 steps · in 18s")
	end)

	it("lists only failed steps until all are asked for", function()
		local node = render("validate/server-missing-file", "suitecloud project:validate --server")
		local steps = textOf(byKey(node, "steps") :: Node)
		expect(steps).toContain("Validate objects")
		expect((string.find(steps, "Validate manifest", 1, true))).toBeNil()
	end)

	it("shows the package file", function()
		local node = render("package/ok", "suitecloud project:package")
		expect(textOf(node)).toContain("tns-demo-2026-10-09_00-00-42.zip")
	end)

	it("lists added dependencies", function()
		local node = render("adddependencies/added", "suitecloud project:adddependencies")
		expect(textOf(byKey(node, "items") :: Node)).toContain("File - /SuiteScripts/tns_shared.js")
	end)

	it("marks files that were not uploaded", function()
		local node = render("upload/partial", "suitecloud file:upload --paths /SuiteScripts/a.js")
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Upload failed")
		expect(textOf(byKey(node, "items") :: Node)).toContain("Not uploaded")
	end)

	it("shows the --log file", function()
		local node = render("validate/log", "suitecloud project:validate --log /work/validate.log")
		expect(textOf(node)).toContain("/work/validate.log")
	end)
end)

describe("raw fallbacks", function()
	it("renders nothing for output it does not understand", function()
		local i = inv("suitecloud project:validate")
		local r = Output.parse(i, { "totally new output format" }, 0) :: Output.Result
		expect(View.render(r, i, Viewstate.default(), opts())).toBeNil()
	end)

	it("renders nothing for interactive runs, whose prompts only make sense raw", function()
		local i = inv("suitecloud project:deploy -i")
		local r = Output.parse(i, fixtures.lines("suitecloud/deploy/ok.txt"), 0) :: Output.Result
		expect(View.render(r, i, Viewstate.default(), opts())).toBeNil()
	end)
end)

describe("wrapped runs", function()
	it("renders a configured wrapper's validate run natively", function()
		local wrappers = { { prefix = "npm run validate", command = "project:validate" } }
		local i = Argv.parse({
			program = "npm",
			args = { "run", "validate", "--project", "billing" },
			line = "npm run validate --project billing",
		}, wrappers) :: Argv.Invocation
		local r = Output.parse(i, fixtures.lines("suitecloud/validate/warnings.txt"), 0) :: Output.Result
		local node = View.render(r, i, Viewstate.default(), opts()) :: Node
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Valid with warnings")
		expect(textOf(node)).toContain("billing")
	end)
end)

describe("every fixture", function()
	it("renders without error, never nesting a lines node in a section (Tern drops such views)", function()
		local commands = {
			validate = "suitecloud project:validate",
			deploy = "suitecloud project:deploy",
			upload = "suitecloud file:upload",
			package = "suitecloud project:package",
			adddependencies = "suitecloud project:adddependencies",
		}
		for _, path in fixtures.list("suitecloud/") do
			local name = string.match(path, "^suitecloud/(.+)%.txt$")
			local family = if name then string.match(name, "^(%a+)/") else nil
			local line = if family then (commands :: any)[family] else nil
			if name and line then
				for _, vs in { "", "w:1;i:1;s:1" } do
					local node = render(name, line, Viewstate.decode(vs))
					expect(node.p and node.p.key).toBe("suitecloud")
					walk(node, function(n)
						if n.k == "section" then
							for _, c in n.c or {} do
								if c.k == "lines" then
									error(name .. ": lines inside a section")
								end
							end
						end
					end)
				end
			end
		end
	end)
end)

describe("deploy preview", function()
	it("labels a dry run as a preview of what would change, not as deployed", function()
		local node = render("deploy/preview", "suitecloud project:deploy --dryrun")
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Preview OK")
		expect((byKey(node, "target") :: Node).p.text).toBe("1234567_SB1")
		local items = textOf(byKey(node, "items") :: Node)
		expect(items).toContain("Would change")
		expect((string.find(textOf(node), "Deployed", 1, true))).toBeNil()
	end)

	it("labels a failed dry run as a failed preview", function()
		local node = render("deploy/validation-failed", "suitecloud project:deploy --dryrun")
		expect((byKey(node, "outcome") :: Node).p.text).toBe("Preview failed")
	end)
end)

local function logsAction(node: Node): string?
	for _, a in actionsOf(node) do
		local url = string.match(a, "^logs=(.*)$")
		if url then
			return url
		end
	end
	return nil
end

local SANDBOX_CONNECTION = [[{
	"accounts": [
		{ "id": "sb", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"] },
		{ "id": "prod", "account_id": "1234567", "auth_ids": ["demo-prod"] }
	],
	"connections": [ { "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" } ]
}]]

describe("tailing the logs of a deploy", function()
	it("offers the execution logs of the deployed scripts, each script once", function()
		local url = logsAction(render("deploy/ok", "suitecloud project:deploy")) :: string
		local decision = LogsLink.route(url) :: LogsLink.Decision
		expect(decision.block).toBe(LogsLink.BLOCK)
		expect(decision.args).toEqual({ "script=customscript_tns_demo", "since=31m" })
	end)

	it("names the connection configured for the deploy's account", function()
		local cfg = Config.parse(SANDBOX_CONNECTION, json.decode)
		local url = logsAction(render("deploy/ok", "suitecloud project:deploy", nil, cfg)) :: string
		expect((LogsLink.route(url) :: LogsLink.Decision).args[1]).toBe("connection=sb-rest")
	end)

	it("never points a production deploy at another account's connection", function()
		local cfg = Config.parse(SANDBOX_CONNECTION, json.decode)
		local url = logsAction(render("deploy/ok-production", "suitecloud project:deploy", nil, cfg)) :: string
		expect((LogsLink.route(url) :: LogsLink.Decision).args[1]).toBe("script=customscript_tns_demo")
	end)

	it("is not offered for a preview, a validation or a deploy without valid script ids", function()
		expect(logsAction(render("deploy/preview", "suitecloud project:deploy --dryrun"))).toBeNil()
		expect(logsAction(render("validate/server-ok", "suitecloud project:validate --server"))).toBeNil()
		local i = inv("suitecloud project:deploy")
		local r = Output.parse(i, {
			"Create object -- customrecord_x (customrecordtype)",
			"Create object -- customscript_bad-id (restlet)",
			"The deployment process has finished successfully.",
		}, 0) :: Output.Result
		expect(logsAction(View.render(r, i, Viewstate.default(), opts()) :: Node)).toBeNil()
	end)

	it("caps the scripts at what the logs link accepts", function()
		local lines: { string } = {}
		for n = 1, 60 do
			table.insert(lines, "Update object -- customscript_s" .. n .. " (restlet)")
		end
		table.insert(lines, "The deployment process has finished successfully.")
		local i = inv("suitecloud project:deploy")
		local r = Output.parse(i, lines, 0) :: Output.Result
		local url = logsAction(View.render(r, i, Viewstate.default(), opts()) :: Node) :: string
		local decision = LogsLink.route(url) :: LogsLink.Decision
		expect(#decision.args).toBe(LogsLink.MAX_SCRIPTS + 1)
	end)
end)

describe("the project folder of ~/ paths", function()
	it("comes from suitecloud.config.js defaultProjectFolder", function()
		expect(View.projectDir("/repo/sdf/billing", "module.exports = { defaultProjectFolder: 'source' };")).toBe(
			"/repo/sdf/billing/source"
		)
		expect(View.projectDir("/repo/x", nil)).toBeNil()
	end)

	it("leaves ~/ paths unlinked when the folder is unknown, rather than guessing src", function()
		local r, i = capture("validate/server-missing-file", "suitecloud project:validate --server")
		local node = View.render(r, i, Viewstate.default(), { cfg = DEFAULTS, cwd = "/x", projectDir = nil }) :: Node
		local card = byKey(node, "g:customscript_tns_demo") :: Node
		expect(card.p.head[3].t).toBe("~/Objects/customscript_tns_demo.xml")
		expect(card.p.head[3].href).toBeNil()
	end)
end)

describe("account listings", function()
	local function listing(name: string, line: string, vs: Viewstate.ViewState?, o: View.Options?): Node?
		local status = tonumber((string.gsub(fixtures.read("suitecloud/list/" .. name .. ".exit"), "%s", ""))) :: number
		return View.renderListing(
			inv(line),
			fixtures.lines("suitecloud/list/" .. name .. ".txt"),
			status,
			vs or Viewstate.default(),
			o or opts()
		)
	end

	it("summarizes object:list by type, largest first, with the filters the user passed", function()
		local node = listing("object-type", "suitecloud object:list --type restlet suitelet") :: Node
		expect((byKey(node, "outcome") :: Node).p.text).toBe("6 objects")
		expect((byKey(node, "t:restlet") :: Node).p.text).toBe("restlet 3")
		expect((byKey(node, "t:suitelet") :: Node).p.text).toBe("suitelet 3")
		expect(textOf(node)).toContain("--type restlet suitelet")
		expect(textOf(node)).toContain("customscript_demo_4")
	end)

	it("caps a long listing and offers the full list as a view toggle", function()
		local node = listing("object-all", "suitecloud object:list") :: Node
		expect(textOf(node)).toContain("Show all 136")
		expect((string.find(textOf(node), "customworkflow_demo_131", 1, true))).toBeNil()
		local all = listing("object-all", "suitecloud object:list", Viewstate.decode("i:1")) :: Node
		expect(textOf(all)).toContain("customworkflow_demo_131")
		expect(textOf(all)).toContain("Show fewer")
	end)

	it("offers the browser, which can search, diff and import, for the directory the command ran in", function()
		local node = listing("object-all", "suitecloud object:list") :: Node
		expect(table.find(actionsOf(node), "browse") ~= nil).toBe(true)
		local o = opts()
		o.cwd = nil
		local noCwd = listing("object-all", "suitecloud object:list", nil, o) :: Node
		expect(table.find(actionsOf(noCwd), "browse")).toBeNil()
	end)

	it("shows an empty result natively with the CLI's sentence", function()
		local node = listing("object-unknown-type", "suitecloud object:list --type bogus") :: Node
		expect((byKey(node, "outcome") :: Node).p.text).toBe("No objects")
		expect(textOf(node)).toContain("no objects matching")
		local files = listing("file-missing-folder", "suitecloud file:list --folder /Nope") :: Node
		expect((byKey(files, "outcome") :: Node).p.text).toBe("No files")
	end)

	it("groups file:list paths by folder", function()
		local node = listing("file-folder", "suitecloud file:list --folder /SuiteScripts") :: Node
		expect((byKey(node, "outcome") :: Node).p.text).toBe("4 files")
		expect((byKey(node, "f:/SuiteScripts/tns_demo/lib") :: Node).p.text).toBe("/SuiteScripts/tns_demo/lib 1")
		expect(textOf(node)).toContain("/SuiteScripts/tns demo/report template.html")
	end)

	it("stays raw for failures, interactive runs and other commands", function()
		expect(listing("object-unknown-auth", "suitecloud object:list")).toBeNil()
		expect(listing("file-no-folder", "suitecloud file:list")).toBeNil()
		expect(listing("object-all", "suitecloud object:list -i")).toBeNil()
		expect(listing("object-all", "suitecloud project:validate")).toBeNil()
	end)

	it("renders every list fixture without nesting a lines node in a section", function()
		for _, path in fixtures.list("suitecloud/list/") do
			local name = string.match(path, "^suitecloud/list/(.+)%.txt$")
			if name then
				local line = if string.sub(name, 1, 4) == "file"
					then "suitecloud file:list --folder /x"
					else "suitecloud object:list"
				for _, vs in { "", "i:1" } do
					local node = listing(name, line, Viewstate.decode(vs))
					if node then
						walk(node, function(n)
							if n.k == "section" then
								for _, c in n.c or {} do
									if c.k == "lines" then
										error(name .. ": lines inside a section")
									end
								end
							end
						end)
					end
				end
			end
		end
	end)
end)

return nil
