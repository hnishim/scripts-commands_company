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
validator_runner="$(mktemp -u).applescript"
trap 'rm -f "${expected_metadata:-}" "${actual_metadata:-}" "$prefix_file" "$compiled_script" "$validator_runner"' EXIT

osacompile -o "$compiled_script" "$SCRIPT_PATH"
cat > "$validator_runner" <<'APPLESCRIPT'
on run argv
    set candidateScript to load script POSIX file (item 1 of argv)
    set candidateURL to item 2 of argv
    return candidateScript's isValidSlackURL(candidateURL)
end run
APPLESCRIPT

assert_validation() {
    local value="$1"
    local expected="$2"
    local actual
    actual="$(osascript "$validator_runner" "$compiled_script" "$value")"
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

# The invalid-URL guard itself must terminate before any Slack/UI/clipboard side effect.
first_side_effect_line="$(grep -niE '(activate|set[[:space:]]+the[[:space:]]+clipboard|open[[:space:]]+location|keystroke|key[[:space:]]+code)' "$SCRIPT_PATH" | head -n 1 | cut -d: -f1 || true)"
[ -n "$first_side_effect_line" ] || fail 'no Slack/UI/clipboard side-effect operation found'
head -n "$((first_side_effect_line - 1))" "$SCRIPT_PATH" > "$prefix_file"

guard_status=0
awk '
BEGIN { in_guard = 0; nested = 0; terminated = 0; found = 0 }
{
    lower = tolower($0)

    if (!in_guard && lower ~ /if[[:space:]]+not[[:space:]]+isvalidslackurl[[:space:]]*\(/) {
        found = 1
        in_guard = 1

        # One-line guard: "if not ... then return/error"
        if (lower ~ /then[[:space:]]+(return|error)([[:space:]]|$)/) {
            terminated = 1
            exit
        }
        next
    }

    if (in_guard) {
        if (lower ~ /^[[:space:]]*if[[:space:]].*then[[:space:]]*$/) {
            nested++
        }

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
    2) fail 'isValidSlackURL invalid-value guard must appear before the first side effect' ;;
    3) fail 'the isValidSlackURL invalid-value guard must itself return/error before the first side effect' ;;
    *) fail 'could not verify the invalid-value guard' ;;
esac

# HIR-251 permanent safety regressions.
# These checks intentionally cover source-level invariants only. They do not
# claim that Slack Accessibility targeting, timeout behavior, single-run
# exclusion, or pasteboard restoration work on a real Mac; those remain
# explicit local acceptance checks.
return_send_count="$(grep -Ec '^[[:space:]]*key code[[:space:]]+36([[:space:]]|$)' "$SCRIPT_PATH" || true)"
[ "$return_send_count" -le 1 ] || fail 'more than one Return-style send operation is present'

if grep -Eq '^[[:space:]]*key code[[:space:]]+36[[:space:]]+using[[:space:]]+\{command down\}' "$SCRIPT_PATH"; then
    fail 'Cmd+Return fallback send must not coexist with the primary send path'
fi

# Preserving only a string is insufficient: HIR-251 requires the general
# pasteboard item/type structure to be saved before mutation and written back.
pasteboard_backup_line="$(grep -nE 'pasteboardItems' "$SCRIPT_PATH" | head -n 1 | cut -d: -f1 || true)"
pasteboard_clear_line="$(grep -nE 'clearContents' "$SCRIPT_PATH" | head -n 1 | cut -d: -f1 || true)"
pasteboard_restore_line="$(grep -nE 'writeObjects:' "$SCRIPT_PATH" | tail -n 1 | cut -d: -f1 || true)"

[ -n "$pasteboard_backup_line" ] || fail 'pasteboard items are not backed up before mutation'
[ -n "$pasteboard_clear_line" ] || fail 'pasteboard mutation point is missing'
[ -n "$pasteboard_restore_line" ] || fail 'pasteboard items are not restored after mutation'
[ "$pasteboard_backup_line" -lt "$pasteboard_clear_line" ] || fail 'pasteboard backup must occur before clearContents'
[ "$pasteboard_restore_line" -gt "$pasteboard_clear_line" ] || fail 'pasteboard restoration must occur after mutation'

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
