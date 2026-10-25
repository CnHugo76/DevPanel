# DevPanel

**English** | [简体中文](README.zh-CN.md)

A native macOS panel and CLI for developers and AI agents to manage local projects: start services, inspect logs and actual listening ports, and keep launch settings in configurations you can review.

AI agents register, start, and query projects through the CLI. You inspect, adjust, and take over through the native app. Both use the same local daemon. Saving a configuration does not execute commands, and closing the app does not stop services. Readiness signals, log digests, operation attribution, and project activity help agents verify results; holds and locks let you control their actions.

- **Service management**: manage foreground processes, inspect listening ports and CPU / memory usage, browse past runs, and adjust launch parameters.
- **AI integration**: a JSON CLI, one-time readiness checks, incremental logs and digests, and an installable agent skill. No MCP server setup required.
- **Human oversight**: a native service panel, operation attribution and activity, holds, and locks.
- **Troubleshooting and reuse**: search all retained logs, compare actual and next launch settings, copy diagnostic context, and share redacted configurations with import previews.
- **Parallel work**: label AI work in activity and group separate directory instances while keeping their runs and management policies independent.
- **Project tools**: saved actions, Maven modules and profiles, Git changes, and separate diff windows, with explicitly configured repositories and Maven projects.

[Feature checklist and v0.4 priorities](docs/features.md) · [Try the demo](examples/demo/README.md) · [Documentation](docs/README.md) · [Contributing](CONTRIBUTING.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

The detailed development guides, demo instructions, and agent skill are currently written in Simplified Chinese. Issues and pull requests are welcome in English or Chinese.

[Releases](https://github.com/CnHugo76/DevPanel/releases) · macOS 14+ · [Quick start](docs/quickstart.md)

![25-second DevPanel demo: CLI startup, readiness and ports, log search, run history, and stopping from the native app](docs/images/devpanel-demo.gif)

25 seconds with two real services in an isolated demo environment. The CLI starts them; the native app shows their state and lets you take over. [Try it yourself](examples/demo/README.md).

## Requirements and downloads

- macOS 14 or later. Distribution packages are built separately on Apple Silicon and Intel Macs.
- Check the [Releases page](https://github.com/CnHugo76/DevPanel/releases) for downloadable packages. The v0.4.2 Apple Silicon package is prepared; its upload and publication are pending. Verify ZIP downloads with the accompanying `.sha256` file. Intel users can build from source on an Intel Mac.
- The standalone app bundles Node.js, the daemon, the CLI, and a process sampling helper. It does not require a separate Node.js installation or a source checkout. Your own projects still need their tools, such as a JDK or package manager.

Extract `DevPanel.app` and place it somewhere you intend to keep it. If macOS blocks the first launch, try opening it once, then use **System Settings → Privacy & Security → Open Anyway** and follow the system prompts. Distribution packages use ad-hoc signing; they are not Developer ID signed or notarized.

## First launch and CLI setup

Follow [Your first project](docs/quickstart.md). The complete App includes a demo and Agent skill; the demo uses bundled Node.

[Configuration sharing, import previews, separate instances and AI work context](docs/config-sharing.md)

You can skip onboarding and reopen it from the DevPanel menu using “安装 CLI 与登录启动…” (Install CLI and start at login):

1. Choose a command directory; the default is `~/.local/bin`. The app previews the destination paths for `devpanel` and `devpaneld`. If a destination already exists, it shows the current file contents or symlink target and asks before replacing it.
2. Add that directory to the `PATH` used by your terminal and agents. The installer does not edit shell configuration files.
3. Starting the daemon at login is off by default. Enabling it installs a user LaunchAgent that starts only the daemon, without starting any project services.

The app prefers its bundled CLI. If you move or delete the app, reinstall the CLI links and login item to update their paths. When the daemon is not running, use “启动管理服务” (Start daemon) in the app.

```sh
devpanel daemon status --json
devpanel project register --config /path/to/project.json --json
devpanel start <project-id> --wait-ready --json
devpanel logs <project-id> --service backend --digest
devpanel activity <project-id> --json
```

Use the project ID returned by registration; replace the placeholder IDs in these examples. Readiness is a one-time signal from logs or a listening port. It does not verify application behavior.

## Configure your AI agent

The [skills/devpanel](skills/devpanel/SKILL.md) directory contains the DevPanel skill. Install that directory in your agent's supported skill location, keeping its `references/` directory. Set a self-reported name in **each agent's own environment**, for example `DEVPANEL_AGENT=codex` for Codex or `DEVPANEL_AGENT=claude-code` for Claude Code. The CLI also accepts `--agent`. These names are labels, not authentication.

When onboarding a project, have the agent inspect its actual launch commands, identify adjustable parameters, and configure readiness signals. Explicitly request a start after registration. Use `--wait-ready` for a startup report, prefer `--digest` when reading logs, and use `--after-seq` for subsequent incremental reads. Supervision policies are edited through the app. An agent may use `--override-hold` only when you explicitly authorize the start in the current conversation.

## Build from source

You need macOS, Node.js ≥24, pnpm 12, and an Xcode toolchain with Swift 6 support. Download or clone this repository, then run these commands from its root:

```sh
pnpm install --frozen-lockfile
export DEVPANEL_HOME="$(mktemp -d /tmp/dp-build.XXXXXX)"
export DEVPANEL_PORT=0
pnpm typecheck
pnpm test
swift build --package-path apps/mac
swift test --package-path apps/mac
apps/mac/scripts/bundle.sh
```

`apps/mac/build/DevPanel.app` is an app bundle for UI development. To build the complete standalone distribution instead, run the following in the same terminal:

```sh
VERSION=0.4.2 pnpm release:local
node scripts/release-smoke.mjs
```

The release script downloads a pinned Node.js runtime for the current architecture from the official Node.js site and verifies its SHA-256. It copies production dependencies and the native sampling helper, applies ad-hoc signatures, and writes the app, ZIP, and checksum to `.devpanel-dev/codex/v04/release/`. It does not install the app, push code, create tags, or publish a GitHub Release. Build the other architecture on a corresponding Mac; a universal binary is not provided.

ZIP names include `macos-arm64` or `macos-x64`, and checksum files reference the same filename. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and contribution guidelines.

Always use a short, temporary `DEVPANEL_HOME` for development and tests: macOS Unix socket paths must be at most 103 bytes. Run the source CLI with `node packages/cli/src/main.ts`. Development CLI installation must specify a temporary destination, such as `pnpm setup:cli --bin-dir /tmp/devpanel-bin`. Keep development builds separate from your daily data, installed app, CLI, and daemon.

## Data and upgrades

The default data directory is `~/Library/Application Support/DevPanel`. It contains project configurations, sensitive values, run records, and bounded logs. Directory permissions are 0700 and file permissions are 0600. Set `DEVPANEL_HOME` to use a separate environment. Removing a project from DevPanel does not delete its source files. Values marked as sensitive are redacted; secrets encoded or transformed by your application cannot be recognized automatically.

See the [migration guide](docs/release-v0.4.md) for moving from a manually installed version to the standalone app. Before upgrading, stop managed services and back up the data, then switch the app, CLI, and login item. Only one daemon may use a data directory. You can keep versions in separate locations, but they must not manage the same data simultaneously. Upgrades, version tags, and GitHub releases remain the maintainer's decision.

## Uninstall

First make sure managed services can be stopped. Run `devpanel daemon uninstall --stop-services` to remove the login item; it has no side effects if none is installed. Then run `devpanel daemon stop --stop-services` to ensure a manually started daemon is also stopped. An unreachable-daemon response means it is already stopped. Quit the app, then delete it and the `devpanel` / `devpaneld` links from your chosen command directory, checking that the links point to this app before deleting them.

You decide whether to delete the data directory. Keep it if you want to reuse your configuration later. Uninstalling does not delete project source files or change shell configuration.

## Known limitations

- Manages only local foreground processes started by DevPanel. It does not adopt existing processes or manage containers or remote hosts.
- No automatic restarts, HTTP readiness probes, continuous health checks, service dependency orchestration, or AI diagnosis.
- Holds, locks, and agent force-stop restrictions help prevent unintended operations. Programs running as the same user can access local API credentials; these controls are not a security boundary.
- After a daemon failure, runs whose output pipes cannot be reattached show an unknown state and a log gap. Lossless recovery is not guaranteed.
- No notarization, automatic updates, package manager distribution, or Linux / Windows installers. The complete installation flow on a clean Mac still needs manual verification.
- The native UI is currently primarily in Simplified Chinese. Bilingual READMEs do not imply that the app UI is localized.

## License

Released under the [MIT License](LICENSE). Commercial use, modification, and redistribution are permitted, provided the copyright and license notice are retained. Third-party components retain their [own licenses](THIRD_PARTY_NOTICES.md).
