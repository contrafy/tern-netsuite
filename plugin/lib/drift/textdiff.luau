--!strict
-- Unified diffs of a project copy against an account copy, for the drift
-- view (`{k = "diff"}` nodes). Files can be large and usually differ in a
-- few lines, so the common head and tail are skipped first and the middle
-- goes through Myers' O((N+M)·D) algorithm; past MAX_EDITS edits, or a
-- middle longer than MAX_LINES, the middle becomes one replace hunk. A
-- missing trailing newline is not a difference (NetSuite exports have
-- none).

local M = {}

M.CONTEXT = 3
M.MAX_EDITS = 1000
M.MAX_LINES = 20000
-- Default cap of the diff text; hunks past it are dropped.
M.MAX_BYTES = 256 * 1024

export type Options = { maxBytes: number? }

export type Result = {
	-- "" when the texts have the same lines.
	text: string,
	truncated: boolean,
}

local function split(text: string): { string }
	if text == "" then
		return {}
	end
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- Myers' shortest edit script between a[lo1..hi1] and b[lo2..hi2] as tags
-- (" ", "-", "+") in order, or nil past MAX_EDITS.
local function myers(a: { string }, lo1: number, hi1: number, b: { string }, lo2: number, hi2: number): { string }?
	local n, m = hi1 - lo1 + 1, hi2 - lo2 + 1
	local v: { [number]: number } = { [1] = 0 }
	local trace: { { [number]: number } } = {}
	local found = false
	for d = 0, math.min(n + m, M.MAX_EDITS) do
		table.insert(trace, table.clone(v))
		for k = -d, d, 2 do
			local x: number
			if k == -d or (k ~= d and (v[k - 1] :: number) < (v[k + 1] :: number)) then
				x = v[k + 1] :: number
			else
				x = (v[k - 1] :: number) + 1
			end
			local y = x - k
			while x < n and y < m and a[lo1 + x] == b[lo2 + y] do
				x += 1
				y += 1
			end
			v[k] = x
			if x >= n and y >= m then
				found = true
				break
			end
		end
		if found then
			break
		end
	end
	if not found then
		return nil
	end
	local rev: { string } = {}
	local x, y = n, m
	for d = #trace - 1, 0, -1 do
		local tv = trace[d + 1]
		local k = x - y
		local prevK = if k == -d or (k ~= d and (tv[k - 1] :: number) < (tv[k + 1] :: number)) then k + 1 else k - 1
		local prevX = if d == 0 then 0 else tv[prevK] :: number
		local prevY = prevX - prevK
		if d == 0 then
			prevX, prevY = 0, 0
		end
		while x > prevX and y > prevY do
			table.insert(rev, " ")
			x -= 1
			y -= 1
		end
		if d > 0 then
			table.insert(rev, if x == prevX then "+" else "-")
		end
		x, y = prevX, prevY
	end
	local out: { string } = table.create(#rev)
	for i = #rev, 1, -1 do
		table.insert(out, rev[i])
	end
	return out
end

local function tags(a: { string }, b: { string }): { string }
	local n, m = #a, #b
	local head = 0
	while head < n and head < m and a[head + 1] == b[head + 1] do
		head += 1
	end
	local tail = 0
	while tail < n - head and tail < m - head and a[n - tail] == b[m - tail] do
		tail += 1
	end
	local out: { string } = table.create(n + m, " ")
	local count = head
	for i = 1, head do
		out[i] = " "
	end
	local lo1, hi1, lo2, hi2 = head + 1, n - tail, head + 1, m - tail
	local middle: { string }? = nil
	if (hi1 - lo1 + 1) + (hi2 - lo2 + 1) <= M.MAX_LINES then
		middle = myers(a, lo1, hi1, b, lo2, hi2)
	end
	if middle == nil then
		local replace: { string } = {}
		for _ = lo1, hi1 do
			table.insert(replace, "-")
		end
		for _ = lo2, hi2 do
			table.insert(replace, "+")
		end
		middle = replace
	end
	for _, tag in middle :: { string } do
		count += 1
		out[count] = tag
	end
	for _ = 1, tail do
		count += 1
		out[count] = " "
	end
	for i = #out, count + 1, -1 do
		out[i] = nil
	end
	return out
end

local function range(start: number, count: number): string
	if count == 1 then
		return tostring(start)
	end
	return string.format("%d,%d", if count == 0 then start - 1 else start, count)
end

-- The unified diff from the project copy to the account copy of `path`.
function M.unified(path: string, projectText: string, accountText: string, opts: Options?): Result
	local a, b = split(projectText), split(accountText)
	local ops = tags(a, b)
	local changed: { number } = {}
	for i, tag in ops do
		if tag ~= " " then
			table.insert(changed, i)
		end
	end
	if #changed == 0 then
		return { text = "", truncated = false }
	end
	local maxBytes = (opts and opts.maxBytes) or M.MAX_BYTES
	local out = { "--- project/" .. path, "+++ account/" .. path }
	local size = #out[1] + #out[2] + 2
	local truncated = false
	-- Line numbers before ops[pos] on each side, advanced as hunks are cut.
	local pos, aLine, bLine = 1, 1, 1
	local c = M.CONTEXT
	local idx = 1
	while idx <= #changed do
		local first = changed[idx]
		local last = first
		while idx < #changed and changed[idx + 1] - last <= 2 * c do
			idx += 1
			last = changed[idx]
		end
		idx += 1
		local s = math.max(1, first - c)
		local e = math.min(#ops, last + c)
		while pos < s do
			local tag = ops[pos]
			if tag ~= "+" then
				aLine += 1
			end
			if tag ~= "-" then
				bLine += 1
			end
			pos += 1
		end
		local body: { string } = {}
		local aCount, bCount = 0, 0
		local ai, bi = aLine, bLine
		for k = s, e do
			local tag = ops[k]
			if tag == " " then
				table.insert(body, " " .. a[ai])
				ai += 1
				bi += 1
				aCount += 1
				bCount += 1
			elseif tag == "-" then
				table.insert(body, "-" .. a[ai])
				ai += 1
				aCount += 1
			else
				table.insert(body, "+" .. b[bi])
				bi += 1
				bCount += 1
			end
		end
		local header = string.format("@@ -%s +%s @@", range(aLine, aCount), range(bLine, bCount))
		local hunkSize = #header + 1
		for _, l in body do
			hunkSize += #l + 1
		end
		if size + hunkSize > maxBytes then
			truncated = true
			break
		end
		size += hunkSize
		table.insert(out, header)
		table.move(body, 1, #body, #out + 1, out)
	end
	return { text = table.concat(out, "\n") .. "\n", truncated = truncated }
end

return table.freeze(M)
