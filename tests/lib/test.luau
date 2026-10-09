--!strict
-- Spec API shared by every spec and tests/run.luau. Specs register tests at
-- require time; the module cache makes the runner and all specs see the same
-- registry regardless of the relative path used to require it.

local inspect = require("./inspect")

export type Expectation = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeNil: () -> (),
	toContain: (needle: any) -> (),
	toThrow: (pattern: string?) -> (),
}

export type TestCase = {
	file: string,
	name: string,
	fn: () -> (),
}

export type Failure = {
	name: string,
	message: string,
}

export type Report = {
	passed: number,
	failures: { Failure },
	ran: number,
}

local ASSERTION = {}

type AssertionError = { tag: typeof(ASSERTION), message: string }

local tests: { TestCase } = {}
local scope: { string } = {}
local currentFile = "<unknown>"

local function fullName(name: string): string
	local parts = table.clone(scope)
	table.insert(parts, name)
	return table.concat(parts, " > ")
end

local function describe(name: string, fn: () -> ())
	table.insert(scope, name)
	local ok, err = pcall(fn :: () -> any)
	table.remove(scope)
	if not ok then
		error(err, 0)
	end
end

local function it(name: string, fn: () -> ())
	table.insert(tests, { file = currentFile, name = fullName(name), fn = fn })
end

local function fail(message: string): never
	local source, line = debug.info(3, "sl")
	local where = if source then string.format("\n  at %s:%d", source, line or 0) else ""
	local e: AssertionError = { tag = ASSERTION, message = message .. where }
	error(e, 0)
end

local function expect(actual: any): Expectation
	return {
		toBe = function(expected: any)
			if actual ~= expected then
				fail(string.format("expected %s to be %s", inspect.format(actual), inspect.format(expected)))
			end
		end,
		toEqual = function(expected: any)
			local path = inspect.firstDifference(actual, expected)
			if path then
				fail(
					string.format(
						"values differ at %s\n  expected: %s\n  actual:   %s",
						path,
						inspect.format(expected),
						inspect.format(actual)
					)
				)
			end
		end,
		toBeNil = function()
			if actual ~= nil then
				fail(string.format("expected nil, got %s", inspect.format(actual)))
			end
		end,
		toContain = function(needle: any)
			if type(actual) == "string" then
				if type(needle) ~= "string" or not string.find(actual, needle, 1, true) then
					fail(string.format("expected %s to contain %s", inspect.format(actual), inspect.format(needle)))
				end
				return
			end
			if type(actual) == "table" then
				for _, v in ipairs(actual) do
					if inspect.firstDifference(v, needle) == nil then
						return
					end
				end
				fail(string.format("expected %s to contain %s", inspect.format(actual), inspect.format(needle)))
			end
			fail(string.format("toContain needs a string or array, got %s", inspect.format(actual)))
		end,
		toThrow = function(pattern: string?)
			if type(actual) ~= "function" then
				fail(string.format("toThrow needs a function, got %s", inspect.format(actual)))
			end
			local ok, err = pcall(actual)
			if ok then
				fail("expected function to throw, but it returned")
			end
			local message = if type(err) == "table" and err.tag == ASSERTION then err.message else tostring(err)
			if pattern and not string.find(message, pattern, 1, true) then
				fail(
					string.format(
						"expected error containing %s, got %s",
						inspect.format(pattern),
						inspect.format(message)
					)
				)
			end
		end,
	}
end

local function describeError(err: any): string
	if type(err) == "table" and err.tag == ASSERTION then
		return err.message
	end
	return (string.gsub(debug.traceback(tostring(err), 2), "%s+$", ""))
end

local function setFile(file: string)
	currentFile = file
	table.clear(scope)
end

local function addLoadFailure(file: string, err: any)
	table.insert(tests, {
		file = file,
		name = "<load>",
		fn = function()
			local e: AssertionError = { tag = ASSERTION, message = tostring(err) }
			error(e, 0)
		end,
	})
end

local function run(filters: { string }, out: (string) -> ()): Report
	local report: Report = { passed = 0, failures = {}, ran = 0 }
	for _, case in tests do
		local label = case.file .. " :: " .. case.name
		local selected = #filters == 0
		for _, f in filters do
			if string.find(label, f, 1, true) then
				selected = true
				break
			end
		end
		if selected then
			report.ran += 1
			local ok, message = xpcall(case.fn :: () -> any, describeError)
			if ok then
				report.passed += 1
				out("PASS " .. label)
			else
				out("FAIL " .. label)
				table.insert(report.failures, { name = label, message = message })
			end
		end
	end
	return report
end

return {
	describe = describe,
	it = it,
	expect = expect,
	setFile = setFile,
	addLoadFailure = addLoadFailure,
	run = run,
}
