--!strict
local Catalog = require("../../../plugin/lib/inspector/catalog")
local Mention = require("../../../plugin/lib/inspector/mention")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function found(texts: { string }): string?
	local r = Mention.find(texts)
	if r == nil then
		return nil
	end
	return (if r.kind then (r.kind :: Catalog.Kind).record else "rectype") .. ":" .. r.id
end

describe("records mentioned in log lines", function()
	it("finds a record a script logged as a NetSuite URL", function()
		expect(found({
			"after submit",
			"see https://1234567-sb1.app.netsuite.com/app/accounting/transactions/custinvc.nl?id=88&whence= for details",
		})).toBe("invoice:88")
	end)

	it("finds a record a script logged as JSON with a type and an id", function()
		expect(found({ "order.sync", '{"recordType":"salesorder","id":123,"status":"ok"}' })).toBe("salesorder:123")
		expect(found({ "x", '{"type": "customer", "internalid": "42"}' })).toBe("customer:42")
	end)

	it("finds type:id tokens of known record types only", function()
		expect(found({ "processed salesorder:77 in 3 ms" })).toBe("salesorder:77")
		expect(found({ "box customrecord_acme_box:5" })).toBe("customrecord_acme_box:5")
	end)

	it("offers nothing for times, namespaces or unknown types, so the chip never misleads", function()
		expect(found({ "suiteql:exec.done", '{"count":3}' })).toBeNil()
		expect(found({ "2026-10-08T22:15:40", "retry:3 widget:5" })).toBeNil()
		expect(found({ '{"type":"error","id":5}' })).toBeNil()
	end)
end)

return nil
