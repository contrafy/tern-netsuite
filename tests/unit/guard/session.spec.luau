--!strict
local Config = require("../../../plugin/lib/config")
local Protocol = require("../../../plugin/lib/guard/protocol")
local Session = require("../../../plugin/lib/guard/session")
local encode = require("./encode")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type State = Session.State
type Effect = Session.Effect

local NONCE = "0123456789abcdef0123456789abcdef"
local SPOOL = "/data/tern-netsuite/spool"
local PATH = SPOOL .. "/req-" .. NONCE .. ".json"
local FP = string.rep("ab", 32)
local SHA = string.rep("0f", 32)
local CREATED = 1791476700
local NOW = CREATED + 10
local PANE = "4294967309"

local WITH_ACCOUNTS = [[{"accounts": [
	{"id": "prod", "label": "PROD", "account_id": "1234567", "auth_ids": ["prod"], "production": true},
	{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["sandbox"]}
]}]]

local function cfg(text: string?): Config.Config
	local c = Config.parse(text or WITH_ACCOUNTS, json.decode)
	return c
end

local function doc(over: { [string]: any }?): { [string]: any }
	local d: { [string]: any } = {
		version = 1,
		nonce = NONCE,
		argv = { "suitecloud", "project:deploy" },
		command = "project:deploy",
		program = "/opt/bin/suitecloud",
		cwd = "/work/sdf/billing",
		folder = "/work/sdf/billing/src",
		auth_id = "prod",
		account_id = "1234567",
		account_name = "Example Co",
		account_type = "Production",
		pane = PANE,
		git = {
			root = "/work",
			branch = "main",
			head = string.rep("1", 40),
			dirty = false,
			upstream = "origin/main",
			ahead = 0,
			behind = 0,
			default_branch = "main",
		},
		notes = {},
		files = {
			{ path = "/work/sdf/billing/src/deploy.xml", sha256 = SHA },
			{ path = "/work/sdf/billing/src/Objects/customscript_a.xml", sha256 = SHA },
		},
		fingerprint = FP,
		created_at = CREATED,
		timeout_s = 600,
	}
	if over then
		for k, v in over do
			d[k] = v
		end
	end
	return d
end

type Opts = { doc: { [string]: any }?, config: Config.Config?, now: number?, panes: { string }? }

local function start(opts: Opts?): (State, { Effect })
	local o: Opts = opts or {}
	return Session.init({
		args = { PATH },
		now = o.now or NOW,
		spool = SPOOL,
		request = { text = encode(o.doc or doc()) },
		panes = o.panes or { PANE },
		decode = json.decode,
		config = o.config or cfg(),
	})
end

local function find(effects: { Effect }, kind: string, tag: string?): Effect?
	for _, e in effects do
		if e.t == kind and (tag == nil or e.tag == tag) then
			return e
		end
	end
	return nil
end

local function result(s: State, tag: string, status: number, stdout: string): { Effect }
	local _, effects = Session.update(s, {
		t = "result",
		tag = tag,
		gen = s.gen,
		result = { status = status, stdout = stdout, stderr = "", timed_out = false },
	})
	return effects
end

-- A request whose spool and fingerprint checks passed.
local function ready(opts: Opts?): (State, { Effect })
	local s = start(opts)
	result(s, "spool", 0, SPOOL .. "\n")
	local effects = result(s, "hash", 0, FP .. "  -\n")
	return s, effects
end

local function act(s: State, name: string): { Effect }
	local _, effects = Session.update(s, { t = "action", act = name })
	return effects
end

local function key(s: State, name: string, text: string?): (boolean, { Effect })
	local _, effects, changed = Session.update(s, {
		t = "key",
		key = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false },
	})
	return changed, effects
end

local function typeText(s: State, text: string)
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		key(s, ch, ch)
	end
end

local function response(effects: { Effect }): string?
	local w = find(effects, "write", "respond")
	return if w then w.text else nil
end

describe("checking a request before it can be approved", function()
	it("verifies that the request sits in the plugin's spool and matches its fingerprint", function()
		local s, effects = start()
		expect(s.phase).toBe("verifying")
		local spool = find(effects, "run", "spool")
		assert(spool, "spool check")
		expect((spool.argv :: { string })[5]).toBe(SPOOL)
		local hash = find(effects, "run", "hash")
		assert(hash, "hash run")
		local canonical = Protocol.canonical(Protocol.fingerprintInput((assert(s.request, "request"))))
		expect(hash.stdin).toBe(canonical)
	end)

	it("cannot approve while the checks are still running", function()
		local s = start()
		typeText(s, "PROD")
		expect(response(act(s, "approve"))).toBeNil()
		expect(s.confirmError).toContain("checked")
	end)

	it("refuses to approve a request whose shown contents do not match its fingerprint", function()
		local s = start()
		result(s, "spool", 0, SPOOL .. "\n")
		result(s, "hash", 0, string.rep("cd", 32) .. "  -\n")
		expect(s.phase).toBe("blocked")
		typeText(s, "PROD")
		expect(response(act(s, "approve"))).toBeNil()
		local text = response(act(s, "deny"))
		assert(text, "deny response")
		expect(text).toContain("decision=deny\n")
		expect(text).toContain("reason=")
	end)

	it("never answers a request outside the plugin's spool", function()
		local s = start()
		result(s, "spool", 0, "/elsewhere/tern-netsuite/spool\n")
		expect(s.phase).toBe("error")
		local effects = act(s, "deny")
		expect(response(effects)).toBeNil()
		expect(find(effects, "exit")).toEqual({ t = "exit" })
	end)

	it("does not offer an expired request: the shell has stopped waiting", function()
		local s, effects = start({ now = CREATED + 601 })
		expect(s.phase).toBe("error")
		expect(find(effects, "run")).toBeNil()
		expect(response(act(s, "deny"))).toBeNil()
	end)

	it("does not offer a request whose pane is gone", function()
		local s = start({ panes = { "1" } })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("gone")
	end)

	it("explains an unreadable or malformed request instead of approving it", function()
		local s = Session.init({
			args = { PATH },
			now = NOW,
			spool = SPOOL,
			request = { text = "{" },
			panes = { PANE },
			decode = json.decode,
			config = cfg(),
		})
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("JSON")
	end)
end)

describe("confirming a production target", function()
	it("classifies the account with the user's config and asks to type its label", function()
		local s = ready()
		local target = assert(s.target, "target")
		expect(target.production).toBe(true)
		expect(target.label).toBe("PROD")
		expect(s.typedRequired).toBe(true)
		expect(target.prompt).toBe("PROD")
	end)

	it("focuses the confirmation field once the request is checked", function()
		local _, effects = ready()
		expect(find(effects, "focus")).toEqual({ t = "focus", id = Session.TYPED_INPUT })
	end)

	it("refuses a click without the typed confirmation", function()
		local s = ready()
		expect(response(act(s, "approve"))).toBeNil()
		expect(s.confirmError).toContain("PROD")
		typeText(s, "PRO")
		expect(response(act(s, "approve"))).toBeNil()
	end)

	it("approves with the label or the account id typed, writing a response bound to the request", function()
		for _, typed in { "PROD", "1234567", " prod " } do
			local s = ready()
			typeText(s, typed)
			local effects = act(s, "approve")
			local w = find(effects, "write", "respond")
			assert(w, "write for " .. typed)
			expect(w.path).toBe(SPOOL .. "/resp-" .. NONCE .. ".env.tmp")
			expect(w.text).toBe(Protocol.response({
				nonce = NONCE,
				decision = "approve",
				fingerprint = FP,
				account = "1234567",
				at = NOW,
			}))
			expect((w.argv :: { string })[6]).toBe(SPOOL .. "/resp-" .. NONCE .. ".env")
			expect(s.phase).toBe("responding")
		end
	end)

	it("records the approval in the audit log", function()
		local s = ready()
		typeText(s, "PROD")
		local a = find(act(s, "approve"), "audit")
		assert(a, "audit")
		local line = json.decode(a.line :: string)
		expect(line.decision).toBe("approved")
		expect(line.account_id).toBe("1234567")
		expect(line.production).toBe(true)
		expect(line.files).toBe(2)
	end)

	it("closes the block once the response is written (exit 0 is the only way `tern open --wait` returns)", function()
		local s = ready()
		typeText(s, "PROD")
		act(s, "approve")
		expect(find(result(s, "respond", 0, ""), "exit")).toEqual({ t = "exit" })
		expect(s.phase).toBe("closed")
	end)

	it("keeps the block open with an error when the response cannot be written", function()
		local s = ready()
		typeText(s, "PROD")
		act(s, "approve")
		local effects = result(s, "respond", 1, "")
		expect(find(effects, "exit")).toBeNil()
		expect(s.phase).toBe("error")
	end)

	it("Enter approves only once the typed confirmation matches", function()
		local s = ready()
		local _, effects = key(s, "enter")
		expect(response(effects)).toBeNil()
		typeText(s, "PROD")
		_, effects = key(s, "enter")
		expect(response(effects)).toContain("decision=approve")
	end)

	it("Backspace and paste edit the confirmation", function()
		local s = ready()
		typeText(s, "PROX")
		key(s, "backspace")
		key(s, "paste", "D")
		expect(s.typed).toBe("PROD")
	end)

	it("a click is enough when typed confirmation is turned off", function()
		local s = ready({ config = cfg([[{"guard": {"typed_confirmation": false}}]]) })
		expect(s.typedRequired).toBe(false)
		expect(response(act(s, "approve"))).toContain("decision=approve")
	end)

	it("treats an unknown account as production and asks for the auth ID", function()
		local d = doc()
		d.account_id = nil
		d.account_name = nil
		d.account_type = nil
		local s = ready({ doc = d })
		local target = assert(s.target, "target")
		expect(target.production).toBe(true)
		expect(target.known).toBe(false)
		expect(target.prompt).toBe("prod")
		typeText(s, "prod")
		expect(response(act(s, "approve"))).toContain("account=-\n")
	end)

	it("needs only a click for an account the config marks non-production", function()
		local d = doc({ account_id = "1234567_SB1", auth_id = "sandbox" })
		local s = ready({ doc = d })
		expect(assert(s.target, "target").production).toBe(false)
		expect(s.typedRequired).toBe(false)
		expect(response(act(s, "approve"))).toContain("decision=approve")
	end)
end)

describe("denying", function()
	it("Escape denies so the shell refuses at once instead of waiting for its timeout", function()
		local s = ready()
		local _, effects = key(s, "escape")
		local text = response(effects)
		assert(text, "deny response")
		expect(text).toContain("decision=deny\n")
		expect(json.decode(assert(find(effects, "audit"), "audit").line :: string).decision).toBe("denied")
	end)

	it("the Deny button works before the checks finish", function()
		local s = start()
		expect(response(act(s, "deny"))).toContain("decision=deny")
	end)

	it("decides only once", function()
		local s = ready()
		act(s, "deny")
		expect(response(act(s, "deny"))).toBeNil()
		expect(response(act(s, "approve"))).toBeNil()
	end)
end)

describe("while the block is open", function()
	it("closes without answering when the shell withdraws the request (Ctrl-C or timeout)", function()
		local s = ready()
		local _, effects = Session.update(s, { t = "tick", cancelled = true, paneAlive = true })
		expect(response(effects)).toBeNil()
		expect(find(effects, "remove")).toEqual({ t = "remove", path = SPOOL .. "/cancel-" .. NONCE })
		expect(json.decode(assert(find(effects, "audit"), "audit").line :: string).decision).toBe("cancelled")
		expect(find(effects, "exit")).toEqual({ t = "exit" })
	end)

	it("closes when the requesting pane is gone", function()
		local s = ready()
		local _, effects = Session.update(s, { t = "tick", paneAlive = false })
		expect(find(effects, "exit")).toEqual({ t = "exit" })
		expect(response(effects)).toBeNil()
	end)

	it("stops accepting an approval once the request's deadline passes", function()
		local s = ready()
		typeText(s, "PROD")
		Session.update(s, { t = "tick", now = CREATED + 601, paneAlive = true })
		expect(s.phase).toBe("expired")
		expect(response(act(s, "approve"))).toBeNil()
	end)

	it("reports what the liveness timer must watch until a decision is made", function()
		local s = ready()
		expect(Session.watch(s)).toEqual({ pane = PANE, cancelPath = SPOOL .. "/cancel-" .. NONCE })
		act(s, "deny")
		expect(Session.watch(s)).toEqual({})
	end)

	it("ignores a late process result from a superseded run", function()
		local s = start()
		local _, effects = Session.update(s, {
			t = "result",
			tag = "hash",
			gen = s.gen + 1,
			result = { status = 0, stdout = FP, stderr = "", timed_out = false },
		})
		expect(#effects).toBe(0)
		expect(s.phase).toBe("verifying")
	end)
end)

describe("warnings about the deploy's source", function()
	-- Warnings shown for a request built from `d`.
	local function texts(d: { [string]: any }): string
		local s = ready({ doc = d })
		local out: { string } = {}
		for _, w in s.warnings do
			table.insert(out, w.text)
		end
		return table.concat(out, "\n")
	end

	it("flags uncommitted changes, a stale or unpushed branch and a non-main branch", function()
		local d = doc()
		d.git = {
			root = "/work",
			branch = "feature/x",
			head = string.rep("1", 40),
			dirty = true,
			upstream = "origin/feature/x",
			ahead = 2,
			behind = 3,
			default_branch = "main",
		}
		local w = texts(d)
		expect(w).toContain("Uncommitted changes")
		expect(w).toContain("3 commits behind origin/feature/x")
		expect(w).toContain("2 commits not pushed")
		expect(w).toContain("feature/x, not main")
	end)

	it("flags a detached HEAD", function()
		local d = doc()
		d.git = { root = "/work", head = string.rep("1", 40), dirty = false, default_branch = "main" }
		expect(texts(d)).toContain("Detached HEAD")
	end)

	it("notes a branch without upstream: whether it is current cannot be told", function()
		local d = doc()
		d.git = { root = "/work", branch = "main", head = string.rep("1", 40), dirty = false, default_branch = "main" }
		expect(texts(d)).toContain("no upstream")
	end)

	it("says so when the project is not in a git repository", function()
		local d = doc()
		d.git = nil
		expect(texts(d)).toContain("Not in a git repository")
	end)

	it("passes on the guard's notes", function()
		local w = texts(doc({ notes = { "no deploy.xml in /work" } }))
		expect(w).toContain("no deploy.xml in /work")
	end)

	it("has nothing to say about a clean, current main branch", function()
		expect(#ready().warnings).toBe(0)
	end)
end)

return nil
