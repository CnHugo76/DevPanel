# DevPanel v0.4 feature checklist

**English** | [简体中文](features.zh-CN.md)

DevPanel gives developers and AI agents a shared view of local project processes. The native macOS app and JSON CLI use the same daemon. This inventory describes the current public source, including changes after the local `v0.4.1` tag; design proposals alone do not count as implemented features.

## Version status

Checked on **2026-10-25**, against public source commit [`2fc5902`](https://github.com/CnHugo76/DevPanel/commit/2fc5902626de035d7d75b371bdce89afd0d2c678).

| Item | Status |
| --- | --- |
| Local development tags | `v0.2.0`, `v0.3.0`, `v0.3.1`, `v0.4.0`, `v0.4.1` |
| Public GitHub tags / Releases | None at the time of this check |
| Package and default bundle version | `0.4.1`; public source also includes later tool navigation, log presentation, and open-source preparation changes |
| Local preview package | An Apple Silicon `0.4.2-dev` preview passed packaging and standalone-runtime smoke checks; it is not a tagged release |
| Suggested next public version | `v0.4.2`, after release checks; this is a recommendation, not an assigned tag |

The old tags belong to development history retained locally. They were deliberately excluded from the new public history; see [publication notes](open-source.md). A future public tag should identify the actual source used to build that release.

## Supported capabilities

“CLI” means an existing DevPanel command, rather than an operation an agent could perform with unrelated shell tools.

| Area | Native macOS app | CLI | Boundaries |
| --- | --- | --- | --- |
| Project configuration | Add, edit, remove; multiple services, working directories, commands and environment | Register, validate, show, list, update, remove | Saving, importing or validating configuration never runs project commands |
| Launch options | Text, number, switch and choice editors; sensitive values; pending changes | List, set and remove parameters; explicit protection for user values | Changes take effect on the next launch; saving does not restart services |
| Service lifecycle | Start, stop, restart; project or service selection; force stop after timeout | `start`, `stop`, `restart`, `force-stop`, operation results and JSON output | Manages foreground processes started by DevPanel; verifies process identity before signaling |
| Runtime visibility | CPU, memory, process count, actual listening ports, run history and launch snapshots | `status`, `stats`, operation queries and startup reports | Ports come from managed processes; unavailable or stale measurements are indicated |
| Logs | Live and historical logs, follow, search, ANSI, stack folding, raw copy and optional prefix simplification | Tail, follow, JSON and incremental `--after-seq` reads | Known Spring Boot / Logback / Log4j layouts can be simplified; unknown formats retain their original text |
| Readiness | Configure a log-text or listening-port signal; see outcome, elapsed time and evidence | `start` / `restart --wait-ready` and startup reports | One-time signal; timeout marks the outcome without stopping or restarting the service |
| Log digests | Copy a digest for the selected run | `logs --digest`, byte budgets and incremental reads | Deterministic error / stack / repetition / tail compression; no model calls or diagnosis |
| Attribution and activity | Startup / stop actor, project timeline and redacted configuration differences | `--agent`, `DEVPANEL_AGENT`, `activity` | Agent names are self-reported; activity does not provide configuration rollback |
| Human oversight | Edit policy, hold after a human stop, allow AI startup, lock / unlock services | Read policy and state; lifecycle commands obey it; explicit `--override-hold` | Policies cover service lifecycle only; actions, Maven and option edits are outside this policy scope |
| Saved actions | Configure, run, cancel, inspect output / history / resources; optional time limits | `action list`, `action run`, `task cancel` | One current run per action; different actions can run concurrently |
| Maven | Module / lifecycle tree, goals, profiles, skip tests, offline, dependency modules, command preview, save as action | `maven modules`, `maven run`, target selection and task cancellation | Explicit multiple roots; static POM parsing; at most one Maven run per DevPanel project |
| Git | Branch / upstream / ahead-behind, grouped changes, status colors, three file layouts; independent unified / side-by-side diffs with inline highlighting | No dedicated Git command | File staging / unstaging, commit / amend and stash save / list / apply / pop are native UI operations |
| Service tool navigation | Open the Git repository or Maven project associated with the selected service | Register explicit repository / Maven paths in project configuration | Uses the deepest registered ancestor of the service working directory; no recursive discovery |
| Desktop and installation | Overview / detail layouts, shortcuts, background event notifications, CLI installation and optional login startup | Daemon start / stop / status / install / uninstall | Closing the UI leaves services running; standalone app bundles Node, daemon, CLI and sampler |

## What v0.4 adds

- [x] Startup verification: readiness signals and `--wait-ready` reports.
- [x] Efficient log handoff: bounded digests, incremental reads and native “copy digest”.
- [x] Operation attribution: actors, stop causes and a configuration activity timeline.
- [x] Human oversight: persistent holds, locks and agent force-stop restrictions.
- [x] Standalone packaging: embedded runtime, installation guidance, local ZIP and checksum generation.
- [x] Subsequent v0.4 improvements: explicit multiple Git / Maven roots, service tool navigation and clearer log presentation.
- [x] Public MIT repository with English and Simplified Chinese READMEs.
- [ ] First public version tag and downloadable GitHub Release.
- [ ] Successful remote CI for the release source, and remaining installation / architecture checks below.

## Current limits

- Supports macOS 14 or later. The app UI is primarily Simplified Chinese; bilingual repository documentation does not mean the UI is localized.
- No adoption of existing processes, remote hosts, container management, automatic restarts, HTTP readiness probes, continuous health checks or dependency orchestration.
- Holds and locks prevent unintended CLI actions; they are not a security boundary against another program running as the same OS user. Agent force stop is disabled by default, and only the UI can unlock a service.
- A daemon restart cannot reconnect old stdout pipes. Unrecoverable runs show an unknown state and log gap; seamless recovery is not guaranteed.
- Git does not offer fetch / pull / push, branch management, discard, conflict resolution or line-level staging. Hook output is shown after the commit finishes.
- Maven uses a static model, rather than Maven's effective model. There is no dependency graph, plugin browser or Gradle panel.
- Packages use ad-hoc signing, with no Developer ID signing, notarization, automatic updates or package-manager distribution. Intel packaging and the full installation flow on a clean Mac still require validation.

## Recommended v0.4 polish

These are proposed priorities, not additional implemented capabilities or an approved implementation plan.

| Priority | Work | Completion criterion |
| --- | --- | --- |
| P0 | Resolve the remote Swift build compatibility failure | The first completed public [CI run](https://github.com/CnHugo76/DevPanel/actions/runs/40162240195) passed TypeScript checks, tests and workspace build, but failed while compiling the notification API at `AppNotifications.swift:31` (`UNNotificationSettings` crossing an isolation boundary). The intended Xcode / Swift versions must build and pass tests remotely before tagging |
| P0 | Align version and release evidence | Choose the version, align package / app metadata, write changes since `v0.4.1`, build from an identified public commit, and match the tag, package and checksum |
| P0 | Finish installation acceptance | Verify Gatekeeper, CLI PATH, replacement confirmation, app relocation, login startup, notifications, upgrade and uninstall using isolated data; verify each advertised architecture |
| P1 | Complete the first-use path in both languages | A new user can install or build, add the demo, configure readiness, start, inspect output and stop using one short guide; missing tools / PATH / readiness have clear next steps |
| P1 | Make runtime and oversight states easier to act on | Running, waiting, ready, timed out and unknown each show evidence and a useful next action; hold / lock reasons and saved changes pending the next launch are clear |
| P1 | Strengthen logs and background behavior | Use representative log formats and large output to verify search, folding, navigation and raw copy; repeat resource checks for hidden windows, background operation and disconnects |
| P2 | Expand language coverage incrementally | Translate the demo and everyday guides first; plan native UI localization separately with maintained terminology and translation checks |

The recommended v0.4 focus is reliable installation, clear state and smooth daily use. Remote execution, container orchestration, automatic recovery and a broader Git client would require separate product decisions. API changes still follow the repository's contract proposal process.

## Evidence and references

Local validation recorded before publication passed 245 TypeScript / Web tests, 320 Swift tests, typechecking, builds, the isolated demo and an Apple Silicon standalone-runtime smoke check. These local results do not replace remote CI or manual installation acceptance. This checklist adds documentation only; it does not claim to resolve the remote Swift failure.

See [acceptance records](plan-v0.4.md), [native app guide](../apps/mac/README.md), [API contract](../contract/api.md), [v0.4 product design](product-design-v0.4.md), [packaging and migration](release-v0.4.md), and [publication notes](open-source.md).
