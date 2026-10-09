#!/bin/sh
# Takes the README screenshots (docs/screenshots/*.png) from the real plugin
# in an isolated Tern window. Local only: needs `tern` (closed beta) and
# shows a window on screen while it runs.
#
#   scripts/screenshots.sh [all]   setup, start the window, shoot, stop
#   scripts/screenshots.sh setup   build the sandbox and the demo workspace
#   scripts/screenshots.sh start   run the sandbox window in the foreground
#   scripts/screenshots.sh shoot [SCENE...]  drive a running window
#   scripts/screenshots.sh stop    quit the sandbox window
#
# Everything is synthetic and lives under /tmp: the sandbox TNS_SHOTS_SANDBOX
# (default /tmp/acme-tern: Tern config, daemon and control sockets, logs, a
# neutral zsh, the plugin config) and the demo repository TNS_SHOTS_WORKSPACE
# (default /tmp/acme: SDF projects built from tests/fixtures/projects and
# tests/fixtures/scaffold/acp). The SuiteCloud CLI is the repo's fake
# (tests/bin/suitecloud) replaying demo fixtures written to the sandbox, so
# nothing reaches NetSuite; the real CLI is never on the panes' PATH. The
# health block reads a summary computed by the plugin's own health model
# from tests/fixtures/monitor/health, injected into the plugin's kv store
# with a lease held by "another window", so no window polls and no
# credentials are read. Never touches the user's Tern config or daemon.
#
# Scenes (in order; `shoot` runs them all): init validate status deploys
# deploy-prod guard explorer health new-script history logs. `logs` links a
# copy of the package whose NsHost answers queries with synthetic rows.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
sb=${TNS_SHOTS_SANDBOX:-/tmp/acme-tern}
ws=${TNS_SHOTS_WORKSPACE:-/tmp/acme}
out=${TNS_SHOTS_OUT:-$repo/docs/screenshots}
tern_bin=$(command -v "${TERN_BIN:-tern}" || true)
luau=$repo/.tools/bin/luau

for d in "$sb" "$ws"; do
	case $d in
	/tmp/?*) ;;
	*)
		echo "screenshots: $d must be under /tmp" >&2
		exit 2
		;;
	esac
done

export TERN_CONFIG_DIR="$sb/cfg"
export TERN_DAEMON_SOCKET="$sb/d.sock"
export STENCIL_LOG_DIR="$sb/logs"
export STENCIL_LOG=warn
# Inherited from a surrounding Tern pane; they describe the user's Tern.
unset TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_PANE TERN_PANE_SOCKET TERN_BLOB_DIR \
	TERN_COMPLETE TERN_IDENTITY TERN_LENSES TERM_PROGRAM TERM_PROGRAM_VERSION TNS_SPOOL
ctl_sock="$sb/ctl.sock"
data="$TERN_CONFIG_DIR/plugin-data/tern-netsuite"
pkg="$sb/pkg"

need_tern() {
	[ -n "$tern_bin" ] || {
		echo "screenshots: tern is not installed" >&2
		exit 1
	}
}

ctl() {
	"$tern_bin" ctl --control "$ctl_sock" "$@"
}

# `tern ctl` joins its words into one scenario line: quote free text.
q() {
	printf '"%s"' "$1"
}

# ---------------------------------------------------------------- setup

# Demo SuiteCloud CLI output: the repo's fixtures with the demo company
# name, plus a few composed from the same message formats for the demo
# projects.
write_fixtures() {
	fx=$sb/fixtures
	rm -rf "$fx"
	mkdir -p "$fx"
	cp -R "$repo/tests/fixtures/suitecloud/." "$fx/"
	find "$fx" -name '*.txt' -exec sed -i '' -e 's/Example Co\(rp\)\{0,1\}/Acme Corp/g' {} +

	cat >"$fx/manageauth/info-production.txt" <<'EOF'
Authentication ID: demo-prod
Account Name: Acme Corp
Account ID: 1234567
Role: Administrator
Domain: 1234567.app.netsuite.com
Account Type: Production
EOF
	echo 0 >"$fx/manageauth/info-production.exit"

	b=$ws/sdf/billing/src
	cat >"$fx/validate/acme-billing.txt" <<EOF
The validation process has encountered an error.
The following errors were found during local validation:
Errors for file: $b/Objects/customscript_demo_order_sync.xml.
  - Line No. 8 - Error message: The file referenced in "scriptfile" is missing in the project and is not included in the dependencies list.
  - Line No. 1 - Error message: When the SuiteCloud project contains a "mapreducescript", the manifest must define the "SERVERSIDESCRIPTING" feature as required.
Errors for file: $b/Objects/customscript_demo_print_label_button.xml.
  - Line No. 1 - Error message: The element type "usereventscript" must be terminated by the matching end-tag "</usereventscript>".
Errors for file: $b/manifest.xml.
  - Line No. 1 - Error message: The following dependencies are missing from the manifest.xml file: [File - /SuiteScripts/map-reduce/order_sync_v2.js]
Errors for file: $b/deploy.xml.
  - Line No. 3 - Error message: The file "~/FileCabinet/SuiteScripts/billing/invoice_export.js" referenced by object field "path" is missing.
EOF
	echo 1 >"$fx/validate/acme-billing.exit"

	cat >"$fx/deploy/acme-storefront-prod.txt" <<'EOF'
Deploying to 1234567 - Acme Corp - Administrator.
2026-10-09 09:41:07 (PDT) Installation started
Info -- Account [(PRODUCTION) Acme Corp]
Info -- Account Customization Project [storefront]
Info -- Framework Version [1.0]
Validate manifest -- Success
Validate deploy file -- Success
Validate configuration -- Success
Validate objects -- Success
Validate files -- Success
Validate folders -- Success
Validate translation imports -- Success
Validation of referenceability from custom objects to translations collection strings in progress. -- Success
Validate preferences -- Success
Validate flags -- Success
Validate account settings -- Success
Validate Custom Objects against the Account -- Success
Validate file cabinet items against the account -- Success
Validate translation imports against the account -- Success
Validation of references to translation collection strings against account in progress. -- Success
Begin deployment
Upload file -- ~/FileCabinet/SuiteScripts/common/integrations/carriers/client.js
Upload file -- ~/FileCabinet/SuiteScripts/warehouses/stock_summary_html.js
Upload file -- ~/FileCabinet/SuiteScripts/user-events/warehouse_stock_subtab.js
Update object -- customscript_demo_warehouse_stock_subtab (usereventscript)
Update object -- customscript_demo_warehouse_stock_subtab.customdeploy_demo_warehouse_stock_subtab (scriptdeployment)
2026-10-09 09:41:29 (PDT) Installation COMPLETE (0 minutes 22 seconds)
The deployment process has finished successfully.
EOF
	echo 0 >"$fx/deploy/acme-storefront-prod.exit"

	cat >"$fx/deploy/acme-billing.txt" <<'EOF'
Deploying to 1234567_SB1 - Acme Corp - Administrator.
2026-10-09 09:32:44 (PDT) Installation started
Info -- Account [(SANDBOX) Acme Corp]
Info -- Account Customization Project [billing]
Info -- Framework Version [1.0]
Validate manifest -- Success
Validate deploy file -- Success
Validate configuration -- Success
Validate objects -- Success
Validate files -- Success
Validate folders -- Success
Begin deployment
Upload file -- ~/FileCabinet/SuiteScripts/map-reduce/order_sync.js
Update object -- customscript_demo_order_sync (mapreducescript)
Update object -- customscript_demo_order_sync.customdeploy_demo_order_sync (scriptdeployment)
Update object -- customlist_demo_order_channel (customlist)
2026-10-09 09:32:58 (PDT) Installation COMPLETE (0 minutes 14 seconds)
The deployment process has finished successfully.
EOF
	echo 0 >"$fx/deploy/acme-billing.exit"

	cat >"$fx/deploy/acme-fulfillment-failed.txt" <<'EOF'
The deployment process has encountered an error.
Deploying to 1234567_SB1 - Acme Corp - Administrator.
2026-10-09 09:36:12 (PDT) Installation started
Info -- Account [(SANDBOX) Acme Corp]
Info -- Account Customization Project [fulfillment]
Info -- Framework Version [1.0]
Validate manifest -- Success
Validate deploy file -- Success
Validate configuration -- Success
Validate objects -- Success
Begin deployment
Update object -- customlist_demo_sprint_status (customlist)
*** ERROR ***

An unexpected error has occurred.
Details: The record type customrecord_demo_sprint is locked and cannot be updated.
Object: customrecord_demo_sprint (customrecordtype)
EOF
	echo 1 >"$fx/deploy/acme-fulfillment-failed.exit"
}

# The panes' `suitecloud`, and the CLI the plugin and the guard call: the
# repo's fake over the demo fixtures. `$sb/scene` names the fixture for the
# next project:/file: command; `--info demo-prod` resolves to production.
write_cli() {
	mkdir -p "$sb/bin"
	cat >"$sb/bin/suitecloud" <<EOF
#!/bin/sh
export TNS_FAKE_FIXTURES='$sb/fixtures'
if [ "\$#" = 3 ] && [ "\$1" = account:manageauth ] && [ "\$2" = --info ] && [ "\$3" = demo-prod ]; then
	export TNS_FAKE=manageauth/info-production
elif [ -f '$sb/scene' ]; then
	case \$1 in project:* | file:*) TNS_FAKE=\$(cat '$sb/scene') && export TNS_FAKE ;; esac
fi
exec '$repo/tests/bin/suitecloud' "\$@"
EOF
	chmod +x "$sb/bin/suitecloud"
	ln -sf "$tern_bin" "$sb/bin/tern"
}

# A neutral interactive zsh: no user rc files, a fixed PATH without the real
# SuiteCloud CLI, a short prompt. `tns_guard` sources the guard (function
# mode) in the current pane.
write_zsh() {
	z=$sb/zsh
	mkdir -p "$z"
	cat >"$z/.zshenv" <<EOF
export TNS_FAKE_FIXTURES='$sb/fixtures'
EOF
	cat >"$z/.zshrc" <<EOF
HISTFILE='$z/history'
path=('$sb/bin' /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)
export PATH
export TERN_BIN='$sb/bin/tern'
export GIT_AUTHOR_NAME='Acme Dev' GIT_AUTHOR_EMAIL='dev@acme.example'
export GIT_COMMITTER_NAME='Acme Dev' GIT_COMMITTER_EMAIL='dev@acme.example'
PROMPT='%1~ \$ '
RPROMPT=''
tns_guard() { source '$pkg/shell/tern-netsuite.zsh'; }
EOF
}

write_config() {
	mkdir -p "$sb/xdg/tern-netsuite" "$TERN_CONFIG_DIR/plugins"
	# Dark theme in either appearance, solid chrome, the status line on.
	cat >"$TERN_CONFIG_DIR/settings.json" <<'EOF'
{
  "theme_dark": "dark",
  "theme_light": "dark",
  "material": "Solid",
  "status_bar": true
}
EOF
	printf '%s\n' "$pkg" >"$TERN_CONFIG_DIR/plugins/tern-netsuite.path"
	cat >"$sb/xdg/tern-netsuite/config.json" <<EOF
{
	"schema_version": 1,
	"suitecloud": { "program": "$sb/bin/suitecloud", "timeout_ms": 600000 },
	"projects": { "roots": ["sdf"], "follow_symlinks": true },
	"accounts": [
		{ "id": "sandbox", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"] },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "auth_ids": ["demo-prod"], "production": true }
	],
	"guard": { "confirm_production": true, "typed_confirmation": true, "commands": ["project:deploy", "file:upload"] },
	"connections": [
		{ "id": "sb1", "account": "sandbox", "auth": "tba", "transport": "rest", "read_only": true }
	],
	"monitor": {
		"poll_seconds": 120,
		"checks": [
			{
				"id": "order-sync", "label": "Order sync", "connection": "sb1", "kind": "freshness",
				"query": "SELECT MAX(lastmodifieddate) AS last FROM customrecord_acme_order", "max_age_minutes": 90
			},
			{
				"id": "stuck-invoices", "label": "Stuck invoices", "connection": "sb1", "kind": "count",
				"query": "SELECT COUNT(*) AS n FROM customrecord_acme_invoice_batch WHERE status = 'PENDING'",
				"warn_at": 1, "error_at": 25
			}
		],
		"script_errors": { "enabled": true, "hour_error_at": 5, "day_warn_at": 50 }
	},
	"status": { "enabled": true }
}
EOF
}

# The demo repository: four SDF projects from the test fixtures, and a
# shared carriers folder symlinked into two of them (a cross-project
# File Cabinet collision for the explorer).
write_workspace() {
	rm -rf "$ws"
	mkdir -p "$ws/sdf" "$ws/shared"
	p=$repo/tests/fixtures/projects
	cp -R "$p/orders" "$ws/sdf/billing"
	cp -R "$p/warehouses" "$ws/sdf/storefront"
	cp -R "$p/tables" "$ws/sdf/fulfillment"
	cp -R "$repo/tests/fixtures/scaffold/acp" "$ws/sdf/payments"
	for n in billing storefront fulfillment payments; do
		sed -i '' -e "s|<projectname>[^<]*</projectname>|<projectname>$n</projectname>|" "$ws/sdf/$n/src/manifest.xml"
	done
	printf '{\n\t"defaultAuthId": "demo-sb"\n}\n' >"$ws/sdf/billing/project.json"
	printf '{\n\t"defaultAuthId": "demo-sb"\n}\n' >"$ws/sdf/fulfillment/project.json"
	printf '{\n\t"defaultAuthId": "demo-sb"\n}\n' >"$ws/sdf/payments/project.json"
	printf '{\n\t"defaultAuthId": "demo-prod"\n}\n' >"$ws/sdf/storefront/project.json"
	ints=src/FileCabinet/SuiteScripts/common/integrations
	mv "$ws/sdf/storefront/$ints/carriers" "$ws/shared/carriers"
	ln -s ../../../../../../../shared/carriers "$ws/sdf/storefront/$ints/carriers"
	mkdir -p "$ws/sdf/billing/$ints"
	ln -s ../../../../../../../shared/carriers "$ws/sdf/billing/$ints/carriers"
	# Folders storefront's deploy.xml lists (untracked when empty, as in a
	# real checkout after a build step).
	mkdir -p "$ws/sdf/storefront/src/AccountConfiguration" "$ws/sdf/storefront/src/Translations"
	(
		cd "$ws"
		export GIT_AUTHOR_NAME='Acme Dev' GIT_AUTHOR_EMAIL='dev@acme.example'
		export GIT_COMMITTER_NAME='Acme Dev' GIT_COMMITTER_EMAIL='dev@acme.example'
		export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
		git init -q -b main
		git add -A
		git commit -q -m "Acme SDF projects"
	)
}

# The health summary the poller would publish for the demo connection,
# computed by the plugin's own checks and model from the health fixtures,
# plus a lease held by another window so this one only reads it.
write_health() {
	gen=$sb/gen
	mkdir -p "$gen" "$data"
	printf '{ "aliases": { "repo": "%s" } }\n' "$repo" >"$gen/.luaurc"
	cat >"$gen/health.luau" <<'EOF'
local Checks = require("@repo/plugin/lib/monitor/health/checks")
local Config = require("@repo/plugin/lib/config")
local Model = require("@repo/plugin/lib/monitor/health/model")
local fixtures = require("@repo/tests/lib/fixtures")
local json = require("@repo/tests/lib/json")

local cfgText = ...
local cfg = Config.parse(cfgText, json.decode)
local specs = Checks.specs(cfg)

local function rows(path)
	local doc = json.decode(fixtures.read("monitor/health/" .. path))
	return doc.items or doc.rows
end

local USER = {
	["order-sync"] = { { last = "2026-10-08 21:52:10" } },
	["stuck-invoices"] = { { n = 4 } },
}

local now = os.time()
local c = Model.conns(cfg)[1]
for _, s in specs do
	local data = if s.kind == "errors"
		then rows("errors-rest.json")
		elseif s.kind == "hourly" then rows("hourly-rest.json")
		elseif s.kind == "last_error" then rows("last-error-restlet.json")
		elseif s.kind == "deployments" then rows("deployments-rest.json")
		else USER[s.id]
	Model.record(c, s, Checks.evaluate(s, data, nil, now - 40, c.clock))
end
local summary = Model.summary(c, specs, now - 30, cfg.monitor.poll_seconds)

local function encode(v): string
	local t = type(v)
	if t == "table" then
		if #v > 0 or next(v) == nil then
			local parts = {}
			for _, x in v do
				table.insert(parts, encode(x))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in v do
			table.insert(keys, k)
		end
		table.sort(keys)
		local parts = {}
		for _, k in keys do
			table.insert(parts, encode(k) .. ":" .. encode(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		local s = string.gsub(v, '[%c"\\]', function(ch)
			return string.format("\\u%04x", string.byte(ch))
		end)
		return '"' .. s .. '"'
	elseif t == "number" then
		return if v == math.floor(v) then string.format("%d", v) else tostring(v)
	else
		return tostring(v)
	end
end

print(encode({
	["health.lease"] = { owner = "another-window", expires = now + 100000000, ttl = 60 },
	["health.summary." .. c.id] = summary,
}))
EOF
	(cd "$gen" && "$luau" health.luau -a "$(cat "$sb/xdg/tern-netsuite/config.json")") >"$data/kv.json"
}

setup() {
	need_tern
	[ -x "$luau" ] || {
		echo "screenshots: $luau is missing (make bootstrap)" >&2
		exit 1
	}
	stop
	rm -rf "$sb"
	mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR" "$pkg"
	# The window runs a snapshot of this checkout, so edits to the checkout
	# during a run cannot reload the plugin under the scenes.
	cp -R "$repo/plugin" "$repo/plugin.toml" "$repo/shell" "$pkg/"
	write_fixtures
	write_cli
	write_zsh
	write_config
	write_workspace
	write_health
}

# ---------------------------------------------------------------- window

start() {
	need_tern
	export XDG_CONFIG_HOME="$sb/xdg"
	export ZDOTDIR="$sb/zsh"
	export SHELL=/bin/zsh
	export PATH="$sb/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
	# Shots land in <cwd>/target/shots: keep them in the sandbox.
	cd "$sb"
	exec "$tern_bin" --control "$ctl_sock" "$ws"
}

wait_ready() {
	i=0
	until ctl ready >/dev/null 2>&1; do
		i=$((i + 1))
		if [ "$i" -gt 120 ]; then
			echo "screenshots: the sandbox window did not become ready (see $sb/window.out)" >&2
			exit 1
		fi
		sleep 0.5
	done
}

# Quits the window, then its daemon (it can outlive the window).
stop() {
	[ -n "$tern_bin" ] && [ -S "$ctl_sock" ] && ctl quit >/dev/null 2>&1 || true
	i=0
	while pgrep -f -- "$TERN_DAEMON_SOCKET" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
		sleep 0.25
		i=$((i + 1))
	done
	pids=$(pgrep -f -- "$TERN_DAEMON_SOCKET" 2>/dev/null || true)
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null || true
	fi
}

# ---------------------------------------------------------------- scenes

shot() { # NAME
	ctl inbox clear >/dev/null
	sleep 0.5
	png=$(ctl shot "$1" | sed -n 's/.*"png":"\([^"]*\)".*/\1/p')
	case $png in
	/*) ;;
	?*) png="$sb/$png" ;;
	*)
		echo "screenshots: shot $1 failed" >&2
		exit 1
		;;
	esac
	mkdir -p "$sb/shots"
	cp "$png" "$sb/shots/$1.png"
}

run() { # LINE typed into the focused pane
	ctl run "$(q "$1")" >/dev/null
}

expect() { # TEXT shown by a plugin surface of the focused pane
	ctl plugins expect "$(q "$1")" >/dev/null
}

scene() { # FIXTURE for the next project:/file: command
	printf '%s\n' "$1" >"$sb/scene"
}

size() { # W H of the window content
	ctl resize "$1" "$2" >/dev/null
	sleep 0.5
}

at() { # DIR relative to the workspace: cd there and clear the pane
	run "cd $ws/$1 && clear"
	sleep 1
}

# Opens a palette command's block beside the pane, zoomed.
block() { # COMMAND
	ctl plugins run "plugin.tern-netsuite.$1" >/dev/null
	sleep 3
	ctl zoom >/dev/null
	sleep 1
}

close_block() {
	ctl key escape >/dev/null
	sleep 1
}

# Window half loads have a 50 ms budget; a cold reload can miss it once.
reload() {
	n=$(grep -c 'plugin window entry failed to load' "$STENCIL_LOG_DIR/tern.log" 2>/dev/null || true)
	for _ in 1 2 3; do
		"$tern_bin" plugin reload >/dev/null
		sleep 2
		m=$(grep -c 'plugin window entry failed to load' "$STENCIL_LOG_DIR/tern.log" 2>/dev/null || true)
		[ "${m:-0}" = "${n:-0}" ] && return 0
		n=$m
	done
	echo "screenshots: the plugin's window half did not load (see $STENCIL_LOG_DIR/tern.log)" >&2
	exit 1
}

scene_init() {
	ctl account signed-in acme >/dev/null
	ctl font 14 >/dev/null
	size 1440 900
	# Startup toasts (updates, tool detection) fade on their own.
	sleep 20
}

scene_validate() {
	at sdf/billing
	scene validate/acme-billing
	run "suitecloud project:validate"
	expect "Validation failed"
	size 1440 600
	shot lens-validate
}

scene_status() {
	at sdf/billing
	run "cat project.json"
	size 1440 220
	shot status-line
}

# Deploys that only feed the history block.
scene_deploys() {
	at sdf/billing
	scene deploy/acme-billing
	run "suitecloud project:deploy"
	expect "Deployed"
	at sdf/fulfillment
	scene deploy/acme-fulfillment-failed
	run "suitecloud project:deploy"
	sleep 3
}

scene_deploy_prod() {
	size 1440 900
	at sdf/storefront
	scene deploy/acme-storefront-prod
	run "suitecloud project:deploy"
	expect "Tail logs"
	size 1440 420
	shot lens-deploy-prod
}

# The guard in function mode; approving runs the (fake) deploy.
scene_guard() {
	size 1440 720
	at sdf/storefront
	run "tns_guard && clear"
	sleep 1
	scene deploy/acme-storefront-prod
	run "suitecloud project:deploy"
	sleep 4
	expect "Type PROD to approve"
	shot guard-approve
	ctl type PROD >/dev/null
	ctl key enter >/dev/null
	sleep 3
	at sdf/storefront
}

scene_explorer() {
	size 1440 900
	at ""
	block explorer
	ctl key tab >/dev/null
	sleep 0.5
	shot explorer
	close_block
}

scene_health() {
	size 1440 560
	at sdf/billing
	block health
	shot health
	close_block
}

scene_new_script() {
	size 1440 900
	at sdf/billing
	block new-script
	ctl type "$(q 'Invoice Approval Guard')" >/dev/null
	ctl key tab >/dev/null
	ctl key tab >/dev/null
	ctl key tab >/dev/null
	ctl type /billing >/dev/null
	ctl key tab >/dev/null
	ctl type INVOICE >/dev/null
	sleep 1
	shot new-script
	close_block
}

scene_history() {
	size 1440 480
	at ""
	block history
	shot history
	close_block
}

# Execution logs need a connection; a copy of the package whose NsHost
# answers every query with synthetic scriptnote rows stands in for it. The
# logs block and its views are the real ones.
scene_logs() {
	logs_pkg=$sb/pkg-logs
	rm -rf "$logs_pkg"
	cp -R "$pkg" "$logs_pkg"
	awk '
		{ print }
		/^function M\.query\(/ {
			print "\tlocal okRead, demo = pcall(tern.fs.read, tern.plugin.dir .. \"/demo-log-rows.json\")"
			print "\tif okRead and demo then"
			print "\t\tcb({ rows = tern.json.decode(demo), truncated = false, pages = 1, ms = 18 }, nil)"
			print "\t\treturn"
			print "\tend"
		}
	' "$pkg/plugin/ns_host.luau" >"$logs_pkg/plugin/ns_host.luau"
	write_log_rows >"$logs_pkg/demo-log-rows.json"
	printf '%s\n' "$logs_pkg" >"$TERN_CONFIG_DIR/plugins/tern-netsuite.path"
	reload
	size 1440 640
	at sdf/billing
	block logs
	sleep 2
	# Expand the failed reduce: the 7th row, newest first.
	for _ in 1 2 3 4 5 6; do
		ctl key j >/dev/null
	done
	ctl key enter >/dev/null
	sleep 1
	shot logs
	close_block
	close_block
	printf '%s\n' "$pkg" >"$TERN_CONFIG_DIR/plugins/tern-netsuite.path"
	reload
}

write_log_rows() {
	i=0
	sep='['
	while IFS='|' read -r ago type script name title detail; do
		i=$((i + 1))
		logged=$(date -v-"${ago}"S '+%Y-%m-%d %H:%M:%S')
		printf '%s\n  {"internalid": %d, "logged": "%s", "type": "%s", "title": "%s", "detail": "%s", "scripttype": %d, "scriptid": "%s", "scriptname": "%s"}' \
			"$sep" $((8100 + i)) "$logged" "$type" "$title" "$detail" "$(printf '%s' "$script" | cksum | cut -c1-4)" "$script" "$name"
		sep=','
	done <<'EOF'
420|AUDIT|customscript_demo_order_sync|Order Sync|order_sync:run.start|{\"lookbackMinutes\":120,\"dryRun\":false}
400|DEBUG|customscript_demo_order_sync|Order Sync|order_sync:getInput|{\"orders\":38,\"since\":\"07:00\"}
380|AUDIT|customscript_demo_order_sync|Order Sync|order_sync:map.done|{\"created\":31,\"matched\":6,\"skipped\":1}
350|ERROR|customscript_demo_order_sync|Order Sync|order_sync:reduce.failed|{\"externalId\":\"WEB-100482\",\"code\":\"INVALID_FLD_VALUE\",\"field\":\"custbody_demo_order_channel\"}
330|AUDIT|customscript_demo_order_sync|Order Sync|order_sync:summarize|{\"created\":31,\"failed\":1,\"usage\":4210}
240|DEBUG|customscript_demo_print_label_button|Print Label Button|beforeLoad|{\"type\":\"view\",\"order\":\"SO-20931\",\"shipments\":1}
200|AUDIT|customscript_demo_warehouse_stock_subtab|Warehouse Stock Subtab|stock:render|{\"warehouse\":\"EAST\",\"carriers\":3,\"ms\":412}
150|ERROR|customscript_demo_warehouse_stock_subtab|Warehouse Stock Subtab|carriers:timeout|{\"carrier\":\"ACME_FREIGHT\",\"timeoutMs\":5000}
90|DEBUG|customscript_demo_print_label_button|Print Label Button|beforeLoad|{\"type\":\"view\",\"order\":\"SO-20935\",\"shipments\":0}
30|AUDIT|customscript_demo_order_sync|Order Sync|order_sync:run.start|{\"lookbackMinutes\":120,\"dryRun\":false}
EOF
	printf '\n]\n'
}

shoot() {
	need_tern
	wait_ready
	if grep -q 'plugin window entry failed to load' "$STENCIL_LOG_DIR/tern.log" 2>/dev/null; then
		reload
	fi
	if [ $# = 0 ]; then
		set -- init validate status deploys deploy-prod guard explorer health new-script history logs
	elif [ "$1" != init ]; then
		# The neutral avatar and font come from the init scene; without it the
		# real account's avatar shows in the window chrome.
		set -- init "$@"
	fi
	for s in "$@"; do
		echo "scene $s"
		"scene_$(printf '%s' "$s" | tr '-' '_')"
	done
	# Copied at the end: files appearing under a linked plugin root make
	# Tern reload it (the window runs a snapshot, but stay clear anyway).
	# pngquant/oxipng, when on PATH, shrink them near-losslessly.
	mkdir -p "$out"
	for s in "$sb"/shots/*.png; do
		f=$out/${s##*/}
		cp "$s" "$f"
		if command -v pngquant >/dev/null 2>&1; then
			pngquant --quality=95-100 --skip-if-larger --force --strip --ext .png "$f" || true
		fi
		if command -v oxipng >/dev/null 2>&1; then
			oxipng -o 4 --strip safe -q "$f" || true
		fi
		echo "$f"
	done
}

case ${1:-all} in
setup) setup ;;
start) start ;;
shoot)
	shift
	shoot "$@"
	;;
stop) stop ;;
all)
	setup
	"$0" start >"$sb/window.out" 2>&1 &
	trap stop EXIT INT TERM
	shoot
	;;
*)
	sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
