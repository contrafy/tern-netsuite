--!strict
-- A unified diff of two small texts (deploy.xml, manifest.xml edits) for
-- the preview. Line-based LCS; texts past MAX_LINES diff as one hunk.

local M = {}

M.CONTEXT = 3
M.MAX_LINES = 2000

type Op = { tag: string, line: string }

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

local function ops(a: { string }, b: { string }): { Op }
	local n, m = #a, #b
	local out: { Op } = {}
	if n > M.MAX_LINES or m > M.MAX_LINES then
		for _, l in a do
			table.insert(out, { tag = "-", line = l })
		end
		for _, l in b do
			table.insert(out, { tag = "+", line = l })
		end
		return out
	end
	-- lcs[i][j]: LCS length of a[i..n] and b[j..m].
	local lcs: { { number } } = table.create(n + 2)
	for i = 1, n + 2 do
		lcs[i] = table.create(m + 2, 0)
	end
	for i = n, 1, -1 do
		local row, below = lcs[i], lcs[i + 1]
		for j = m, 1, -1 do
			if a[i] == b[j] then
				row[j] = below[j + 1] + 1
			else
				row[j] = math.max(below[j], row[j + 1])
			end
		end
	end
	local i, j = 1, 1
	while i <= n and j <= m do
		if a[i] == b[j] then
			table.insert(out, { tag = " ", line = a[i] })
			i += 1
			j += 1
		elseif lcs[i + 1][j] >= lcs[i][j + 1] then
			table.insert(out, { tag = "-", line = a[i] })
			i += 1
		else
			table.insert(out, { tag = "+", line = b[j] })
			j += 1
		end
	end
	for k = i, n do
		table.insert(out, { tag = "-", line = a[k] })
	end
	for k = j, m do
		table.insert(out, { tag = "+", line = b[k] })
	end
	return out
end

local function range(start: number, count: number): string
	if count == 1 then
		return tostring(start)
	end
	return string.format("%d,%d", if count == 0 then start - 1 else start, count)
end

-- "" when the texts are equal.
function M.unified(path: string, from: string, to: string): string
	local list = ops(split(from), split(to))
	local changed: { number } = {}
	for k, op in list do
		if op.tag ~= " " then
			table.insert(changed, k)
		end
	end
	if #changed == 0 then
		return ""
	end
	local out = { "--- a/" .. path, "+++ b/" .. path }
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
		local e = math.min(#list, last + c)
		-- Line numbers of hunk starts: count lines before s on each side.
		local aLine, bLine = 1, 1
		for k = 1, s - 1 do
			local tag = list[k].tag
			if tag ~= "+" then
				aLine += 1
			end
			if tag ~= "-" then
				bLine += 1
			end
		end
		local aCount, bCount = 0, 0
		local body: { string } = {}
		for k = s, e do
			local op = list[k]
			if op.tag ~= "+" then
				aCount += 1
			end
			if op.tag ~= "-" then
				bCount += 1
			end
			table.insert(body, op.tag .. op.line)
		end
		table.insert(out, string.format("@@ -%s +%s @@", range(aLine, aCount), range(bLine, bCount)))
		table.move(body, 1, #body, #out + 1, out)
	end
	return table.concat(out, "\n") .. "\n"
end

return table.freeze(M)
