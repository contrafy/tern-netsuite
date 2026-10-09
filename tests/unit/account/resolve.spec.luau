--!strict
local Config = require("../../../plugin/lib/config")
local Resolve = require("../../../plugin/lib/account/resolve")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CFG = Config.parse(
	'{"accounts": [{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"]},'
		.. ' {"id": "prod", "label": "PROD", "account_id": "1234567", "production": true, "auth_ids": ["demo-prod"]}]}',
	json.decode
)
local NONE = Config.defaults()
local TTL = Resolve.TTL_MS

local function cached(authId: string, accountId: string?, at: number, err: string?): Resolve.Cache
	return { [authId] = { authId = authId, accountId = accountId, at = at, error = err } }
end

describe("resolving an auth id to an account", function()
	it("uses the config first, without asking the CLI", function()
		local r = Resolve.resolve("demo-prod", { config = CFG, cache = {}, now = 0 })
		expect(r.source).toBe("configured")
		expect(r.production).toBe(true)
		expect(r.label).toBe("PROD")
		expect(Resolve.needsLookup("demo-prod", { config = CFG, cache = {}, now = 0 })).toBe(false)
	end)

	it("prefers the config over a cached CLI answer that disagrees", function()
		local r = Resolve.resolve("demo-sb", { config = CFG, cache = cached("demo-sb", "7654321", 0), now = 1 })
		expect(r.accountId).toBe("1234567_SB1")
	end)

	it("uses a fresh cached CLI answer for an auth id the config does not list", function()
		local r = Resolve.resolve("other", { config = CFG, cache = cached("other", "1234567_SB1", 1000), now = 2000 })
		expect(r.source).toBe("cli")
		expect(r.production).toBe(false)
		expect(r.label).toBe("SB1")
	end)

	it("labels a cached account the config does not know by its id", function()
		local r = Resolve.resolve("x", { config = NONE, cache = cached("x", "7777777_SB2", 0), now = 1 })
		expect(r.label).toBe("7777777_SB2")
		expect(r.production).toBe(false)
	end)

	it("fails closed for an unknown auth id: unresolved counts as production", function()
		local r = Resolve.resolve("mystery", { config = CFG, cache = {}, now = 0 })
		expect(r.source).toBe("unknown")
		expect(r.production).toBe(true)
		expect(r.accountId).toBeNil()
		expect(Resolve.needsLookup("mystery", { config = CFG, cache = {}, now = 0 })).toBe(true)
	end)

	it("keeps a CLI error as unknown with its reason", function()
		local r = Resolve.resolve("gone", { config = NONE, cache = cached("gone", nil, 0, "not available"), now = 1 })
		expect(r.source).toBe("unknown")
		expect(r.production).toBe(true)
		expect(r.problem).toBe("not available")
	end)
end)

describe("cache lifetime", function()
	it("stops trusting a cached answer after the TTL, as the auth id may have been set up again", function()
		local r = Resolve.resolve("other", { config = NONE, cache = cached("other", "1234567_SB1", 0), now = TTL })
		expect(r.source).toBe("unknown")
		expect(r.production).toBe(true)
	end)

	it("refreshes well before expiry so the status line does not flicker to unknown", function()
		local opts = { config = NONE, cache = cached("other", "1234567_SB1", 0), now = TTL / 2 - 1 }
		expect(Resolve.needsLookup("other", opts)).toBe(false)
		opts.now = TTL / 2
		expect(Resolve.needsLookup("other", opts)).toBe(true)
		expect(Resolve.resolve("other", opts).source).toBe("cli")
	end)

	it("retries a failed lookup soon, since a new auth id may just have been set up", function()
		local opts = { config = NONE, cache = cached("gone", nil, 0, "nope"), now = Resolve.ERROR_TTL_MS - 1 }
		expect(Resolve.needsLookup("gone", opts)).toBe(false)
		opts.now = Resolve.ERROR_TTL_MS
		expect(Resolve.needsLookup("gone", opts)).toBe(true)
	end)

	it("honours a custom TTL", function()
		local opts = { config = NONE, cache = cached("o", "1_SB1", 0), now = 50, ttl = 40 }
		expect(Resolve.resolve("o", opts).source).toBe("unknown")
	end)
end)

describe("storing answers", function()
	it("stores an --info answer without mutating the previous cache", function()
		local before: Resolve.Cache = {}
		local after = Resolve.store(before, Resolve.fromInfo({ authId = "a", accountId = "1_SB1" }, 5))
		expect(before.a).toBeNil()
		expect(after.a.accountId).toBe("1_SB1")
		expect(after.a.at).toBe(5)
	end)

	it("stores a failure as an entry without an account", function()
		local after = Resolve.store({}, Resolve.fromError("a", "boom", 9))
		expect(after.a.accountId).toBeNil()
		expect(after.a.error).toBe("boom")
	end)

	it("keeps a still-valid account when a refresh fails, so a PROD account never drops to unknown", function()
		local good = Resolve.store({}, Resolve.fromInfo({ authId = "p", accountId = "1234567" }, 0))
		local now = TTL / 2 + 10
		local after = Resolve.store(good, Resolve.fromError("p", "timed out", now))
		local r = Resolve.resolve("p", { config = NONE, cache = after, now = now + 1 })
		expect(r.source).toBe("cli")
		expect(r.accountId).toBe("1234567")
		expect(r.production).toBe(true)
	end)

	it("retries a failed refresh on the error schedule, not the success one", function()
		local good = Resolve.store({}, Resolve.fromInfo({ authId = "p", accountId = "1_SB1" }, 0))
		local failedAt = TTL / 2
		local after = Resolve.store(good, Resolve.fromError("p", "boom", failedAt))
		local opts = { config = NONE, cache = after, now = failedAt + Resolve.ERROR_TTL_MS - 1 }
		expect(Resolve.needsLookup("p", opts)).toBe(false)
		opts.now = failedAt + Resolve.ERROR_TTL_MS
		expect(Resolve.needsLookup("p", opts)).toBe(true)
	end)

	it("fails closed once the kept account expires and the refresh still fails", function()
		local good = Resolve.store({}, Resolve.fromInfo({ authId = "p", accountId = "1_SB1" }, 0))
		local after = Resolve.store(good, Resolve.fromError("p", "boom", TTL / 2))
		local r = Resolve.resolve("p", { config = NONE, cache = after, now = TTL })
		expect(r.source).toBe("unknown")
		expect(r.production).toBe(true)
		expect(r.accountId).toBeNil()
	end)

	it("replaces an expired account with the failure, which then retries on the error schedule", function()
		local good = Resolve.store({}, Resolve.fromInfo({ authId = "p", accountId = "1_SB1" }, 0))
		local after = Resolve.store(good, Resolve.fromError("p", "boom", TTL))
		expect(after.p.accountId).toBeNil()
		local r = Resolve.resolve("p", { config = NONE, cache = after, now = TTL + 1 })
		expect(r.source).toBe("unknown")
		expect(r.problem).toBe("boom")
	end)

	it("a later success clears the recorded refresh failure", function()
		local cache = Resolve.store({}, Resolve.fromInfo({ authId = "p", accountId = "1_SB1" }, 0))
		cache = Resolve.store(cache, Resolve.fromError("p", "boom", TTL / 2))
		cache = Resolve.store(cache, Resolve.fromInfo({ authId = "p", accountId = "1_SB1" }, TTL / 2 + 5))
		expect(cache.p.error).toBeNil()
		expect(Resolve.needsLookup("p", { config = NONE, cache = cache, now = TTL / 2 + 6 })).toBe(false)
	end)
end)

return nil
