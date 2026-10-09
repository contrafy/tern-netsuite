--!strict
-- The SuiteScript 2.1 script types the scaffolder creates, with the SDF
-- object shape of each. Element sets come from the SDK's own metadata
-- (sdf_metadata.xml in the SuiteCloud CLI jar, 2026.1): only usereventscript
-- and clientscript deployments take <recordtype> and neither has a <title>;
-- mapreducescript and scheduledscript have no <notifyuser> and no audience.

export type ScriptType = "userevent" | "suitelet" | "restlet" | "mapreduce" | "scheduled" | "clientscript"

export type Kind = {
	id: ScriptType,
	label: string,
	-- Root tag of the SDF object.
	tag: string,
	-- @NScriptType value.
	nScriptType: string,
	-- Entry points of the built-in skeleton, in source order.
	entryPoints: { string },
	-- The object has <notifyuser>.
	notifyUser: boolean,
	-- The deployment has an audience (<allroles>).
	audience: boolean,
	-- The deployment requires <recordtype>.
	recordType: boolean,
	-- The deployment requires <title>.
	title: boolean,
	-- Deployment statuses a new script may start in; the first is the default.
	statuses: { string },
}

local M = {}

-- ScriptType ids in palette order.
M.ORDER = table.freeze({
	"userevent",
	"clientscript",
	"suitelet",
	"restlet",
	"mapreduce",
	"scheduled",
} :: { string })

-- SCHEDULED needs a <recurrence>, and INPROGRESS/INQUEUE/COMPLETED are run
-- states, so neither is offered for a new script.
local RECORD_STATUSES = table.freeze({ "TESTING", "RELEASED" })
local QUEUED_STATUSES = table.freeze({ "NOTSCHEDULED", "TESTING" })

-- script_loglevel also lists INTERNAL and SYSTEM, which the UI never offers.
M.LOG_LEVELS = table.freeze({ "DEBUG", "AUDIT", "ERROR", "EMERGENCY" })

-- Every script object requires this manifest feature (project:validate:
-- 'When the SuiteCloud project contains a "usereventscript", the manifest
-- must define the "SERVERSIDESCRIPTING" feature as required.').
M.FEATURE = "SERVERSIDESCRIPTING"

local KINDS: { [string]: Kind } = {
	userevent = {
		id = "userevent",
		label = "User Event",
		tag = "usereventscript",
		nScriptType = "UserEventScript",
		entryPoints = { "beforeLoad", "beforeSubmit", "afterSubmit" },
		notifyUser = true,
		audience = true,
		recordType = true,
		title = false,
		statuses = RECORD_STATUSES,
	},
	clientscript = {
		id = "clientscript",
		label = "Client",
		tag = "clientscript",
		nScriptType = "ClientScript",
		-- saveRecord is left out: an empty one returns undefined, which
		-- blocks saving the record.
		entryPoints = { "pageInit", "fieldChanged" },
		notifyUser = true,
		audience = true,
		recordType = true,
		title = false,
		statuses = RECORD_STATUSES,
	},
	suitelet = {
		id = "suitelet",
		label = "Suitelet",
		tag = "suitelet",
		nScriptType = "Suitelet",
		entryPoints = { "onRequest" },
		notifyUser = true,
		audience = true,
		recordType = false,
		title = true,
		statuses = RECORD_STATUSES,
	},
	restlet = {
		id = "restlet",
		label = "RESTlet",
		tag = "restlet",
		nScriptType = "Restlet",
		entryPoints = { "get", "post", "put", "delete" },
		notifyUser = true,
		audience = true,
		recordType = false,
		title = true,
		statuses = RECORD_STATUSES,
	},
	mapreduce = {
		id = "mapreduce",
		label = "Map/Reduce",
		tag = "mapreducescript",
		nScriptType = "MapReduceScript",
		entryPoints = { "getInputData", "map", "reduce", "summarize" },
		notifyUser = false,
		audience = false,
		recordType = false,
		title = true,
		statuses = QUEUED_STATUSES,
	},
	scheduled = {
		id = "scheduled",
		label = "Scheduled",
		tag = "scheduledscript",
		nScriptType = "ScheduledScript",
		entryPoints = { "execute" },
		notifyUser = false,
		audience = false,
		recordType = false,
		title = true,
		statuses = QUEUED_STATUSES,
	},
}

for _, k in KINDS do
	table.freeze(k.entryPoints)
	table.freeze(k)
end

function M.get(id: string): Kind?
	return KINDS[id]
end

return table.freeze(M)
