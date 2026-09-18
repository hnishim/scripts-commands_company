#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${JOBCAN_SCRIPT_PATH:-$ROOT_DIR/jobcan-touch.applescript}"
README_PATH="$ROOT_DIR/README.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_literal() {
    local literal="$1"
    local file="$2"
    grep -Fq -- "$literal" "$file" || fail "missing required text in ${file#$ROOT_DIR/}: $literal"
}

[ -f "$SCRIPT_PATH" ] || fail "missing Jobcan Script Command: ${SCRIPT_PATH#$ROOT_DIR/}"
[ -f "$README_PATH" ] || fail "missing README.md"

# Baseline Raycast Script Command shape and command contract.
# Exact metadata-value preservation is checked against the private source when
# JOBCAN_METADATA_REFERENCE is supplied; mere key presence is not treated as
# the adjacent-regression guarantee.
require_literal '@raycast.schemaVersion' "$SCRIPT_PATH"
require_literal '@raycast.title' "$SCRIPT_PATH"
require_literal '@raycast.mode' "$SCRIPT_PATH"
require_literal '@raycast.description' "$SCRIPT_PATH"
require_literal '/jobcan_touch' "$SCRIPT_PATH"
require_literal 'JOBCAN_SLACK_URL' "$SCRIPT_PATH"
require_literal 'JOBCAN_SLACK_URL' "$README_PATH"

if [ -n "${JOBCAN_METADATA_REFERENCE:-}" ]; then
    [ -f "$JOBCAN_METADATA_REFERENCE" ] || fail 'JOBCAN_METADATA_REFERENCE does not exist'
    expected_metadata="$(mktemp)"
    actual_metadata="$(mktemp)"
    trap 'rm -f "$expected_metadata" "$actual_metadata" "${prefix_file:-}" "${compiled_script:-}" "${validator_runner:-}"' EXIT
    grep -E '^[[:space:]]*#[[:space:]]*@raycast\.' "$JOBCAN_METADATA_REFERENCE" > "$expected_metadata" || fail 'reference source has no Raycast metadata'
    grep -E '^[[:space:]]*#[[:space:]]*@raycast\.' "$SCRIPT_PATH" > "$actual_metadata" || fail 'public source has no Raycast metadata'
    diff -u "$expected_metadata" "$actual_metadata" >/dev/null || fail 'Raycast metadata differs from the private source'
else
    printf '%s\n' 'SKIP: exact Raycast metadata comparison (JOBCAN_METADATA_REFERENCE is not set)'
fi

# A concrete workspace/conversation deeplink must never be embedded in the public script.
if grep -Eq 'slack://channel\?team=[A-Za-z0-9][A-Za-z0-9_-]*&id=[A-Za-z0-9][A-Za-z0-9_-]*' "$SCRIPT_PATH"; then
    fail 'public script contains a concrete Slack channel deeplink'
fi

# The production validator is tested directly without invoking Slack/UI side effects.
require_literal 'on isValidSlackURL' "$SCRIPT_PATH"
command -v osacompile >/dev/null 2>&1 || fail 'osacompile is required (run this test on macOS)'
command -v osascript >/dev/null 2>&1 || fail 'osascript is required (run this test on macOS)'

prefix_file="$(mktemp)"
compiled_script="$(mktemp -u).scpt"
testable_script="$(mktemp -u).applescript"
run_block_file="$(mktemp)"
trap 'rm -f "${expected_metadata:-}" "${actual_metadata:-}" "$prefix_file" "$compiled_script" "$testable_script" "$run_block_file"' EXIT

osacompile -o "$compiled_script" "$SCRIPT_PATH"

# Build a side-effect-free test harness from the production source without
# using `load script`. The real Raycast `run` handler is renamed only in the
# temporary copy; production handlers remain otherwise unchanged.
awk '
BEGIN { renamed = 0 }
!renamed && /^[[:space:]]*on[[:space:]]+run[[:space:]]+argv[[:space:]]*$/ {
    sub(/on[[:space:]]+run[[:space:]]+argv/, "on productionRun argv")
    renamed = 1
}
{ print }
END {
    if (!renamed) exit 2
}
' "$SCRIPT_PATH" > "$testable_script" || fail 'could not create testable AppleScript source'

# The real Raycast entry point must delegate to the same flow exercised below.
awk '
BEGIN { in_run = 0; found = 0 }
{
    if (!in_run && $0 ~ /^[[:space:]]*on[[:space:]]+run[[:space:]]+argv[[:space:]]*$/) {
        in_run = 1
        found = 1
    }
    if (in_run) print
    if (in_run && $0 ~ /^[[:space:]]*end[[:space:]]+run[[:space:]]*$/) exit
}
END {
    if (!found) exit 2
}
' "$SCRIPT_PATH" > "$run_block_file" || fail 'could not extract production run handler'

flow_call_count="$(awk '!/^[[:space:]]*--/ && index($0, "executeJobcanFlow") { count++ } END { print count + 0 }' "$run_block_file")"
[ "$flow_call_count" -eq 1 ] || fail 'production run must call executeJobcanFlow exactly once'

if grep -Eq 'tell application "Slack"|keystroke|key[[:space:]]+code|openURL:|clearContents|setString:' "$run_block_file"; then
    fail 'production run must delegate UI/pasteboard side effects through executeJobcanFlow'
fi

flow_call_line="$(awk '!/^[[:space:]]*--/ && index($0, "executeJobcanFlow") { print NR; exit }' "$run_block_file")"
[ -n "$flow_call_line" ] || fail 'production run does not call executeJobcanFlow'
head -n "$((flow_call_line - 1))" "$run_block_file" > "$prefix_file"

guard_status=0
awk '
BEGIN { in_guard = 0; nested = 0; terminated = 0; found = 0 }
{
    lower = tolower($0)

    if (!in_guard && lower ~ /if[[:space:]]+not[[:space:]]+isvalidslackurl[[:space:]]*\(/) {
        found = 1
        in_guard = 1

        if (lower ~ /then[[:space:]]+(return|error)([[:space:]]|$)/) {
            terminated = 1
            exit
        }
        next
    }

    if (in_guard) {
        if (lower ~ /^[[:space:]]*if[[:space:]].*then[[:space:]]*$/) nested++

        if (nested == 0 && lower ~ /^[[:space:]]*(return|error)([[:space:]]|$)/) {
            terminated = 1
        }

        if (lower ~ /^[[:space:]]*end[[:space:]]+if[[:space:]]*$/) {
            if (nested > 0) {
                nested--
            } else {
                exit
            }
        }
    }
}
END {
    if (!found) exit 2
    if (!terminated) exit 3
}
' "$prefix_file" || guard_status=$?
case "$guard_status" in
    0) ;;
    2) fail 'isValidSlackURL invalid-value guard must precede executeJobcanFlow' ;;
    3) fail 'isValidSlackURL invalid-value guard must return/error before executeJobcanFlow' ;;
    *) fail 'could not verify the invalid-value guard' ;;
esac

cat >> "$testable_script" <<'APPLESCRIPT'

on joinEvents(eventList)
    set previousDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to ","
    set joinedEvents to eventList as text
    set AppleScript's text item delimiters to previousDelimiters
    return joinedEvents
end joinEvents

on run argv
    set testMode to item 1 of argv

    if testMode is "validate" then
        return isValidSlackURL(item 2 of argv)
    end if

    if testMode is not "flow" then error "unknown test mode"
    set scenarioName to item 2 of argv

    script fakeAdapter
        property lockAvailable : true
        property composerReady : true
        property failureStage : ""
        property events : {}

        on recordEvent(eventName)
            set my events to my events & {eventName}
        end recordEvent

        on acquireSingleRunGuard()
            my recordEvent("lock")
            return my lockAvailable
        end acquireSingleRunGuard

        on activateSlack()
            my recordEvent("activate")
        end activateSlack

        on openConfiguredConversation()
            my recordEvent("open")
        end openConfiguredConversation

        on waitForComposer()
            my recordEvent("wait")
            return my composerReady
        end waitForComposer

        on backupPasteboard()
            my recordEvent("backup")
            if my failureStage is "backup" then error "synthetic backup failure"
            return "snapshot"
        end backupPasteboard

        on writeCommandToPasteboard(commandText)
            my recordEvent("set-command")
            if commandText is not "/jobcan_touch" then error "unexpected command"
            if my failureStage is "set-command" then error "synthetic set-command failure"
        end writeCommandToPasteboard

        on focusComposerAndPaste()
            my recordEvent("paste")
            if my failureStage is "paste" then error "synthetic paste failure"
        end focusComposerAndPaste

        on sendCommand()
            my recordEvent("send")
            if my failureStage is "send" then error "synthetic send failure"
        end sendCommand

        on restorePasteboard(snapshotValue)
            my recordEvent("restore")
            if snapshotValue is not "snapshot" then error "unexpected pasteboard snapshot"
        end restorePasteboard

        on releaseSingleRunGuard()
            my recordEvent("release")
        end releaseSingleRunGuard
    end script

    set expectedError to false
    if scenarioName is "lock-unavailable" then
        set fakeAdapter's lockAvailable to false
    else if scenarioName is "readiness-unavailable" then
        set fakeAdapter's composerReady to false
    else if scenarioName is "backup-failure" then
        set fakeAdapter's failureStage to "backup"
        set expectedError to true
    else if scenarioName is "set-command-failure" then
        set fakeAdapter's failureStage to "set-command"
        set expectedError to true
    else if scenarioName is "paste-failure" then
        set fakeAdapter's failureStage to "paste"
        set expectedError to true
    else if scenarioName is "send-failure" then
        set fakeAdapter's failureStage to "send"
        set expectedError to true
    else if scenarioName is not "success" then
        error "unknown scenario"
    end if

    set observedError to false
    try
        executeJobcanFlow(fakeAdapter)
    on error
        set observedError to true
    end try

    if observedError is not expectedError then error "unexpected flow error result"
    return joinEvents(fakeAdapter's events)
end run
APPLESCRIPT

assert_validation() {
    local value="$1"
    local expected="$2"
    local actual
    actual="$(osascript "$testable_script" validate "$value")"
    [ "$actual" = "$expected" ] || fail "isValidSlackURL returned $actual for '$value' (expected $expected)"
}

assert_validation 'slack://channel?team=T123&id=C456' true
assert_validation '' false
assert_validation 'https://channel?team=T123&id=C456' false
assert_validation 'slack://' false
assert_validation 'slack://channel' false
assert_validation 'slack://channel?team=T123' false
assert_validation 'slack://channel?id=C456' false
assert_validation 'slack://channel?team=&id=C456' false
assert_validation 'slack://channel?team=T123&id=' false
assert_validation 'slack://channel?id=C456&team=T123' false
assert_validation 'slack://channel?team=T123&id=C456&extra=1' false

# HIR-251 permanent safety regressions.
run_flow_scenario() {
    local scenario="$1"
    osascript "$testable_script" flow "$scenario"
}

assert_events() {
    local scenario="$1"
    local expected="$2"
    local actual
    actual="$(run_flow_scenario "$scenario")"
    [ "$actual" = "$expected" ] || fail "scenario $scenario events '$actual', expected '$expected'"
}

assert_events lock-unavailable 'lock'
assert_events readiness-unavailable 'lock,activate,open,wait,release'
assert_events backup-failure 'lock,activate,open,wait,backup,release'
assert_events set-command-failure 'lock,activate,open,wait,backup,set-command,restore,release'
assert_events success 'lock,activate,open,wait,backup,set-command,paste,send,restore,release'
assert_events paste-failure 'lock,activate,open,wait,backup,set-command,paste,restore,release'
assert_events send-failure 'lock,activate,open,wait,backup,set-command,paste,send,restore,release'

# Supplementary checks for the real Slack/pasteboard adapter.
return_send_count="$(grep -Ec '^[[:space:]]*key code[[:space:]]+36([[:space:]]|$)' "$SCRIPT_PATH" || true)"
[ "$return_send_count" -le 1 ] || fail 'more than one Return-style send operation is present'

if grep -Eq '^[[:space:]]*key code[[:space:]]+36[[:space:]]+using[[:space:]]+\{command down\}[[:space:]]*$' "$SCRIPT_PATH"; then
    fail 'Cmd+Return fallback send must not coexist with the primary send path'
fi

require_literal 'pasteboardItems' "$SCRIPT_PATH"
require_literal 'writeObjects:' "$SCRIPT_PATH"

# Exact private values are supplied only at test time and must not be written to the repository.
# Provide one forbidden value per line, for example the real workspace ID, conversation ID,
# or complete private deeplink. Every reachable Git commit is scanned.
if [ -n "${JOBCAN_FORBIDDEN_VALUES:-}" ]; then
    while IFS= read -r forbidden_value; do
        [ -n "$forbidden_value" ] || continue
        while IFS= read -r commit; do
            if git -C "$ROOT_DIR" grep -F -q -- "$forbidden_value" "$commit" -- .; then
                fail "a forbidden private value exists in Git history at $commit"
            fi
        done < <(git -C "$ROOT_DIR" rev-list --all)
    done <<< "$JOBCAN_FORBIDDEN_VALUES"
else
    printf '%s\n' 'SKIP: exact private-value history scan (JOBCAN_FORBIDDEN_VALUES is not set)'
fi

printf '%s\n' 'PASS: Jobcan validation, public-source safety, and AppleScript syntax checks'
printf '%s\n' 'NOTE: exact Raycast metadata preservation requires JOBCAN_METADATA_REFERENCE to point to the original private source.'
printf '%s\n' 'NOTE: real Raycast/Slack/Jobcan behavior remains a local/manual acceptance check.'
