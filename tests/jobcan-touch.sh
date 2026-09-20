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
# HIR-285: Keychain is the sole source; failures must never use the old environment.
require_literal 'my.slack.url-dm-myself' "$SCRIPT_PATH"
require_literal 'find-generic-password' "$SCRIPT_PATH"
require_literal '/usr/bin/security' "$SCRIPT_PATH"
require_literal '"-s"' "$SCRIPT_PATH"
require_literal '"-a"' "$SCRIPT_PATH"
require_literal '"my"' "$SCRIPT_PATH"
require_literal 'Keychain' "$README_PATH"
if grep -Eq 'NSProcessInfo|launchdEnvironmentValue|launchctl|getenv|objectForKey:"JOBCAN_SLACK_URL"' "$SCRIPT_PATH"; then
    fail 'legacy Slack URL environment lookup remains in production source'
fi

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
    sub(/on[[:space:]]+run[[:space:]]+argv/, "on productionRun(argv)")
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

flow_call_count="$(awk '!/^[[:space:]]*--/ && index($0, "runJobcanWithProvider") { count++ } END { print count + 0 }' "$run_block_file")"
[ "$flow_call_count" -eq 1 ] || fail 'production run must delegate to the tested URL-provider gate exactly once'
require_literal 'keychainURLProvider' "$run_block_file"

if grep -Eq 'tell application "Slack"|keystroke|key[[:space:]]+code|openURL:|clearContents|setString:' "$run_block_file"; then
    fail 'production run must delegate UI/pasteboard side effects through the tested entry gate'
fi

flow_call_line="$(awk '!/^[[:space:]]*--/ && index($0, "runJobcanWithProvider") { print NR; exit }' "$run_block_file")"
[ -n "$flow_call_line" ] || fail 'production run does not call executeJobcanFlow'
head -n "$((flow_call_line - 1))" "$run_block_file" > "$prefix_file"

# The real run delegates to the separately tested entry gate; only that gate
# may continue to executeJobcanFlow after successfully validating the URL.
require_literal 'runJobcanWithProvider' "$SCRIPT_PATH"
require_literal 'isValidSlackURL' "$SCRIPT_PATH"

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

    if testMode is not "flow" and testMode is not "entry" and testMode is not "provider" then error "unknown test mode"
    set scenarioName to item 2 of argv

    script fakeAdapter
        property configuredSlackURL : ""
        property expectedURL : ""
        property lockAvailable : true
        property composerReady : true
        property failureStage : ""
        property eventLog : {}

        on recordEvent(eventName)
            set my eventLog to my eventLog & {eventName}
        end recordEvent

        on acquireSingleRunGuard()
            my recordEvent("lock")
            return my lockAvailable
        end acquireSingleRunGuard

        on activateSlack()
            my recordEvent("activate")
        end activateSlack

        on openConfiguredConversation()
            if my configuredSlackURL is not my expectedURL then error "Keychain URL not propagated"
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

    -- Test the production provider with a fake command executor. No real Keychain
    -- or Slack request occurs, and no secret is copied into error output.
    if testMode is "provider" then
        script fakeSecurityRunner
            property calls : 0
            property resultCode : 0
            property resultOutput : "slack://channel?team=T123&id=C456"
            property deny : false

            on runSecurity(commandPath, commandArguments)
                set my calls to my calls + 1
                if commandPath is not "/usr/bin/security" then error "incorrect security binary"
                if commandArguments is not {"find-generic-password", "-w", "-s", "my.slack.url-dm-myself", "-a", "my"} then error "incorrect service or account"
                if my deny then error "NEVER-EXPOSE synthetic denial"
                return {exitCode:(my resultCode), stdoutText:(my resultOutput)}
            end runSecurity
        end script
        if scenarioName is "missing" then
            set fakeSecurityRunner's resultCode to 44
        else if scenarioName is "access-denied" then
            set fakeSecurityRunner's deny to true
        else if scenarioName is "empty" then
            set fakeSecurityRunner's resultOutput to ""
        else if scenarioName is "nonzero-with-output" then
            set fakeSecurityRunner's resultCode to 36
        else if scenarioName is not "success" then
            error "unknown provider scenario"
        end if
        set originalRunner to keychainURLProvider's commandRunner
        set keychainURLProvider's commandRunner to fakeSecurityRunner
        set providerValue to missing value
        set leakedError to ""
        try
            set providerValue to keychainURLProvider's readSlackURL()
        on error messageText
            set leakedError to messageText
        end try
        set keychainURLProvider's commandRunner to originalRunner
        if fakeSecurityRunner's calls is not 1 then error "Keychain command must run once"
        if leakedError is not "" then error "Keychain provider leaked or raised an error"
        if scenarioName is "success" then
            if providerValue is not fakeSecurityRunner's resultOutput then error "Keychain output altered"
        else
            if providerValue is not "" then error "Keychain failure not rejected"
        end if
        return "provider-checked"
    end if

    -- The provider is a test-only replacement for Keychain; no real Slack is invoked.
    if testMode is "entry" then
        script fakeURLProvider
            property suppliedURL : ""
            property denyRead : false
            property readCount : 0

            on readSlackURL()
                set my readCount to my readCount + 1
                if my denyRead then error "synthetic Keychain read failure"
                return my suppliedURL
            end readSlackURL
        end script

        if scenarioName is "success-a" then
            set fakeURLProvider's suppliedURL to "slack://channel?team=T123&id=C456"
        else if scenarioName is "success-b" then
            set fakeURLProvider's suppliedURL to "slack://channel?team=T987&id=D654"
        else if scenarioName is "missing" or scenarioName is "access-denied" then
            set fakeURLProvider's denyRead to true
        else if scenarioName is "empty" or scenarioName is "legacy-only" then
            set fakeURLProvider's suppliedURL to ""
        else if scenarioName is "malformed" then
            set fakeURLProvider's suppliedURL to "slack://channel?team=T123&id=C456&extra=1"
        else
            error "unknown entry scenario"
        end if

        set fakeAdapter's expectedURL to fakeURLProvider's suppliedURL
        set observedError to false
        try
            runJobcanWithProvider(fakeAdapter, fakeURLProvider)
        on error
            set observedError to true
        end try
        if observedError then error "provider failure must not leak to the caller"
        if fakeURLProvider's readCount is not 1 then error "provider must be read once"
        if scenarioName is "success-a" or scenarioName is "success-b" then
            if fakeAdapter's configuredSlackURL is not fakeURLProvider's suppliedURL then error "Keychain URL not delivered"
        else
            if fakeAdapter's configuredSlackURL is not "" then error "invalid URL reached adapter"
            if (count of fakeAdapter's eventLog) is not 0 then error "invalid URL caused side effects"
        end if
        return joinEvents(fakeAdapter's eventLog)
    end if

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
    return joinEvents(fakeAdapter's eventLog)
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

# HIR-285 permanent safety regressions: the same production gate is exercised
# with a test-only URL provider and a test-only UI adapter.
assert_entry_events() {
    local scenario="$1"
    local expected="$2"
    local actual
    actual="$(osascript "$testable_script" entry "$scenario")"
    [ "$actual" = "$expected" ] || fail "entry scenario $scenario events '$actual', expected '$expected'"
}
assert_entry_events success-a 'lock,activate,open,wait,backup,set-command,paste,send,restore,release'
assert_entry_events success-b 'lock,activate,open,wait,backup,set-command,paste,send,restore,release'
assert_entry_events missing ''
assert_entry_events access-denied ''
assert_entry_events empty ''
assert_entry_events malformed ''
JOBCAN_SLACK_URL='slack://channel?team=T123&id=C456' assert_entry_events legacy-only ''

# Production-provider command-boundary regressions (real Keychain is mocked).
assert_provider_scenario() {
    local scenario="$1"
    local actual
    actual="$(osascript "$testable_script" provider "$scenario")"
    [ "$actual" = "provider-checked" ] || fail "provider scenario $scenario failed"
}
for scenario in success missing access-denied empty nonzero-with-output; do
    assert_provider_scenario "$scenario"
done

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
