# Your first project

**English** | [简体中文](quickstart.zh-CN.md)

[Configuration sharing, import previews, separate instances and AI work context](config-sharing.md)

Start once, inspect the shared logs, and stop the service yourself. DevPanel records services started through DevPanel. Registering configuration does not execute commands.

## Install and check

Download a release for your architecture when available, or follow the README source build instructions. Keep the App in a permanent location. If macOS blocks it, attempt to open it, then use System Settings → Privacy & Security → Open Anyway. Keep Gatekeeper enabled.

Choose the CLI directory in DevPanel → Install CLI and login startup. Existing files require a preview and overwrite confirmation; login startup is off by default. Reopen the onboarding guide from the App menu (the interface is primarily Chinese).

For the default command directory:

```sh
export PATH="$HOME/.local/bin:$PATH"
command -v devpanel
devpanel --help
devpanel daemon status --json
```

Use your actual directory. The export affects only this terminal; configure PATH separately in your Agent environment. If the daemon is stopped, use Start management service in the App. Reinstall CLI links after moving the App.

## Run the bundled example

The example uses bundled Node and an automatically assigned available port. Set APP to its actual location:

```sh
APP="/Applications/DevPanel.app"
CLI="$APP/Contents/Resources/runtime/bin/devpanel"
NODE="$APP/Contents/Resources/runtime/node/bin/node"
DEMO_DIR="$(mktemp -d /tmp/devpanel-demo.XXXXXX)"
"$NODE" "$APP/Contents/Resources/demo/create-config.mjs" "$DEMO_DIR"
"$CLI" project validate --config "$DEMO_DIR/devpanel-demo.json" --json
"$CLI" project register --config "$DEMO_DIR/devpanel-demo.json" --json
```

These commands only create files and register configuration. Copy project.id from the response, then start:

```sh
PROJECT_ID="paste project ID"
"$CLI" start "$PROJECT_ID" --wait-ready --json
"$CLI" logs "$PROJECT_ID" --service web --digest
```

Find DevPanel demo in the App. Confirm readiness, the actual port and the same run ID. Open the port to see Hello from DevPanel. Stop it in the App, then verify and remove:

```sh
"$CLI" status "$PROJECT_ID" --json
"$CLI" project remove "$PROJECT_ID" --json
```

Removing a registration does not delete files. Delete the example directory after stopping and removing it. Closing the window does not stop services.

## Add your own project

Install the complete Contents/Resources/skills/devpanel directory from the App, or skills/devpanel from the repository, using your Agent's skill installation mechanism. Keep references/. Set DEVPANEL_AGENT=codex or claude-code in the Agent environment and ask:

> Use the DevPanel skill to add this project. Check actual startup scripts, tool paths, environment and readiness. Turn frequently adjusted values into options. Validate and register, explain the result, and do not start it yet.

After reviewing, explicitly ask to start. Verify the source, actual command, working directory, logs and readiness evidence; stop it from the App. Preserve project instructions so new Agent sessions use the same entry point.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| java/pnpm works in a terminal but is missing in the App | Run project validate, inspect programResolved/pathUsed, configure the tool path or project PATH |
| No readiness condition | Add a log/port condition in the editor; it applies on the next start |
| Readiness timeout | The process may still be running; inspect that run's logs before retrying |
| Agent start denied | Inspect hold/lock state and decide in the App whether to allow it |
| Management interrupted / unknown state | Preserve evidence and inspect the previous run before starting another |

See README and release-v0.4.md for upgrade, rollback and removal. Gatekeeper, login sessions and notifications require verification on the target Mac.
