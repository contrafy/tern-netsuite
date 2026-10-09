--!strict
local Crypto = require("../../../plugin/lib/ns/crypto")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function sha(msg: string): string
	return Crypto.hex(Crypto.sha256(msg))
end

local function hmac(key: string, msg: string): string
	return Crypto.hex(Crypto.hmacSha256(key, msg))
end

local function bytes(from: number, to: number): string
	local out = {}
	for b = from, to do
		table.insert(out, string.char(b))
	end
	return table.concat(out)
end

describe("SHA-256, which every TBA request signature depends on", function()
	it("matches the FIPS 180-4 example digests", function()
		expect(sha("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
		expect(sha("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
		expect(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).toBe(
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
		)
	end)

	it("pads correctly at every block boundary, where off-by-one bugs hide", function()
		expect(sha(string.rep("a", 55))).toBe("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
		expect(sha(string.rep("a", 56))).toBe("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
		expect(sha(string.rep("a", 64))).toBe("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
		expect(sha(string.rep("a", 119))).toBe("31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb")
	end)

	it("hashes a million bytes, so large request bodies sign correctly", function()
		expect(sha(string.rep("a", 1000000))).toBe("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
	end)

	it("hashes UTF-8 bytes, not characters", function()
		expect(sha("é✓")).toBe("1e77cb71920ad52885fab06465a5fcf2e5f98c0382aab36202689431b93b9fb3")
	end)
end)

describe("HMAC-SHA256 (RFC 4231 test cases)", function()
	it("case 1: short key", function()
		expect(hmac(string.rep(string.char(0x0b), 20), "Hi There")).toBe(
			"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
		)
	end)

	it("case 2: key shorter than the output", function()
		expect(hmac("Jefe", "what do ya want for nothing?")).toBe(
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
		)
	end)

	it("case 3 and 4: binary keys and data", function()
		expect(hmac(string.rep(string.char(0xaa), 20), string.rep(string.char(0xdd), 50))).toBe(
			"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
		)
		expect(hmac(bytes(1, 25), string.rep(string.char(0xcd), 50))).toBe(
			"82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
		)
	end)

	it("case 6 and 7: keys longer than a block are hashed first", function()
		local key = string.rep(string.char(0xaa), 131)
		expect(hmac(key, "Test Using Larger Than Block-Size Key - Hash Key First")).toBe(
			"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
		)
		expect(
			hmac(
				key,
				"This is a test using a larger than block-size key and a larger than block-size data. "
					.. "The key needs to be hashed before being used by the HMAC algorithm."
			)
		).toBe("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
	end)
end)

return nil
