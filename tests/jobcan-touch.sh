#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${JOBCAN_SCRIPT_PATH:-$ROOT_DIR/jobcan-touch.applescript}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_literal() { grep -Fq -- "$1" "$SCRIPT_PATH" || fail "missing contract: $2"; }
[ -f "$SCRIPT_PATH" ] || fail 'Jobcan Script Command is missing'

# Behavior contract, not the previous Accessibility adapter's internal shape.
require_literal '@raycast.schemaVersion' 'Raycast schema'
require_literal '@raycast.title' 'Raycast title'
require_literal '@raycast.mode' 'Raycast mode'
require_literal '@raycast.description' 'Raycast description'
require_literal '/jobcan_touch' 'Slack command'
require_literal 'on isValidSlackURL' 'URL validator'
require_literal 'find-generic-password' 'Keychain lookup'
require_literal 'my.slack.url-dm-myself' 'Keychain service'

if grep -Fq 'JOBCAN_SLACK_URL' "$SCRIPT_PATH"; then
    fail 'legacy environment URL source remains in production script'
fi
if grep -Eq 'slack://channel\?team=[A-Za-z0-9][A-Za-z0-9_-]*&id=[A-Za-z0-9][A-Za-z0-9_-]*' "$SCRIPT_PATH"; then
    fail 'public script embeds a concrete conversation URL'
fi

# Exactly one Return send; no Cmd+Return fallback or automatic retry.
send_count="$(grep -Ec '^[[:space:]]*key code[[:space:]]+36([[:space:]]|$)' "$SCRIPT_PATH" || true)"
[ "$send_count" -eq 1 ] || fail 'expected exactly one Return-style send operation'
if grep -Eq '^[[:space:]]*key code[[:space:]]+36[[:space:]]+using[[:space:]]+\{command down\}' "$SCRIPT_PATH"; then
    fail 'Cmd+Return fallback risks a duplicate send'
fi

# Synthetic URL tests invoke the real pure validator; no Keychain/UI side effects.
if command -v osascript >/dev/null 2>&1 && command -v osacompile >/dev/null 2>&1; then
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    osacompile -o "$temp_dir/jobcan.scpt" "$SCRIPT_PATH"
    awk '
        /^on isValidSlackIdentifier\(/ { copying=1; found_start=1 }
        copying { print }
        /^end isValidSlackURL/ { found_end=1; exit }
        END { if (!found_start || !found_end) exit 2 }
    ' "$SCRIPT_PATH" > "$temp_dir/validator.applescript" || fail 'cannot extract URL validator'
    cat >> "$temp_dir/validator.applescript" <<'APPLESCRIPT'

on run argv
    return isValidSlackURL(item 1 of argv)
end run
APPLESCRIPT
    assert_url() {
        local actual
        actual="$(osascript "$temp_dir/validator.applescript" "$1")" || fail 'URL validation execution failed'
        [ "$actual" = "$2" ] || fail "unexpected URL validation result (expected $2)"
    }
    assert_url 'slack://channel?team=T123&id=C456' true
    assert_url '' false
    assert_url 'https://channel?team=T123&id=C456' false
    assert_url 'slack://channel?team=T123' false
    assert_url 'slack://channel?team=&id=C456' false
    assert_url 'slack://channel?team=T123&id=' false
    assert_url 'slack://channel?team=T123&id=C456&extra=1' false
    printf '%s\n' 'PASS: AppleScript compilation and synthetic URL validation'
else
    printf '%s\n' 'SKIP: AppleScript compilation and synthetic URL validation require macOS'
fi

# Optional transition-only comparison with private registration metadata.
if [ -n "${JOBCAN_METADATA_REFERENCE:-}" ]; then
    [ -f "$JOBCAN_METADATA_REFERENCE" ] || fail 'metadata reference is unavailable'
    metadata_actual="$(grep -E '^[[:space:]]*#[[:space:]]*@raycast\.' "$SCRIPT_PATH")"
    metadata_expected="$(grep -E '^[[:space:]]*#[[:space:]]*@raycast\.' "$JOBCAN_METADATA_REFERENCE")"
    [ "$metadata_actual" = "$metadata_expected" ] || fail 'Raycast registration metadata changed'
else
    printf '%s\n' 'SKIP: private-source metadata comparison (reference not supplied)'
fi

# Optional scan; secrets are supplied locally, never printed or committed.
if [ -n "${JOBCAN_FORBIDDEN_VALUES:-}" ]; then
    command -v git >/dev/null 2>&1 || fail 'git is needed for private-value history scan'
    while IFS= read -r forbidden_value; do
        [ -n "$forbidden_value" ] || continue
        while IFS= read -r commit; do
            if git -C "$ROOT_DIR" grep -F -q -- "$forbidden_value" "$commit" -- .; then
                fail "private value found in reachable history at $commit"
            fi
        done < <(git -C "$ROOT_DIR" rev-list --all)
    done <<< "$JOBCAN_FORBIDDEN_VALUES"
else
    printf '%s\n' 'SKIP: private-value history scan (values not supplied)'
fi

printf '%s\n' 'PASS: static Keychain-source, confidentiality and single-send contracts'
printf '%s\n' 'UNVERIFIED: Keychain account/read failure handling, target DM and draft, Raycast binding, clipboard behavior and actual Slack delivery require macOS acceptance.'
