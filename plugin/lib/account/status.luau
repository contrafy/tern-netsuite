--!strict
-- The status-line segment for a pane inside an SDF project: which account
-- its default auth id deploys to. Production is shown in the error tone;
-- an auth id nothing has resolved yet (lookup pending or failed) shows as
-- `<authId>? (unverified)` in the warning tone: it is not claimed as PROD,
-- but it does not look like a sandbox either, because unknown counts as
-- production everywhere else (the guard). When that account's health checks report
-- errors, a second segment names them (badges come from the health monitor's
-- cache; this module stays pure).

local Context = require("./context")
local Resolve = require("./resolve")

export type Segment = { text: string, icon: string?, tone: string?, command: string? }

local M = {}

M.COMMAND = "plugin.tern-netsuite.doctor"
M.ICON = "cloud"
M.HEALTH_COMMAND = "plugin.tern-netsuite.health"
M.HEALTH_ICON = "activity"

local function segment(text: string, tone: string): Segment
	return { text = text, icon = M.ICON, tone = tone, command = M.COMMAND }
end

-- `badges` maps an upper-case account id to its health badge text.
function M.segments(ctx: Context.Context?, opts: Resolve.Options, badges: { [string]: string }?): { Segment }?
	if ctx == nil or not opts.config.status.enabled then
		return nil
	end
	local prefix = ctx.projectName .. " -> "
	local authId = ctx.authId
	if authId == nil then
		return { segment(prefix .. "no auth id", "muted") }
	end
	local r = Resolve.resolve(authId, opts)
	if r.source == "unknown" then
		return { segment(prefix .. authId .. "? (unverified)", "warning") }
	end
	local main = if r.production
		then segment(
			prefix .. (if string.find(string.upper(r.label), "PROD", 1, true) then r.label else r.label .. " PROD"),
			"error"
		)
		else segment(prefix .. r.label, "muted")
	local badge = if badges and r.accountId then badges[string.upper(r.accountId)] else nil
	if badge == nil then
		return { main }
	end
	return { main, { text = badge, icon = M.HEALTH_ICON, tone = "error", command = M.HEALTH_COMMAND } }
end

return M
