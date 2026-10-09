--!strict
-- Host (daemon) half: lenses, blocks and host hooks. Every feature lives in a
-- `*_host.luau` adapter exporting `register()`; this file only wires them.
-- Adapters execute effects and feed results to pure modules under lib/.

require("./config_host")

pcall(tern.fs.mkdir, tern.plugin.data)

require("./doctor_host").register()
require("./ns_host").register()
require("./guard_host").register()
require("./lens_host").register()
require("./scaffold_host").register()
require("./health_host").register()
require("./logs_host").register()
require("./explorer_host").register()
require("./history_host").register()
require("./browser_host").register()
