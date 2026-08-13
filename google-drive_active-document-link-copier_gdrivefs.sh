#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Copy Active Document Google Drive Link (Drive for desktop)
# @raycast.mode silent
# @raycast.packageName Google Drive

set -uo pipefail

# Google Drive for desktop's File Provider location. Set GOOGLE_DRIVE_ROOT when
# a custom streaming location is configured in Drive for desktop.
DRIVE_ROOT_OVERRIDE="${GOOGLE_DRIVE_ROOT:-}"
DRIVE_ITEM_ID_XATTR='com.google.drivefs.item-id#S'

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Copy Active Document Google Drive Link\""
}

# Resolve firmlinks and symlinks so the Drive root and document use the same
# prefix when the document was opened through an alternate path.
canon() {
  local p="$1" d b
  d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
  b=$(basename "$p")
  printf '%s/%s' "${d#/System/Volumes/Data}" "$b"
}

find_drive_root_for_file() {
  local candidate candidate_real

  if [ -n "$DRIVE_ROOT_OVERRIDE" ]; then
    [ -d "$DRIVE_ROOT_OVERRIDE" ] || return 1
    candidate_real=$(canon "$DRIVE_ROOT_OVERRIDE") || return 1
    case "$file_real/" in
      "$candidate_real"/*) printf '%s' "$DRIVE_ROOT_OVERRIDE"; return 0 ;;
      *) return 1 ;;
    esac
  fi

  # Current macOS File Provider location. The glob also supports any account
  # name without hardcoding the user's email address.
  for candidate in "$HOME/Library/CloudStorage"/GoogleDrive-* "$HOME/Google Drive"; do
    [ -d "$candidate" ] || continue
    candidate_real=$(canon "$candidate") || continue
    case "$file_real/" in
      "$candidate_real"/*) printf '%s' "$candidate"; return 0 ;;
    esac
  done

  return 1
}

get_ax_document_path() {
  local target_bundle="${1:-}" document_url path_enc

  # JXA's console.log is emitted on stderr by osascript on this macOS
  # version, so merge stderr to capture the AXDocument URL.
  document_url=$(/usr/bin/osascript -l JavaScript <<JXA 2>&1
const se = Application("System Events");
const targetBundle = "$target_bundle";
const processes = targetBundle
  ? se.processes.whose({ bundleIdentifier: targetBundle })()
  : se.processes.whose({ frontmost: true })();

for (const proc of processes) {
  const windows = proc.windows();
  let found = false;
  for (const win of windows) {
    const doc = win.attributes.byName("AXDocument").value();
    if (doc) {
      console.log(doc);
      found = true;
      break;
    }
  }
  if (found) break;
}
JXA
  )

  case "$document_url" in
    file://*)
      path_enc="${document_url#file://}"
      case "$path_enc" in
        localhost/*) path_enc="/${path_enc#localhost/}" ;;
      esac
      printf '%b' "${path_enc//%/\\x}"
      ;;
    *)
      return 1
      ;;
  esac
}

# Get the active document path. Office applications expose a more reliable
# path through AppleScript; other apps expose it through AXDocument.
bundle_id=$(/usr/bin/osascript -e '
  tell application "System Events"
    return bundle identifier of first application process whose frontmost is true
  end tell
' 2>/dev/null)

case "$bundle_id" in
  com.microsoft.Excel)
    file_path=$(/usr/bin/osascript -e '
      tell application "Microsoft Excel"
        if not (exists active workbook) then error "開いているブックがありません"
        return POSIX path of (full name of active workbook as alias)
      end tell
    ' 2>/dev/null)
    ;;
  com.microsoft.Word)
    file_path=$(/usr/bin/osascript -e '
      tell application "Microsoft Word"
        if not (exists active document) then error "開いている文書がありません"
        return POSIX path of (full name of active document as alias)
      end tell
    ' 2>/dev/null)
    ;;
  com.microsoft.Powerpoint)
    file_path=$(/usr/bin/osascript -e '
      tell application "Microsoft PowerPoint"
        if not (exists active presentation) then error "開いているプレゼンテーションがありません"
        return POSIX path of (full name of active presentation as alias)
      end tell
    ' 2>/dev/null)
    ;;
  *)
    file_path=$(get_ax_document_path)
    ;;
esac

# PowerPoint can expose the document through AX while its AppleScript bridge
# fails, for example when a modal formatting dialog is open. Use the app's
# own process rather than relying on whichever process is frontmost.
case "$bundle_id" in
  com.microsoft.Excel|com.microsoft.Word|com.microsoft.Powerpoint)
    if [ -z "${file_path:-}" ] || [ ! -e "$file_path" ]; then
      file_path=$(get_ax_document_path "$bundle_id")
    fi
    ;;
esac

if [ -z "${file_path:-}" ] || [ ! -e "$file_path" ]; then
  notify "最前面ウィンドウから保存済みファイルを取得できません"
  exit 1
fi

file_real=$(canon "$file_path") || {
  notify "ファイルパスを解決できません"
  exit 1
}

drive_root=$(find_drive_root_for_file) || {
  notify "ファイルはGoogle Drive for desktopの同期場所外です"
  exit 1
}

# Drive for desktop stores the Drive item ID on the File Provider entry. This
# avoids rclone, a Drive API credential, and a remote directory name lookup.
id=$(/usr/bin/xattr -p "$DRIVE_ITEM_ID_XATTR" "$file_real" 2>/dev/null | tr -d '\r\n')

case "$id" in
  ''|*[!A-Za-z0-9_-]*)
    notify "Drive項目IDを取得できません（同期完了前または未対応のファイルです）"
    exit 1
    ;;
esac

build_url() {
  local path_lower
  path_lower=$(printf '%s' "$file_real" | tr '[:upper:]' '[:lower:]')

  # Google editor placeholders use the editor-specific URL copied by Finder's
  # Drive for desktop action. Binary files use the Drive web URL format.
  case "$path_lower" in
    *.gdoc)
      printf 'https://docs.google.com/document/d/%s?usp=drive_fs' "$id"
      ;;
    *.gsheet)
      printf 'https://docs.google.com/spreadsheets/d/%s?usp=drive_fs' "$id"
      ;;
    *.gslides)
      printf 'https://docs.google.com/presentation/d/%s?usp=drive_fs' "$id"
      ;;
    *.gdraw|*.gdrawings)
      printf 'https://docs.google.com/drawings/d/%s?usp=drive_fs' "$id"
      ;;
    *)
      printf 'https://drive.google.com/open?id=%s&usp=drive_fs' "$id"
      ;;
  esac
}

url=$(build_url)
if ! printf '%s' "$url" | /usr/bin/pbcopy; then
  notify "Google Driveリンクのコピーに失敗しました"
  exit 1
fi

notify "Google Driveリンクをコピーしました"
