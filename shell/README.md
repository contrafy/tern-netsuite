# tern-netsuite production deploy guard (opt-in)

Makes SuiteCloud CLI commands that write to a NetSuite account wait for an
approval block in Tern when they target a production account. The block
shows the target account (with a PRODUCTION badge), the exact command, the
project, the auth ID, the git state, how many objects and files are sent,
and warnings (uncommitted changes, behind or ahead of upstream, not on the
main branch). Only after you approve, typing the account's label or id when
typed confirmation is on, does the guard run the exact command you typed.

Guarded by default: `project:deploy` and `file:upload` (config
`guard.commands`). Sandbox (`_SB<n>`), release preview (`_RP[<n>]`) and test
drive (`TSTDRV<n>`) accounts, and accounts your config marks
`"production": false`, run immediately without a prompt. Everything else,
including an account the guard cannot resolve, counts as production.

The guard is a POSIX sh core, `shell/tern-netsuite-guard`, plus one small
activation file per shell. It fails closed: outside a Tern pane, without
the tern-netsuite plugin, on timeout, on any mismatch, nothing runs. The
wire protocol is in [PROTOCOL.md](PROTOCOL.md).

## Install

Clone the repository somewhere stable (the activation files find the core
next to themselves), add the lines for your shell after anything that puts
the SuiteCloud CLI on `PATH`, and open a new Tern pane (panes started
before the plugin loaded lack `TNS_SPOOL`).

### Function mode (default)

Defines a `suitecloud` shell function: commands typed in this shell are
guarded.

zsh `~/.zshrc` / bash `~/.bashrc`:

```sh
source /path/to/tern-netsuite/shell/tern-netsuite.zsh    # or tern-netsuite.bash
```

fish `~/.config/fish/config.fish`:

```fish
source /path/to/tern-netsuite/shell/tern-netsuite.fish
```

### PATH shim mode (recommended for wrapper scripts)

Shell functions are invisible to child processes, so `make deploy`,
`npm run deploy` or any script that calls `suitecloud` by name bypasses
function mode. Shim mode puts `shell/bin` first on `PATH` instead; its
`suitecloud` hands every call, from any process started in the shell, to
the guard, which then runs the real CLI (the first other `suitecloud` on
`PATH`, never the shim itself).

```sh
TERN_NETSUITE_GUARD=shim
source /path/to/tern-netsuite/shell/tern-netsuite.zsh    # or tern-netsuite.bash
```

```fish
set -g TERN_NETSUITE_GUARD shim
source /path/to/tern-netsuite/shell/tern-netsuite.fish
```

A wrapper that calls the CLI by absolute path (for example
`node_modules/.bin/suitecloud` or `npx suitecloud` resolving a local
install) is not covered by either mode; point it at `suitecloud` on `PATH`
or put `shell/bin` on its `PATH`.

## What a guarded command does

1. Finds the target the CLI will use: `project.json`'s `defaultAuthId` in
   the current directory (the CLI never looks in parent directories), then
   the account through `suitecloud account:manageauth --info <authId>`
   (about a second; only for guarded commands).
2. Non-production: runs the CLI at once.
3. Production or unknown, in a Tern pane: fingerprints the command and the
   files it sends (`deploy.xml` entries, symlinks followed, or the
   `file:upload --paths`), opens the approve block with `tern open --wait`,
   and waits (Ctrl-C cancels; `guard.timeout_s`, default 600 s, withdraws
   the request).
4. Approved: re-reads `project.json` and re-hashes the files; if anything
   changed it refuses, else it runs the CLI with your exact argv.

`project:deploy --dryrun` and `--help` run without approval. `--dryrun`
gets that shortcut only when the project's `suitecloud.config.js` is absent,
or defines no `beforeExecuting` hook and loads no other code (`require(`,
`import`): a hook runs inside the CLI first and can turn a preview into a
real deploy. The trade-off: a production preview in a project whose config
loads code (for example one that loads the SuiteCloud Jest runner) asks for approval
like a deploy; sandbox previews still run without a prompt.

A `project.json` the guard cannot read unambiguously (duplicate
`defaultAuthId`, JSON escapes, an unusual auth ID) makes the target
unknown, so it needs approval.

## Outside Tern

A production target is refused outside a Tern pane (any terminal without
`TERM_PROGRAM=tern` and `TERN_PANE`, ssh sessions, CI): nothing runs, and
the message names the target account and the deliberate bypass.
Non-production targets and non-guarded commands work everywhere.

## Settings

From the plugin config (`$XDG_CONFIG_HOME/tern-netsuite/config.json`),
handed to new panes as environment variables by the plugin:

- `guard.commands`: guarded commands (default `["project:deploy",
  "file:upload"]`).
- `guard.confirm_production`: `false` turns the prompt off; production
  commands then run at once with a one-line notice.
- `guard.typed_confirmation`: `false` makes Approve a single click.
- `guard.timeout_s`: seconds to wait for a decision (default 600).
- `accounts[].production` / `accounts[].label`: override the classification
  of an account id and the label you type to confirm.
- `suitecloud.program`: when an absolute path, the CLI the guard runs.

Shell-only: `TERN_BIN` (the `tern` to call), `TNS_SUITECLOUD` (absolute
path of the real CLI).

## Status

```sh
tern-netsuite-guard-status
```

prints the mode, which `suitecloud` is active, the real CLI and `tern` the
guard will use, the guarded commands, the timeout, and what a guarded
command aimed at production would do in this shell.

## Bypass

Function mode:

```sh
command suitecloud project:deploy
```

Shim mode: call the real CLI by its path (refusals print it). A bypassed
command gets no confirmation and no audit entry.

## Conflicts

In function mode, an existing `suitecloud` alias or function (fish: also an
abbreviation) is left untouched: the activation file prints a message,
returns 1 and defines nothing. Remove it, or use shim mode (which warns that
the alias still wins for commands typed in that shell).

## Uninstall

1. In each open shell: `tern-netsuite-guard-uninstall` (removes the
   function, takes `shell/bin` off `PATH` and removes the helpers).
2. Delete the lines from your startup file.

## Limitations

- Only invocations of `suitecloud` by name are guarded (see shim mode).
  `suitecloud.config.js` `beforeExecuting` hooks run inside the CLI after
  approval and can change its arguments; the block shows a note when the
  project defines one.
- The fingerprint is checked just before the CLI starts; a file changed in
  the instant between the check and the CLI zipping the project is not
  detected. `project.json` is re-read by the CLI itself.
- A per-command `projectFolder` in `suitecloud.config.js` is noted but the
  guard fingerprints the default project folder.
- `ahead`/`behind` use the last fetched upstream; the guard never fetches.

## Tests

`make test-shell` runs `tests/shell/guard/run.sh` in zsh, bash, fish and
dash (each when installed) with a fake `tern` and a fake `suitecloud`
(`tests/bin/fake-suitecloud-guard`); no Tern and no NetSuite account is
involved.
