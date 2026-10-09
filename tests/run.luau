--!strict
-- Test runner. Standalone luau has no filesystem listing, so the caller passes
-- spec paths after `-a` (`make test` does the discovery with `find`):
--
--   .tools/bin/luau tests/run.luau -a [FILTER...] tests/unit/foo.spec.luau ...
--
-- Arguments ending in `.luau` are spec files, given relative to the repo root
-- (the working directory must be the repo root). Any other argument is a
-- filter: a test runs when "<file> :: <describe > ... > it>" contains at least
-- one filter as a plain substring. Specs must end with `return nil`: luau
-- modules must return exactly one value. Exits nonzero (via a top-level error,
-- as the luau CLI has no os.exit) on any failure, on a spec that fails to
-- load, or when nothing ran.

local t = require("./lib/test")

local specs: { string } = {}
local filters: { string } = {}

for _, arg in { ... } do
	if type(arg) ~= "string" then
		continue
	end
	if string.sub(arg, -5) == ".luau" then
		table.insert(specs, arg)
	else
		table.insert(filters, arg)
	end
end

if #specs == 0 then
	error("run.luau: no spec files given; run `make test` or pass paths after -a", 0)
end

for _, spec in specs do
	local path = string.gsub(spec, "^%./", "")
	if string.sub(path, 1, 1) == "/" then
		error("run.luau: spec paths must be relative to the repo root: " .. spec, 0)
	end
	t.setFile(path)
	local ok, err = pcall(require, "../" .. string.sub(path, 1, -6))
	if not ok then
		if string.find(tostring(err), "module must return a single value", 1, true) then
			err = "spec must end with `return nil` (luau modules must return one value)"
		end
		t.addLoadFailure(path, err)
	end
end

local report = t.run(filters, print)

for _, failure in report.failures do
	print("\n" .. failure.name)
	print("  " .. string.gsub(failure.message, "\n", "\n  "))
end

print(string.format("\n%d passed, %d failed, %d ran", report.passed, #report.failures, report.ran))

if #report.failures > 0 then
	error(string.format("%d test(s) failed", #report.failures), 0)
end
if report.ran == 0 then
	error("no tests matched", 0)
end
