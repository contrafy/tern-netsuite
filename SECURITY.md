# Security policy

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/contrafy/tern-netsuite/security/advisories/new)
(Security tab, "Report a vulnerability"). Do not open a public issue.

Include the version (`version` in `plugin.toml` or `tern plugin list`), the
Tern and SuiteCloud CLI versions, OS and architecture, your shell for guard
issues, and steps to reproduce. Never include credentials, tokens, real
account ids or unsanitized CLI output.

Fixes are released as a patch version and credited in the advisory unless
you prefer otherwise.

## Supported versions

tern-netsuite is pre-1.0. Only the latest release and `master` receive
security fixes.

## Scope

The trust boundary is the local user: any process running as you can
already run the SuiteCloud CLI, read the plugin's data directory and write
its spool files. The deploy guard is a safety net against mistakes, not
access control; `command suitecloud ...` bypasses it by design.

In scope, for example:

- the guard or the approve block running something other than what was
  shown and confirmed, or a production target passing without approval;
- credentials leaving the system keychain (logs, files, URLs, block state);
- a read-only connection sending anything but a single `SELECT` / `WITH`;
- a `tern-netsuite://` link (which any program can print as a hyperlink)
  starting a command or query the user did not ask for.
