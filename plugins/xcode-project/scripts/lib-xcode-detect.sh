# shellcheck shell=sh
#
# Shared Xcode-project detection, sourced by this plugin's SessionStart hooks.
#
# A project counts as an Xcode project when a *.xcodeproj or *.xcworkspace
# bundle is found either downward from the project directory (bounded depth, so
# a workspace living one or two directories in is still found) or upward through
# its parents (so a session started in a subdirectory still matches).
#
# The upward walk stops at the project boundary — a directory holding .git or
# .claude. Without that it would run all the way to /, and one stray workspace
# in a shared parent such as ~/Projects would match every project underneath it.
#
# The signal is deliberately narrower than "Swift": a SwiftPM package or a
# server-side Swift repo has no .xcodeproj and gets nothing from this plugin.

xcode_project_detected() {
    _dir="${CLAUDE_PROJECT_DIR:-$PWD}"

    # Downward. Prune the directories that are big, uninteresting, or full of
    # derived copies of the very bundles being looked for.
    #
    # .swiftpm matters most: Xcode generates .swiftpm/xcode/package.xcworkspace
    # inside any SwiftPM package it has opened, so without pruning it every
    # package on the machine reads as an Xcode project — the exact case this
    # detection is meant to exclude.
    _found=$(find "$_dir" -maxdepth 3 \
        \( -name .git -o -name .swiftpm -o -name node_modules -o -name DerivedData \
           -o -name .build -o -name Carthage -o -name build \) -prune -o \
        -type d \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print 2>/dev/null \
        | head -n 1) || _found=""
    if [ -n "$_found" ]; then
        return 0
    fi

    # Upward: a bundle sitting directly in an ancestor directory, stopping once
    # the project boundary has been examined. Each level is checked for a bundle
    # first and only then for the boundary marker, so the boundary directory
    # itself — usually the repository root — still counts.
    #
    # .git is tested with -e rather than -d: in a linked worktree or a submodule
    # it is a file, and those are project boundaries just the same.
    _dir="${CLAUDE_PROJECT_DIR:-$PWD}"
    while [ -n "$_dir" ] && [ "$_dir" != "/" ]; do
        for _candidate in "$_dir"/*.xcodeproj "$_dir"/*.xcworkspace; do
            if [ -d "$_candidate" ]; then
                return 0
            fi
        done
        if [ -e "$_dir/.git" ] || [ -d "$_dir/.claude" ]; then
            return 1
        fi
        _dir=$(dirname "$_dir")
    done

    return 1
}
