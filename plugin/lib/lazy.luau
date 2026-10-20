--!strict
-- Deferred module loading for the window half. Tern aborts a window half
-- whose load takes over 50 ms, and nearly all of that is compiling required
-- modules (in real Tern about 0.16 ms per KiB of source on a busy machine),
-- so window adapters require at load only what registration, chrome
-- formatters and their own types need. Everything else is reached through an
-- accessor that requires the module on first use and remembers it (a repeated
-- `require` still costs Tern a path lookup):
--
--   local Upload = lazy(function()
--   	return require("./lib/explorer/upload")
--   end)
--   ... Upload().command(owner, guard, target) ...
--
-- The `require` stays in the caller's file, so it resolves relative to that
-- file and the accessor returns the module's type. Luau cannot import a type
-- without running the require, so a type the caller names comes either from
-- an eager require or from `typeof` of an accessor call, which only the type
-- checker evaluates:
--
--   type Target = typeof(Upload().target(nil, nil :: any))
--
-- Never call an accessor first from a chrome formatter: Tern gives those 4 ms
-- and disables a slower one until reload. A loader that raises is retried on
-- the next call.

return function<T>(load: () -> T): () -> T
	local loaded = false
	local value: T
	return function(): T
		if not loaded then
			value = load()
			loaded = true
		end
		return value
	end
end
