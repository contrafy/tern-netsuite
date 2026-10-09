--!strict
-- NetSuite timestamps as "naive" seconds: the wall-clock fields counted as
-- if they were UTC. SuiteQL returns times in the account's or user's time
-- zone without saying which, so ages are only ever computed against the
-- server's own SYSDATE parsed the same way (see checks.luau), never against
-- the local clock.

export type Stamp = {
	t: number,
	-- The value had no time of day (an unformatted SuiteQL date column).
	dateOnly: boolean,
}

local M = {}

local function leap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function validDay(y: number, m: number, d: number): boolean
	if m < 1 or m > 12 or d < 1 then
		return false
	end
	local max = if m == 2 and leap(y) then 29 else DAYS[m]
	return d <= max
end

-- Days since 1970-01-01 (proleptic Gregorian; Howard Hinnant's algorithm).
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function stamp(y: number, m: number, d: number, h: number, mi: number, s: number, dateOnly: boolean): Stamp?
	if not validDay(y, m, d) or h > 23 or mi > 59 or s > 59 then
		return nil
	end
	return { t = daysFromCivil(y, m, d) * 86400 + h * 3600 + mi * 60 + s, dateOnly = dateOnly }
end

local function n(s: string?): number
	return if s and s ~= "" then tonumber(s) :: number else 0
end

-- `HH:MM[:SS] [am|pm]` -> hour, minute, second; nil when invalid.
local function clock(text: string): (number?, number, number)
	local h, mi, s, ampm = string.match(text, "^(%d%d?):(%d%d):?(%d?%d?)%s*(%a*)$")
	if h == nil then
		return nil, 0, 0
	end
	local hour = n(h)
	local suffix = string.lower(ampm :: string)
	if suffix == "am" or suffix == "pm" then
		if hour < 1 or hour > 12 then
			return nil, 0, 0
		end
		hour = hour % 12 + (if suffix == "pm" then 12 else 0)
	elseif suffix ~= "" then
		return nil, 0, 0
	end
	return hour, n(mi), n(s)
end

-- Reads `YYYY-MM-DD[( |T)HH[:MI[:SS[.fff]]][Z]]` and `M/D/YYYY[ h:mm[:ss][ am|pm]]`.
function M.parse(v: any): Stamp?
	if type(v) ~= "string" then
		return nil
	end
	local text = string.gsub(string.gsub(v, "^%s+", ""), "%s+$", "")
	local y, m, d, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if y then
		if rest == "" then
			return stamp(n(y), n(m), n(d), 0, 0, 0, true)
		end
		local hh, tail = string.match(rest :: string, "^[ T](%d%d)(.*)$")
		if hh == nil then
			return nil
		end
		local clean = string.gsub(string.gsub(tail :: string, "Z$", ""), "%.%d+$", "")
		if clean == "" then
			return stamp(n(y), n(m), n(d), n(hh), 0, 0, false)
		end
		local mi, s = string.match(clean, "^:(%d%d):?(%d?%d?)$")
		if mi == nil then
			return nil
		end
		return stamp(n(y), n(m), n(d), n(hh), n(mi), n(s), false)
	end
	local mo, da, yr, time = string.match(text, "^(%d%d?)/(%d%d?)/(%d%d%d%d)%s*(.*)$")
	if mo == nil then
		return nil
	end
	if time == "" then
		return stamp(n(yr), n(mo), n(da), 0, 0, 0, true)
	end
	local h, mi, s = clock(time :: string)
	if h == nil then
		return nil
	end
	return stamp(n(yr), n(mo), n(da), h, mi, s, false)
end

-- `YYYY-MM-DD HH:MM:SS` of naive seconds `t`.
function M.format(t: number): string
	local days = t // 86400
	local secs = t - days * 86400
	-- Inverse of daysFromCivil.
	local z = days + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	if m <= 2 then
		y += 1
	end
	return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, m, d, secs // 3600, (secs % 3600) // 60, secs % 60)
end

return M
