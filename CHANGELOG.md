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
