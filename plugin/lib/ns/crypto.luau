--!strict
-- SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104) over byte strings. Tern
-- exposes no hash primitive, and OAuth 1.0a TBA signs every NetSuite request
-- with HMAC-SHA256, so the client needs its own.

local M = {}

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rrotate, rshift = bit32.rrotate, bit32.rshift

local K = {
	0x428a2f98,
	0x71374491,
	0xb5c0fbcf,
	0xe9b5dba5,
	0x3956c25b,
	0x59f111f1,
	0x923f82a4,
	0xab1c5ed5,
	0xd807aa98,
	0x12835b01,
	0x243185be,
	0x550c7dc3,
	0x72be5d74,
	0x80deb1fe,
	0x9bdc06a7,
	0xc19bf174,
	0xe49b69c1,
	0xefbe4786,
	0x0fc19dc6,
	0x240ca1cc,
	0x2de92c6f,
	0x4a7484aa,
	0x5cb0a9dc,
	0x76f988da,
	0x983e5152,
	0xa831c66d,
	0xb00327c8,
	0xbf597fc7,
	0xc6e00bf3,
	0xd5a79147,
	0x06ca6351,
	0x14292967,
	0x27b70a85,
	0x2e1b2138,
	0x4d2c6dfc,
	0x53380d13,
	0x650a7354,
	0x766a0abb,
	0x81c2c92e,
	0x92722c85,
	0xa2bfe8a1,
	0xa81a664b,
	0xc24b8b70,
	0xc76c51a3,
	0xd192e819,
	0xd6990624,
	0xf40e3585,
	0x106aa070,
	0x19a4c116,
	0x1e376c08,
	0x2748774c,
	0x34b0bcb5,
	0x391c0cb3,
	0x4ed8aa4a,
	0x5b9cca4f,
	0x682e6ff3,
	0x748f82ee,
	0x78a5636f,
	0x84c87814,
	0x8cc70208,
	0x90befffa,
	0xa4506ceb,
	0xbef9a3f7,
	0xc67178f2,
}

local BLOCK = 64

local function compress(h: { number }, msg: string, offset: number, w: { number })
	for i = 1, 16 do
		local p = offset + (i - 1) * 4
		local b1, b2, b3, b4 = string.byte(msg, p, p + 3)
		w[i] = bor(bit32.lshift(b1, 24), bit32.lshift(b2, 16), bit32.lshift(b3, 8), b4)
	end
	for i = 17, 64 do
		local w15, w2 = w[i - 15], w[i - 2]
		local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
		local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
		w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
	end
	local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
	for i = 1, 64 do
		local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
		local ch = bxor(band(e, f), band(bnot(e), g))
		local t1 = hh + s1 + ch + K[i] + w[i]
		local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
		local maj = bxor(band(a, b), band(a, c), band(b, c))
		local t2 = s0 + maj
		hh, g, f, e = g, f, e, band(d + t1, 0xffffffff)
		d, c, b, a = c, b, a, band(t1 + t2, 0xffffffff)
	end
	h[1] = band(h[1] + a, 0xffffffff)
	h[2] = band(h[2] + b, 0xffffffff)
	h[3] = band(h[3] + c, 0xffffffff)
	h[4] = band(h[4] + d, 0xffffffff)
	h[5] = band(h[5] + e, 0xffffffff)
	h[6] = band(h[6] + f, 0xffffffff)
	h[7] = band(h[7] + g, 0xffffffff)
	h[8] = band(h[8] + hh, 0xffffffff)
end

-- The raw 32-byte digest of `msg`.
function M.sha256(msg: string): string
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	local len = #msg
	local zeros = (BLOCK - (len + 9) % BLOCK) % BLOCK
	local bits = len * 8
	local hi = math.floor(bits / 0x100000000)
	local padded = msg .. "\128" .. string.rep("\0", zeros) .. string.pack(">I4I4", hi, bits % 0x100000000)
	local w = table.create(64, 0)
	for offset = 1, #padded, BLOCK do
		compress(h, padded, offset, w)
	end
	return string.pack(">I4I4I4I4I4I4I4I4", h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
end

-- The raw 32-byte HMAC-SHA256 of `msg` under `key`.
function M.hmacSha256(key: string, msg: string): string
	if #key > BLOCK then
		key = M.sha256(key)
	end
	key ..= string.rep("\0", BLOCK - #key)
	local inner = table.create(BLOCK, "")
	local outer = table.create(BLOCK, "")
	for i = 1, BLOCK do
		local b = string.byte(key, i)
		inner[i] = string.char(bxor(b, 0x36))
		outer[i] = string.char(bxor(b, 0x5c))
	end
	return M.sha256(table.concat(outer) .. M.sha256(table.concat(inner) .. msg))
end

-- Lowercase hex of `bytes`.
function M.hex(bytes: string): string
	return (string.gsub(bytes, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

return M
