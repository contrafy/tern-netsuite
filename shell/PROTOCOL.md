# tern-netsuite guard protocol (version 1)

Contract between the shell guard (`shell/tern-netsuite-guard`, POSIX sh) and
the tern-netsuite approve block (`tern-netsuite.approve`,
`plugin/lib/guard/session.luau`). The block never runs the command; it shows
the request and writes a decision. The guard runs the real SuiteCloud CLI
with the exact argv, and only after verifying that decision. Every failure
is a refusal: nothing runs.

## Entry points

- `tern-netsuite-guard suitecloud ARGS...`: called by the `suitecloud` shell
  function (`shell/tern-netsuite.{zsh,bash,fish}`, function mode).
- `tern-netsuite-guard shim ARGS...`: called by the PATH shim
  `shell/bin/suitecloud` (shim mode); identical except for the bypass hint.
- `tern-netsuite-guard status`: prints what the guard would do in this shell.

The real CLI is `$TNS_SUITECLOUD` when set (absolute path), else the first
executable `suitecloud` on `PATH` whose content does not contain the marker
`TERN_NETSUITE_GUARD_SHIM` (so the shim, or a copy of it, is never chosen).
None found: exit 127.

## Which invocations are guarded

The command is the first argument that does not start with `-` (the CLI's
global options take no value). It is guarded when it is listed in
`$TNS_GUARD_COMMANDS` (space-separated; unset = `project:deploy file:upload`,
empty = nothing). Not guarded, executed at once with `exec`:

- every other command;
- `-h`/`--help` anywhere (before `--`, and not right after an option that
  may take a value);
- `project:deploy --dryrun` under the same rule (a preview changes nothing),
  but only when `./suitecloud.config.js` is absent, or readable and matches
  none of `beforeExecuting`, `require(`, `import ` / `import(` (a hook,
  possibly loaded from other code, can rewrite the arguments into a real
  deploy). `--log --dryrun` and `-- --dryrun` are not previews.

## Target resolution

The CLI reads `project.json` and `suitecloud.config.js` from its working
directory only (never a parent), so the guard does too:

- project = physical `pwd`;
- auth ID = `defaultAuthId` of `./project.json`, read line-based only when
  that provably agrees with the CLI's `JSON.parse` (last duplicate wins,
  `\uXXXX` decoded): a file containing any backslash or more than one
  `"defaultAuthId"`, or a value outside `[A-Za-z0-9._-]`, makes the target
  unknown (with a note); a key and value split across lines, or no key, too;
- project folder = `./<defaultProjectFolder>` from `./suitecloud.config.js`
  (quoted literal), else the project itself;
- `--authid` anywhere after the command: the target is unknown (CLI 3.x has
  no such option for these commands; the guard does not trust it either way);
- account = `Account ID:` line of `suitecloud account:manageauth --info
  <authId>`, run from `/` with stdin `/dev/null` (also `Account Name:`,
  `Account Type:`); failure or an id outside `[A-Za-z0-9_-]` = unknown.

Classification (mirrors `plugin/lib/account/classify.luau`): the id is
uppercased; an entry `ID=prod` or `ID=nonprod` in `$TNS_GUARD_ACCOUNTS`
(space-separated) wins; else an id ending in `_SB<digits>` (at least one
digit) or `_RP` with optional digits, or `TSTDRV<digits>` (at least one
digit, nothing else), is non-production; everything else (`X_SB`, `TSTDRV`,
`TSTDRVX` included), and an
unknown account, is production.

Non-production: `exec` the CLI. Production or unknown: with
`TNS_GUARD_CONFIRM=0` (`guard.confirm_production: false`) the guard prints
one line and `exec`s the CLI; otherwise it asks for approval.

## Preconditions for approval

- `TERM_PROGRAM=tern` and a non-empty `TERN_PANE`. Outside a Tern pane a
  production target is refused with the bypass hint (`command suitecloud
  ...` in function mode, the real CLI's path in shim mode);
- `TNS_SPOOL`: absolute path, injected into new panes by the plugin's
  `spawn` hook (`<plugin data>/spool`). Panes started before the plugin
  loaded lack it: "open a new Tern pane";
- `TNS_GUARD_TIMEOUT`: positive integer seconds (default 600).

## Environment set by the plugin

`plugin/lib/guard/env.luau`, applied to every new pane by the host `spawn`
hook from the user's config:

| Variable | Value |
| --- | --- |
| `TNS_SPOOL` | `<plugin data>/spool` |
| `TNS_GUARD_COMMANDS` | `guard.commands`, space-separated |
| `TNS_GUARD_CONFIRM` | `1`, or `0` when `guard.confirm_production` is false |
| `TNS_GUARD_TIMEOUT` | `guard.timeout_s` |
| `TNS_GUARD_ACCOUNTS` | `ACCOUNT_ID=prod\|nonprod` for each `accounts[]` entry with an explicit `production` |
| `TNS_SUITECLOUD` | `suitecloud.program` when it is an absolute path |

A config change reaches panes opened after it. Without these variables
(outside Tern, or an old pane) the guard uses its defaults, which never
weaken the guard.

## Spool

`$TNS_SPOOL`, mode 0700, owned by the user (the guard creates it if
missing, refuses a symlink or foreign owner, and `chmod 700`s it). Paths the
guard hands to `tern open` are physical (`pwd -P`).

| File | Writer | Mode | Lifetime |
| --- | --- | --- | --- |
| `req-<nonce>.json` | guard (noclobber) | 0600 | removed by the guard when it finishes |
| `resp-<nonce>.env` | block (tmp + rename) | 0600 best effort | removed by the guard |
| `cancel-<nonce>` | guard | 0600 | left for the block, which removes it |
| `work-<nonce>/` | guard (scratch) | 0700 | removed by the guard |

The guard sweeps `req-*`, `resp-*` and `cancel-*` older than one day plus
the timeout. `<nonce>` is 32 lowercase hex characters from 16 bytes of
`/dev/urandom`.

## Request: `req-<nonce>.json`

One JSON object on one line. Strings escape `"`, `\` and control bytes; other
bytes pass through unchanged. `null` stands for unknown.

```json
{"version":1,
 "nonce":"<32 hex>",
 "argv":["suitecloud","project:deploy","--log","my logs/d.log"],
 "command":"project:deploy",
 "program":"/Users/me/.bun/bin/suitecloud",
 "cwd":"/Users/me/src/repo/sdf/billing",
 "folder":"/Users/me/src/repo/sdf/billing/src",
 "auth_id":"prod",
 "account_id":"1234567",
 "account_name":"Example Co",
 "account_type":"Production",
 "pane":"4294967309",
 "git":{"root":"/Users/me/src/repo","branch":"main","head":"<40 hex>","dirty":false,
        "upstream":"origin/main","ahead":0,"behind":0,"default_branch":"main"},
 "notes":["suitecloud.config.js defines a beforeExecuting hook: ..."],
 "files":[{"path":"/Users/me/src/repo/sdf/billing/project.json","sha256":"<64 hex>"}],
 "fingerprint":"<64 hex>",
 "created_at":1791476707,
 "timeout_s":600}
```

- `argv`: the exact argv; the first element is always `suitecloud`, the rest
  is what runs. `program`: the real CLI that will run it.
- `git`: `null` outside a repository. Read only, no fetch: `ahead`/`behind`
  compare with the last fetched upstream (`null` without upstream);
  `default_branch` is `origin/HEAD`'s branch, else `main` or `master` when it
  exists; `dirty` covers the whole repository.
- `notes`: one-line facts the approver should see (unknown target, missing
  deploy.xml entries, `beforeExecuting` hooks, per-command `projectFolder`,
  upload paths that are not files).
- `pane`: `$TERN_PANE`. The block refuses requests whose pane is gone, and
  requests older than `created_at + timeout_s`.

### Fingerprinted files

Always `./project.json` and `./suitecloud.config.js` when present, then:

- `project:deploy`: `<folder>/deploy.xml`, `<folder>/manifest.xml` and each
  `<path>` of deploy.xml (`~/` = the folder): `~/dir/*` = every regular file
  under `dir`, any other `*` = `find -path` match under the folder (may
  over-match), a directory = every file under it, a file = itself. Symlinks
  are followed (SDF projects often link objects and scripts in from shared
  directories); dangling links are skipped. No deploy.xml: every file of the
  folder;
- `file:upload`: each space-separated `--paths` value, as
  `<folder>/FileCabinet<path>`; values that are not files are skipped with a
  note (interactive uploads fingerprint no file);
- other configured commands: only the two settings files.

Listed paths are absolute, sorted bytewise and de-duplicated. A name with a
newline, another control character or a backslash is refused.

## Fingerprint

`fingerprint` = lowercase hex sha256 of this byte string (also
`plugin/lib/guard/protocol.luau`; both must change together). Lengths are
decimal byte counts; every line ends with `\n`:

```
tern-netsuite/fp/v1
argv <n>
<len>:<arg>                     (n lines, argv in order, starting with suitecloud)
cwd <len>:<physical cwd>
folder <len>:<project folder>
authid <len>:<auth ID>          or: authid -
account <len>:<account id>      or: account -
files <m>
<len>:<abs path> <sha256>       (m lines, sorted bytewise by path)
```

The block recomputes this string from the request it displays and refuses
to approve unless its sha256 equals `fingerprint`, so what the approver sees
is what is fingerprinted.

## Waiting

The guard runs `${TERN_BIN:-tern} open --wait <req path>` (stdin
`/dev/null`) in the background under a watchdog of `$TNS_GUARD_TIMEOUT`
seconds:

- timeout: the guard kills `tern open`, writes `cancel-<nonce>`, refuses;
- SIGINT/SIGTERM/SIGHUP (Ctrl-C): the guard writes `cancel-<nonce>`, kills
  `tern open`, removes the request, exits 130, never executes;
- `tern open` exits non-zero: `cancel-<nonce>`, refusal;
- `tern open` exits 0: its status says nothing about the decision (an
  unclaimed request opens in an editor block and still returns 0); the
  response file decides.

The window half claims `tern open` of `.../tern-netsuite/spool/req-<32
hex>.json` with origin `cli` and opens `tern-netsuite.approve` with the path
as its only argument. A block that sees `cancel-<nonce>` closes without
writing a response.

## Response: `resp-<nonce>.env`

Line-based `key=value` (value = everything after the first `=`), written to
`resp-<nonce>.env.tmp`, `chmod 600`, then renamed:

```
nonce=<nonce of the request>
decision=approve|deny
fingerprint=<the request's fingerprint, verified by the block>
account=<account id the block showed, or - when unknown>
approved_at=<unix seconds>
reason=<one line; optional, deny only>
```

`reason` is set when the block refused the request on its own (for example
a fingerprint mismatch); the guard prints it with the denial, stripped of
non-printable characters. Unknown keys are ignored. The block always exits
with status 0 (`tern open --wait` ignores it, and a non-zero exit leaves a
sheet that blocks the wait).

The guard refuses, executing nothing, unless all hold:

1. the file exists, is a regular file (not a symlink) owned by the user;
2. no key above appears twice;
3. `nonce` equals the request nonce;
4. `decision=approve` (`deny`: "denied in Tern" plus the `reason` if any,
   exit 1);
5. `approved_at` is an integer with `created_at <= approved_at <=
   created_at + timeout_s`, and now `<= created_at + timeout_s`;
6. `account` equals the request's account id (`-` when unknown);
7. `project.json`'s `defaultAuthId`, read again, is unchanged;
8. a fresh fingerprint (same argv, cwd, folder, auth ID, account, the file
   list enumerated and hashed again) equals both the request and the
   response `fingerprint`.

Then the guard removes its request, response and scratch files, restores
the user's umask and runs `exec <program> "$@"`: the exact argv, the user's
terminal, environment and working directory, the CLI's exit status. Exit
statuses of the guard itself: 1 refusal or denial, 130 cancelled, 127 no
CLI, 2 usage.

## Audit log

The block appends one JSON line per decision (`approved`, `denied`,
`cancelled`) to `<plugin data>/audit.log` (mode 0600): time, decision,
command, account id/label, production, auth ID, cwd, folder, argv, file
count, fingerprint, git branch/head/dirty, deny reason. File contents and
notes are never logged.
