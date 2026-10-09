# SuiteCloud CLI fixtures

Output of `@oracle/suitecloud-cli` 3.2.0 (SDK `cli-2026.1.0.jar`), one
`<name>.txt` per run with its exit code in `<name>.exit`. The text is what a
Tern lens receives: stdout and stderr interleaved, spinner frames and escape
sequences applied, trailing blanks trimmed.

## Captured (real)

Recorded by `scripts/fixtures/capture-suitecloud.sh` against scratch projects
under /tmp and a sandbox account (`--server`, `object:list`, `file:list`
only). Sanitized: account id `1234567` (`1234567_SB1`), account name
`Example Co`, auth id `demo-sb`, scratch paths `/work/...`, home `/home/dev`.
Everything else is byte-for-byte.

| Fixture | Command | Exit | What it shows |
| --- | --- | --- | --- |
| `help/*` | `<command> --help` | 0 | option lists |
| `validate/ok` | `project:validate` | 0 | clean local validation |
| `validate/warnings` | `project:validate` | 0 | local warnings (success layout: indented path, `- Line No. N - msg`) |
| `validate/malformed-xml` | `project:validate` | 1 | XML parse error (failure layout: `Errors for file: <path>.`, `- Line No. N - Error message: msg`) |
| `validate/missing-dependency` | `project:validate` | 1 | feature missing from manifest.xml |
| `validate/deploy-path-missing` | `project:validate` | 1 | deploy.xml file path that does not exist |
| `validate/deploy-path-crash` | `project:validate` | 1 | deploy.xml object path that does not exist: the SDK prints a Java NullPointerException message |
| `validate/missing-file` | `project:validate` | 1 | script object referencing a missing file |
| `validate/log` | `project:validate --log <file>` | 0 | `--log` prints nothing extra; the path is only in argv |
| `validate/no-account` | `project:validate` (no project.json) | 1 | setup error |
| `validate/server-ok` | `project:validate --server` | 0 | `Validating against <account> - <name> - <role>.`, step list, `Validation COMPLETE` |
| `validate/server-warnings` | `project:validate --server` | 0 | `WARNING -- ... (<scriptid>)` / `Details:` / `File:` block |
| `validate/server-missing-file` | `project:validate --server` | 1 | `*** ERROR ***` block with `(<scriptid>)`, `Details:`, `File:` |
| `validate/server-malformed-xml` | `project:validate --server` | 1 | error block without a script id |
| `validate/server-account-dependency` | `project:validate --server` | 1 | dependency missing in the account |
| `package/ok`, `package/malformed-xml` | `project:package` | 0 | package never validates |
| `adddependencies/added`, `adddependencies/none` | `project:adddependencies` | 0 | dependencies written to manifest.xml |
| `list/object-none`, `list/file-missing-folder` | `object:list --scriptid ...`, `file:list --folder ...` | 0 | empty results |
| `list/object-all` | `object:list` | 0 | header plus `<type>:<scriptid>` lines; a sample of up to 3 objects per type (136 in all) in the CLI's order, scriptids replaced by synthetic `<real prefix>_demo_<n>` |
| `list/object-type` | `object:list --type restlet suitelet` | 0 | same format, 3 per type, synthetic scriptids |
| `list/object-type-scriptid` | `object:list --type restlet --scriptid customscript_demo` | 0 | `--scriptid` filters by substring; synthetic scriptids |
| `list/object-unknown-type` | `object:list --type bogustype` | 0 | an unknown type is "no objects", not an error |
| `list/object-unknown-auth` | `object:list` (project.json names a missing auth id) | 1 | auth id not available |
| `list/object-no-account` | `object:list` (no project.json) | 1 | setup error |
| `list/file-no-folder` | `file:list` | 1 | `--folder` is mandatory outside `-i` |

The sandbox role used for the captures sees no files in any File Cabinet
folder (`file:list` always printed `No files found.`), so `list/file-folder`
(4 paths, exit 0) is synthetic: one File Cabinet path per line and no header,
as `ListFilesOutputHandler.js` prints them.

`manageauth/` belongs to the account feature.

## Synthetic

`project:deploy` and `file:upload` write to an account, so they were never
run. These fixtures follow the CLI 3.2.0 source and the SDK message bundle
exactly where those define the text, and Oracle's documented deployment log
for the server part:

- `deploy/*`: `Deploying to {account} - {name} - {role}.` and the result
  lines `The deployment process has finished successfully.` / `The
  deployment process has encountered an error.` come from the SDK bundle
  (`Messages_en_US.properties`: `msg_deploying_to_account`,
  `msg_deploy_successful`, `msg_deploy_error`); errors are printed before
  the server log, as the captured `--server` failures show. The server log
  (`Installation started`, `Info -- Account [(SANDBOX) ...]`, validation
  steps, `Begin deployment`, `Upload file -- ~/FileCabinet/...`,
  `Create object -- <scriptid> (<type>)`, `Installation COMPLETE (0 minutes
  N seconds)`) follows the sample in Oracle's SDF tutorial ("Validate and
  Deploy the SuiteCloud Project to a Target NetSuite Account"); the step
  names are the ones the captured `--server` runs print. `Update object --`
  and the `Object:` line of `deploy/failed` are assumptions.
- `deploy/preview` (`project:deploy --dryrun`): `Deployment preview for
  {account} - {name} - {role}.` is the SDK bundle's `msg_previewing_to_account`;
  the `Deployment preview` marker before the would-be changes follows the
  sample in Oracle's `sdfcli preview` reference. `DeployAction._preview`
  prints no closing sentence of its own.
- `upload/*`: `The following files were uploaded:` / `The following files
  were not uploaded:` and `<path>: <error>` follow
  `UploadFilesOutputHandler.js`; the error texts are SDK bundle messages
  (`msg_could_not_upload_inactive_files`, `msg_project_has_no_uploadable_files`).

| Fixture | Exit |
| --- | --- |
| `deploy/ok` | 0 |
| `deploy/ok-production` | 0 |
| `deploy/validation-failed` | 1 |
| `deploy/failed` | 1 |
| `deploy/preview` | 0 |
| `upload/ok` | 0 |
| `upload/partial` | 0 |
| `upload/failed` | 1 |
