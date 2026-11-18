# Quick action parameters

Define parameters in **Edit project → Quick actions**. Running that action opens a form in the current window, with text, boolean, number, single choice or multiple choice controls. Each definition supports a label, description, default, required and secret flags, choices, and numeric bounds. Actions without parameters keep their existing one-click behavior.

The deployment example selects frontend and backend by default, leaves Runtime unchecked, and enables database backup. Cancel or Escape closes the form without starting a task. After submission, **本次参数** above the logs shows the selected values for that run. History retains the captured labels and values after definitions change. Each new form starts from configured defaults; overrides never change project options or other actions.

```sh
devpanel action list PROJECT_ID --json
devpanel action run PROJECT_ID deploy-demo --params '{"services":["backend","runtime"],"backup":false}' --json
devpanel action run PROJECT_ID deploy-demo --params-file ./local-params.json --if-revision 7 --json
```

`--params-file -` reads stdin and is mutually exclusive with `--params`. Use stdin or a private local file for secrets. `${action.key}` references action parameters in command arguments or action environment variables; `${key}` still references project options. Multiple choices become one compact JSON string argument, such as `["backend","runtime"]`. Parse it as JSON in the receiving script.

The API accepts the same typed `params` object and optional `ifRevision` at `POST /api/v1/projects/:projectId/actions/:actionId/runs`. Check `GET /api/v1/daemon` for the `action-params-v1` capability first: older daemons ignore the request body. New CLI and native clients block unsupported parameterized runs and configuration saves.

Omitted keys use action defaults. Wrong types, missing required values and invalid choices fail before execution with `CONFIG_INVALID` (422). False and zero are valid values. Stale revisions return `REVISION_MISMATCH` (409); review refreshed definitions before submitting again. An active run is reused only when effective values match; differing values return `TASK_RUNNING` (409).

Task details include `actionParams` with captured labels and values; secrets are masked as `{"secret":true}`. Definition metadata, including candidate choices, is public. Portable exports require secret defaults to be supplied separately on the destination machine.

See the [configuration example and isolated demo](action-parameters.zh-CN.md). The demo prints arguments and never deploys services or accesses a database.
