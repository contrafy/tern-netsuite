--!strict
local Config = require("../../../plugin/lib/config")
local Connect = require("../../../plugin/lib/ns/connect")
local Encoding = require("../../../plugin/lib/ns/encoding")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local cfg = Config.parse(fixtures.read("examples/config.json"), json.decode)

local function key(name: string, text: string?, mods: { [string]: boolean }?): { [string]: any }
	local k: { [string]: any } = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
	for m, v in (mods or {}) :: { [string]: boolean } do
		k[m] = v
	end
	return k
end

local function typeText(s: Connect.State, text: string): Connect.State
	for i = 1, #text do
		local c = string.sub(text, i, i)
		s = Connect.key(s, key(c, c))
	end
	return s
end

local function contains(view: any, needle: string): boolean
	return string.find(Encoding.json(view), needle, 1, true) ~= nil
end

describe("the connect block", function()
	local targets = Connect.targets(cfg)

	it("offers every configured connection with its account", function()
		expect(#targets).toBe(1)
		expect(targets[1].id).toBe("sandbox-restlet")
		expect(targets[1].account_id).toBe("1234567_SB1")
		expect(targets[1].production).toBe(false)
	end)

	it("never shows, saves or keeps typed secrets anywhere but its live state", function()
		local s = Connect.new(targets)
		s = typeText(s, "secret-consumer-key")
		local view = Connect.view(s)
		expect(contains(view, "secret-consumer-key")).toBe(false)
		expect(contains(view, "•")).toBe(true)
		expect(Encoding.json(Connect.saved(s))).toBe('{"connection":"sandbox-restlet"}')
	end)

	it("walks the fields with Tab and Enter and saves from the last one", function()
		local s = Connect.new(targets)
		local effect
		for _, v in { "ck", "cs", "ti" } do
			s = typeText(s, v)
			s, effect = Connect.key(s, key("enter"))
			expect(effect).toBeNil()
		end
		s = typeText(s, "ts")
		s, effect = Connect.key(s, key("enter"))
		expect(effect).toBe("save")
		local values = Connect.collect(s)
		expect(values).toEqual({ consumer_key = "ck", consumer_secret = "cs", token_id = "ti", token_secret = "ts" })
	end)

	it("drops whitespace pasted into single-line fields, a common copy-paste accident", function()
		local s = Connect.new(targets)
		s = Connect.key(s, key("paste", "  abc\n"))
		s = Connect.key(s, key("backspace"))
		expect(s.values.consumer_key).toBe("ab")
		s = Connect.key(s, key("u", "u", { ctrl = true }))
		expect(s.values.consumer_key).toBe("")
	end)

	it("keeps line breaks in a pasted PEM key for machine-to-machine connections", function()
		local m2m: Connect.Target = table.clone(targets[1])
		m2m.auth = "oauth2_m2m"
		local s = Connect.new({ m2m })
		s = Connect.event(s, "field", "3")
		s = Connect.key(s, key("paste", "-----BEGIN PRIVATE KEY-----\r\nAAA\r\n-----END PRIVATE KEY-----"))
		expect(s.values.private_key).toBe("-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----")
	end)

	it("reports which field is missing before anything is stored", function()
		local s = typeText(Connect.new(targets), "ck")
		local values, why = Connect.collect(s)
		expect(values).toBeNil()
		expect(why).toBe("Consumer secret is empty")
	end)

	it("forgets typed values when switching connections, so they cannot land on the wrong one", function()
		local two = { targets[1], table.clone(targets[1]) }
		two[2].id = "other"
		local s = typeText(Connect.new(two), "abc")
		s = Connect.event(s, "conn", "other")
		expect(Connect.target(s) and (Connect.target(s) :: Connect.Target).id).toBe("other")
		expect(s.values.consumer_key).toBeNil()
	end)

	it("shows normalized errors with their kind and code", function()
		local s = Connect.settle(Connect.new(targets), {
			tone = "error",
			text = "Test failed",
			error = { kind = "auth", message = "Invalid login attempt.", code = "INVALID_LOGIN_ATTEMPT", status = 401 },
		})
		local view = Connect.view(s)
		expect(contains(view, "authentication")).toBe(true)
		expect(contains(view, "INVALID_LOGIN_ATTEMPT")).toBe(true)
	end)

	it("explains how to add a connection when none is configured", function()
		local view = Connect.view(Connect.new({}))
		expect(contains(view, "connections[]")).toBe(true)
	end)

	it("ignores clicks on actions while a save or test is running", function()
		local s = Connect.busy(Connect.new(targets), "testing", "Testing...")
		local _, effect = Connect.event(s, "save", nil)
		expect(effect).toBeNil()
	end)
end)

return nil
