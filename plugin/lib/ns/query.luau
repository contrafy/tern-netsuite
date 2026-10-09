--!strict
-- A SuiteQL query as a sequence of HTTP requests: `plan` validates it (the
-- read-only guard runs here, before anything can be sent), `request` gives
-- the next unsigned request, `advance` folds the response in and says
-- whether another page is needed. The adapter only signs, fetches and loops.

local Config = require("../config")
local Endpoints = require("./endpoints")
local Errors = require("./errors")
local Sql = require("./sql")
local Transport = require("./transport")

local M = {}

type NsError = Errors.NsError
type Connection = Config.Connection

M.DEFAULT_MAX_ROWS = 1000
M.MAX_ROWS = Endpoints.MAX_OFFSET

export type Spec = {
	connection: Connection,
	-- The NetSuite account id of the connection's account.
	account_id: string,
	sql: string,
	params: { any }?,
	-- Rows to fetch at most (default 1000, at most 100000).
	max_rows: number?,
}

export type Plan = {
	transport: Config.Transport,
	account_id: string,
	restlet: Config.Restlet?,
	-- The SQL sent: for REST, with parameters bound.
	sql: string,
	params: { any },
	max_rows: number,
	offset: number,
	-- Pages received so far (never mutated; a new list per page).
	pages: { { any } },
	count: number,
}

export type Result = {
	rows: { any },
	-- More rows matched than were fetched (max_rows or the offset cap).
	truncated: boolean,
	pages: number,
}

export type Step = { kind: "next", plan: Plan } | { kind: "done", result: Result } | { kind: "error", error: NsError }

function M.plan(spec: Spec): (Plan?, NsError?)
	local conn = spec.connection
	if not Endpoints.valid(spec.account_id) then
		return nil,
			Errors.new("query", string.format("%q is not a NetSuite account id", spec.account_id), Errors.NO_CONNECTION)
	end
	if conn.read_only then
		local ok, why = Sql.readOnly(spec.sql)
		if not ok then
			return nil,
				Errors.new(
					"query",
					string.format("refused by the read-only guard of connection %q: %s", conn.id, why or "not a query"),
					Errors.READ_ONLY
				)
		end
	end
	local params = spec.params or {}
	local sql = spec.sql
	if conn.transport == "rest" and #params > 0 then
		local bound, err = Sql.bind(sql, params)
		if bound == nil then
			return nil, Errors.new("query", err or "the parameters do not match the query")
		end
		sql = bound
		params = {}
	end
	if conn.transport == "restlet" and conn.restlet == nil then
		return nil,
			Errors.new("query", string.format("connection %q has no restlet settings", conn.id), Errors.NO_CONNECTION)
	end
	local maxRows = math.clamp(math.floor(spec.max_rows or M.DEFAULT_MAX_ROWS), 1, M.MAX_ROWS)
	return {
		transport = conn.transport,
		account_id = spec.account_id,
		restlet = conn.restlet,
		sql = sql,
		params = params,
		max_rows = maxRows,
		offset = 0,
		pages = {},
		count = 0,
	},
		nil
end

function M.request(plan: Plan): Transport.HttpRequest
	if plan.transport == "restlet" then
		return Transport.restlet(plan.account_id, plan.restlet :: Config.Restlet, plan.sql, plan.params)
	end
	local limit = math.min(Endpoints.MAX_PAGE, plan.max_rows - plan.count, Endpoints.MAX_OFFSET - plan.offset)
	return Transport.rest(plan.account_id, plan.sql, limit, plan.offset)
end

local function flatten(pages: { { any } }, limit: number): { any }
	local rows: { any } = {}
	for _, page in pages do
		for _, row in page do
			if #rows >= limit then
				return rows
			end
			table.insert(rows, row)
		end
	end
	return rows
end

function M.advance(plan: Plan, res: Transport.HttpResult, decode: (string) -> any): Step
	local page: Transport.Page?, err: NsError?
	if plan.transport == "restlet" then
		page, err = Transport.parseRestlet(res, plan.restlet :: Config.Restlet, decode)
	else
		page, err = Transport.parseRest(res, decode)
	end
	if err then
		return { kind = "error", error = err }
	end
	local p = page :: Transport.Page
	local pages = table.clone(plan.pages)
	table.insert(pages, p.rows)
	local count = plan.count + #p.rows
	local offset = plan.offset + #p.rows
	local more = p.hasMore and #p.rows > 0
	if more and count < plan.max_rows and offset < Endpoints.MAX_OFFSET then
		local nextPlan = table.clone(plan)
		nextPlan.pages = pages
		nextPlan.count = count
		nextPlan.offset = offset
		return { kind = "next", plan = nextPlan }
	end
	return {
		kind = "done",
		result = {
			rows = flatten(pages, plan.max_rows),
			truncated = more or count > plan.max_rows,
			pages = #pages,
		},
	}
end

return M
