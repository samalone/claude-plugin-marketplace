## Xcode project

This project contains an Xcode project or workspace, so the `mcp__xcode__*`
tools are available. Availability is not a reason to prefer them: a repository
can hold both an Xcode app target and SwiftPM packages, and for a package
`swift build` and `swift test` are usually the simpler, faster route. Choose by
what is actually being worked on.

### Ask before putting the app on a screen

Launching the app on a **physical device or on this Mac** takes over a screen the
user may be looking at. An iPhone or iPad attached over WiFi will wake and
foreground the app wherever it happens to be, which during a long unattended task
is an unwelcome interruption.

So before anything that installs, launches, or resumes the app on a physical
device or on this Mac, ask first — and ask with the **AskUserQuestion tool**
rather than in plain text, because that reaches the user when they are away from
the keyboard and lets them answer from their phone.

What matters is a window appearing in front of the user, not code executing.
Building, static analysis, `RenderPreview`, reading logs or crash reports, and
running a command-line executable or a `swift test` suite that puts nothing
onscreen all need no permission.

For the device and Mac cases, which one applies is decided by the **run
destination** — Xcode's current selection, not something the tool call spells
out. Check it with `mcp__xcode__XcodeListRunDestinations` rather than assuming;
a project left pointing at a real iPhone will happily install onto it. The rule
covers `RunAllTests` and `RunSomeTests` against a device destination,
`InvokeDebuggerCommand` when it resumes a process, and every shell equivalent,
including `xcodebuild test -destination`, `xcrun devicectl`, `open -a`, and
`swift run` for a GUI executable.

### The simulator is not automatically offscreen

Xcode 27 replaced Simulator.app with **Device Hub**, so "simulator" no longer
means "invisible". On a simulator destination the **tool** decides, not the
destination:

- **Invisible — use freely:** `xcrun simctl boot`, `install` and
  `launch`; `xcodebuild` building against a simulator destination;
  `XcodeSwitchRunDestination`; `DeviceInteractionStartWorkspaceSession`, which
  boots the device headlessly.
- **Steals focus — ask first:** `RunProject`,
  `DeviceInteractionInstallAndRun`, and `open` on DeviceHub.app or any GUI app.

So when the goal is "does this work" rather than "watch the app", run the whole
cycle invisibly: `xcodebuild` to build, `simctl install` and `launch` to run,
and `xcrun simctl spawn booted log stream --level debug --predicate '...'` for
output.

### How long permission lasts

Use judgement. The goal is one ask, not a prompt per launch.

- Ask at the moment of the launch, not in advance. Permission granted half an
  hour earlier defeats the purpose, because the interruption still arrives
  unannounced.
- A yes covers continued iteration on **that** destination: run, fix, run again.
- Ask again when the destination changes (a different device, or Mac ↔
  simulator ↔ device), when the user has said to stop, or when the session has
  moved on to unrelated work.
- If the user declines or does not answer, fall back to a plain build or the
  invisible `simctl` route, say plainly what was skipped, and get on with the
  rest of the task.
