# Changelog

## 0.1.0 (unreleased)

First version.

- SuiteCloud lens for validate, deploy, upload, package, adddependencies,
  manageauth, object:list and file:list output; wrapper commands via
  `lens.wrappers` and `scripts/tern-netsuite-wrappers`.
- Status-line account indicator and Doctor block.
- Opt-in production deploy guard (`shell/`): approval block, typed
  confirmation, fingerprinted files, audit log.
- SDF explorer with project checks, Upload this file, account browser with
  imports, New script scaffolder, deploy history with CI runs.
- Read-only NetSuite connection layer (TBA and OAuth 2.0 M2M; REST SuiteQL
  and RESTlet transports; keychain credentials), execution log tail and
  account health with a status-line badge.
- Blocks fill their pane on Tern 0.7.0: row lists scroll themselves instead
  of being sized from `cx.rows`, which Tern 0.7.0 leaves at 80x24.
- The window half loads in about half the time (155 instead of 321 KiB of
  source at load), so a busy machine no longer pushes it past Tern's 50 ms
  load limit ("load exceeded 50 ms"); modules it needs only later are loaded
  on first use.
- PageUp/PageDown work in the explorer, browser, history and logs blocks
  (Tern names them `page_up` / `page_down`).
- Row lists keep the selected row visible in short panes; the key hints give
  way first.
- One SuiteCloud account command per auth ID across blocks, panes, windows
  and plugin reloads; imports run in their own split pane.
- Links printed by other programs never start work: bare browser and logs
  links open the block waiting for Enter; uploads, imports, health refresh,
  CI logs and NetSuite query/credential links need a single-use grant.
- Paths with backslashes, quotes or control characters are refused for
  imports and uploads (fish would parse them differently).
- Config edits reach the guard environment of new panes without a reload.
- Deploy history: a deploy's status is recorded only when the line's exit
  status is its own, and every `NAME=value` word is redacted.
- Logs: full pages continue from the newest row of the page, nothing is cut
  after an empty first load, retries never come sooner than a normal poll.
- New script: SuiteApp projects scaffold under
  `/SuiteApps/<publisherid>.<projectid>`; writes refuse symlinks and paths
  outside the project; the real deploy.xml / manifest.xml edit error shows.
- The shell guard makes every SuiteCloud account command typed in a Tern
  pane wait for the plugin's per-auth-ID CLI slot, so it never overlaps the
  plugin's own listings, imports or uploads; a production command waits for
  the slot only after approval.
- SuiteQL console: multi-line editor with history, saved queries and `.sql`
  folders (`console.saved_dirs`, recursive), PROD badges, a sortable and
  filterable results grid, CSV/TSV copy, CSV/JSON files, Tern's table viewer,
  and `Tern NetSuite: Run SuiteQL file`.
- Record inspector: fields with custom and standard labels, system notes,
  related records and lines, Open in NetSuite; log rows offer Inspect.
- Script deployments: status, log level, record type and 24 h log counts per
  deployment; changes go through the project's SDF XML and the guard.
- Drift: compares a project's objects and File Cabinet files with any
  configured account (read-only, scratch project, canonical XML comparison,
  unified diffs, account-only listing, cached results).
