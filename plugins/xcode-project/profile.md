## Xcode project

This project contains an Xcode project or workspace, so the `mcp__xcode__*`
tools are available. Availability is not a reason to prefer them: a repository
can hold both an Xcode app target and SwiftPM packages, and for a package
`swift build` and `swift test` are usually the simpler, faster route. Choose by
what is actually being worked on.

### Ask before putting the app on a real screen

Launching the app on a **physical device or on this Mac** takes over a screen the
user may be looking at. An iPhone or iPad attached over WiFi will wake and
foreground the app wherever it happens to be, which during a long unattended task
is an unwelcome interruption.

So before anything that installs, launches, or resumes the app on a physical
device or on this Mac, ask first — and ask with the **AskUserQuestion tool**
rather than in plain text, because that reaches the user when they are away from
the keyboard and lets them answer from their phone.

**The simulator is exempt.** Simulator runs are offscreen and invisible, so use
them freely and never ask. Where the simulator would answer the same question,
prefer it and skip the ask entirely — the best way to avoid interrupting is to
not need the device.

Which case applies is decided by the **run destination**, and that is Xcode's
current selection rather than something the tool call spells out. Check it with
`mcp__xcode__XcodeListRunDestinations` before running rather than assuming.

The rule is about the act of launching, not about one list of tools. It covers
`RunProject`, `DeviceInteractionInstallAndRun`, the `DeviceInteractionStart*`
session tools, `RunAllTests` and `RunSomeTests` against a device destination,
`InvokeDebuggerCommand` when it resumes a process — and every shell equivalent,
including `xcodebuild test -destination`, `xcrun devicectl`, `open -a`,
`swift run` for a GUI executable, and any script that ends up doing one of those.

What matters is a window appearing in front of the user, not code executing.
Building, static analysis, `RenderPreview`, reading logs or crash reports, and
running a command-line executable or a `swift test` suite that puts nothing
onscreen all need no permission.

### How long permission lasts

Use judgement. The goal is one ask, not a prompt per launch.

- Ask at the moment of the launch, not in advance. Permission granted half an
  hour earlier defeats the purpose, because the interruption still arrives
  unannounced.
- A yes covers continued iteration on **that** destination: run, fix, run again.
- Ask again when the destination changes (a different device, or Mac ↔
  simulator ↔ device), when the user has said to stop, or when the session has
  moved on to unrelated work.
- If the user declines or does not answer, fall back to the simulator or a plain
  build, say plainly what was skipped, and get on with the rest of the task.
