--!strict
-- Values the deployment editor offers for a script deployment's
-- <loglevel> and <status> in an SDF object file. Every script object type
-- in the SuiteCloud CLI's sdf_metadata.xml (2026.2) types them with the
-- same lists, script_loglevel and script_status; what is offered is the
-- subset the NetSuite UI lets a user pick for that type:
--   * log levels: script_loglevel without INTERNAL and SYSTEM (as in
--     lib/scaffold/kinds.luau);
--   * scheduled and map/reduce deployments: NOTSCHEDULED, TESTING, and
--     SCHEDULED only when the deployment has a <recurrence> (a schedule);
--     COMPLETED, INPROGRESS and INQUEUE are run states, never set by hand;
--   * every other script type: TESTING, RELEASED.

local M = {}

export type Field = "loglevel" | "status"

M.FIELDS = table.freeze({ "loglevel", "status" } :: { Field })

M.LABELS = table.freeze({ loglevel = "log level", status = "status" } :: { [string]: string })

M.LOG_LEVELS = table.freeze({ "DEBUG", "AUDIT", "ERROR", "EMERGENCY" })

local QUEUED: { [string]: boolean } = { scheduledscript = true, mapreducescript = true }

-- Script object root tags whose deployments carry loglevel and status.
local SCRIPT_TAGS: { [string]: boolean } = {
	bundleinstallationscript = true,
	clientscript = true,
	customrecordactionscript = true,
	mapreducescript = true,
	massupdatescript = true,
	portlet = true,
	restlet = true,
	scheduledscript = true,
	sdfinstallationscript = true,
	suitelet = true,
	usereventscript = true,
	workflowactionscript = true,
}

-- The values `field` may take in a deployment of an object with root tag
-- `tag`, or nil and why it cannot be edited.
function M.allowed(tag: string, field: Field, recurrence: boolean): ({ string }?, string?)
	if not SCRIPT_TAGS[tag] then
		return nil, string.format("<%s> is not a script object with deployments", tag)
	end
	if field == "loglevel" then
		return table.clone(M.LOG_LEVELS), nil
	end
	if QUEUED[tag] then
		local out = { "NOTSCHEDULED", "TESTING" }
		if recurrence then
			table.insert(out, 2, "SCHEDULED")
		end
		return out, nil
	end
	return { "TESTING", "RELEASED" }, nil
end

return table.freeze(M)
