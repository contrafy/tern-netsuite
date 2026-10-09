--!strict
-- The rows the log tail holds: ordered by time then internal id, deduped by
-- internal id (polls re-read an overlap window), capped at `cap` rows with
-- the oldest dropped first. Functions return a new buffer.

local Entry = require("./entry")

type Entry = Entry.Entry

local M = {}

export type Buffer = {
	-- Oldest first.
	entries: { Entry },
	-- Internal id -> logged, for every row a later poll may return again
	-- (including rows dropped by the cap); pruned to the poll window.
	seen: { [number]: string },
	-- The newest `logged` seen; nil before the first row.
	watermark: string?,
	cap: number,
	-- Rows dropped by the cap since the buffer was created.
	dropped: number,
}

M.DEFAULT_CAP = 2000

function M.new(cap: number?): Buffer
	return { entries = {}, seen = {}, watermark = nil, cap = math.max(1, cap or M.DEFAULT_CAP), dropped = 0 }
end

local function before(a: Entry, b: Entry): boolean
	if a.logged ~= b.logged then
		return a.logged < b.logged
	end
	return a.id < b.id
end

-- `b` plus the rows of `list` it has not seen; also returns how many were
-- new.
function M.merge(b: Buffer, list: { Entry }): (Buffer, number)
	local seen = table.clone(b.seen)
	local fresh: { Entry } = {}
	local watermark = b.watermark
	for _, e in list do
		if seen[e.id] == nil then
			seen[e.id] = e.logged
			table.insert(fresh, e)
			if watermark == nil or e.logged > watermark then
				watermark = e.logged
			end
		end
	end
	if #fresh == 0 then
		return b, 0
	end
	local entries = table.clone(b.entries)
	local last = entries[#entries]
	table.sort(fresh, before)
	local inOrder = last == nil or not before(fresh[1], last)
	table.move(fresh, 1, #fresh, #entries + 1, entries)
	if not inOrder then
		table.sort(entries, before)
	end
	local over = #entries - b.cap
	if over > 0 then
		entries = table.move(entries, over + 1, #entries, 1, table.create(b.cap))
	end
	return {
		entries = entries,
		seen = seen,
		watermark = watermark,
		cap = b.cap,
		dropped = b.dropped + math.max(over, 0),
	},
		#fresh
end

-- Forgets dedupe ids logged before `from` (the next poll cannot return them).
function M.prune(b: Buffer, from: string): Buffer
	local seen: { [number]: string } = {}
	for id, logged in b.seen do
		if logged >= from then
			seen[id] = logged
		end
	end
	return { entries = b.entries, seen = seen, watermark = b.watermark, cap = b.cap, dropped = b.dropped }
end

return M
