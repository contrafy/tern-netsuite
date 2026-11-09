--!strict
-- The health block's `r` asks the window to poll every check now through
-- `tern-netsuite://health/refresh?grant=<id>`: the block stores a
-- single-use grant (../grant.luau) first, so a link printed by anything
-- else starts no queries. The window also spaces refreshes MIN_SECONDS
-- apart. A refresh never resumes connections paused after an
-- authentication failure: only the connect flow or a config change does.

local Grant = require("../grant")

local M = {}

M.GRANTS_KEY = "health.grants"
M.MIN_SECONDS = 30
M.PREFIX = "tern-netsuite://health/refresh"

function M.url(id: string): string
	return M.PREFIX .. "?grant=" .. id
end

function M.newId(seed: string, counter: number): string
	return Grant.newId("health", seed, counter)
end

-- What a `tern-netsuite://health/...` link asks for: "refresh" with the
-- grant id it carries (nil for a bare or malformed refresh link), or nil.
function M.parse(url: string): (string?, string?)
	local rest = string.match(url, "^tern%-netsuite://health/refresh(.*)$")
	if rest == nil then
		return nil, nil
	end
	local id = string.match(rest, "^%?grant=([a-f0-9]+)$")
	if id and Grant.validId(id) then
		return "refresh", id
	end
	return "refresh", nil
end

-- Takes grant `id`: true when it was live; the remaining grants (store
-- them back).
function M.take(stored: any, id: string, now: number): (boolean, Grant.Grants)
	local data, rest = Grant.take(stored, id, now)
	return data == true, rest
end

-- The grants with a new refresh grant `id`.
function M.add(stored: any, id: string, now: number): Grant.Grants
	return Grant.add(stored, id, true, now)
end

-- Whether a refresh may poll now, `last` being when the previous one did.
function M.allowed(last: number?, now: number): boolean
	return last == nil or now - last >= M.MIN_SECONDS or now < last
end

return table.freeze(M)
