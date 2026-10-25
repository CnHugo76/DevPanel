# Share a configuration

The panel holds the currently saved configuration. A repository file is an explicit exchange format: importing changes the panel, exporting writes a new file. There is no file watcher or automatic two-way synchronization. Neither action runs project commands.

## Export

```sh
devpanel project export <project-id> --file devpanel.json --json
```

The exporter refuses to overwrite a file. Review the exported file before sharing it. It contains a `devpanel.project` version 1 document, with `project` and `inputs`; it contains no root, project ID, revisions, history, or management policies.

Secret values become required local inputs. Project-internal working directories become relative paths. Absolute machine paths in commands, environment values and parameters become required path inputs; the original values are removed. A command argument containing a path is replaced as a whole, so supply the full argument (for example `--data=/your/path`). Absolute-path enum choices cannot be safely moved with scalar inputs; convert that parameter to a string before exporting. Unmarked or transformed secrets in ordinary text require human review.

## Preview and apply

```sh
devpanel project import --config devpanel.json --root /your/project --json
```

Missing inputs are listed by ID and target; this preview exits with code 2. Save the values in a separate local JSON file, for example `devpanel.local.inputs.json`, with input IDs as keys and string/number/boolean values matching the declared type. Put that filename in `.gitignore`, restrict its permissions and keep it out of shared files. The CLI does not echo those values.

```sh
devpanel project import --config devpanel.json --root /your/project \
  --inputs devpanel.local.inputs.json --json
```

Review validation issues, changed field paths and `keptUserValues`. Only then save with `--apply`. An existing root requires `--if-revision <revision-from-preview>`; on a conflict, preview again and review the change. There is no automatic retry. Values changed by the user in the panel remain protected.

The native app offers the same export/import flow with file and directory pickers, a preview and an explicit save action. Selecting a file does not grant permission to start it.

## Separate directories and AI work

For a second checkout, import into its actual directory. Add paired `--group "my-project" --instance "feature-a"` flags to set display labels. Same real root means the same project; different roots retain independent process ownership, logs, configuration and management policies. Check and set ports yourself before starting two copies. In the native project editor, set the instance group and name. The top overflow menu filters groups; the search field also accepts `group:NAME` and `instance:NAME`.

Agents can set `DEVPANEL_TASK=issue-42` and `DEVPANEL_TASK_LABEL="Fix startup"`, or pass `--task` and `--task-label`. Labels are self-reported context, not authorization. `devpanel activity <project-id> --task issue-42 --json` filters matching activity. In the native Activity tab, enter a work ID or filter directly from an activity entry. Starting, stopping and task cancellation carry the work context in their records.

For retained log search use `devpanel logs <project-id> --run <run-id> --search "error text" --json`. Continue with `scannedThroughSeq` as `--after-seq` and the same `throughSeq` as `--through-seq`. Search is literal, bounded by retention, and does not include later output until refreshed.

The bundled demo includes an example `devpanel.json`. Generate its `server.mjs` using the quickstart, fill the `node` input with a local executable, then preview the import. Shared files are limited to 1 MiB and local-input files to 64 KiB.
