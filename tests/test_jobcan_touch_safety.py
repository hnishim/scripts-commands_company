"""HIR-318: 外部送信を行わない安全境界の回帰テスト。"""
from __future__ import annotations

import platform
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "jobcan-touch.applescript"
OSASCRIPT = Path("/usr/bin/osascript")
EXTERNAL_EFFECT = re.compile(
    r"(?i)\btell\s+application\b|\bopen\s+(?:location|application|file)\b|\bopenURL\b|"
    r"\bset\s+the\s+clipboard\b|\bkeystroke\b|\bkey\s+code\b|"
    r"\bdo\s+shell\s+script\b|\bNSTask\b|\bNSWorkspace\b|"
    r"\bNSPasteboard\b|\bactivate\b|\b(?:run|load|store)\s+script\b|"
    r"\bperformSelector\b|\bNSAppleScript\b|"
    r"\bNSAppleEvent(?:Descriptor|Manager)\b|"
    r"\b(?:executeAndReturnError|compileAndReturnError)\b"
)
APPLE_SCRIPT_LITERALS = re.compile(r'"(?:[^"\\]|\\.)*"')
APPLE_SCRIPT_COMMENTS = re.compile(r"(?m)--.*$")
KEYCHAIN_READ_ONLY_FORBIDDEN = re.compile(
    r"(?i)\btell\s+application\b|\bopen\s+(?:location|application|file)\b|\bopenURL\b|"
    r"\bset\s+the\s+clipboard\b|\bkeystroke\b|\bkey\s+code\b|"
    r"\bdo\s+shell\s+script\b|\bNSWorkspace\b|\bNSPasteboard\b|"
    r"\bactivate\b|\b(?:run|load|store)\s+script\b|\bNSAppleScript\b|"
    r"\bNSAppleEvent(?:Descriptor|Manager)\b|\bperformSelector\b"
)
KEYCHAIN_HELPER_CALLS = {
    "alloc", "init", "pipe", "setLaunchPath", "setArguments", "setStandardOutput",
    "launch", "waitUntilExit", "terminationStatus", "fileHandleForReading",
    "readDataToEndOfFile", "initWithData", "encoding",
    "stringByTrimmingCharactersInSet", "whitespaceAndNewlineCharacterSet",
}
HELPER_CALLS = {
    "isValidSlackIdentifier": set(),
    "isValidSlackURL": {"isValidSlackIdentifier"},
    "tryAcquireJobcanLock": {"alloc", "initWithPath", "tryLock"},
    "releaseJobcanLock": {"unlock"},
    "jobcanLockPath": {"NSHomeDirectory"},
    "runSafeJobcanTouch": {
        "isValidSlackURL",
        "tryAcquireJobcanLock",
        "releaseJobcanLock",
        "performJobcanTouch",
    },
}
TEST_EFFECTS = '''
script TestEffects
    property callCount : 0
    property shouldRaise : false
    on performJobcanTouch(lockObject)
        set my callCount to my callCount + 1
        if my shouldRaise then error "synthetic failure" number 42
        return "performed"
    end performJobcanTouch
end script
'''


class JobcanTouchSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if platform.system() != "Darwin" or not OSASCRIPT.is_file():
            raise unittest.SkipTest("AppleScriptの実行にはmacOSが必要です")
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def handler_issues(self, name: str, handler: str) -> list[str]:
        executable_handler = self.executable_source(handler)
        issues = []
        if EXTERNAL_EFFECT.search(executable_handler):
            issues.append("外部操作または動的実行")
        body = executable_handler.split("\n", 1)[1]
        calls = set(re.findall(r"\b(?:my\s+)?([A-Za-z][A-Za-z0-9_]*)\s*\(", body))
        calls.update(re.findall(r"\bmy\s+([A-Za-z][A-Za-z0-9_]*)\b", body))
        calls.update(re.findall(r"\b([A-Za-z][A-Za-z0-9_]*)\s*:", body))
        calls.update(re.findall(r"\|([A-Za-z][A-Za-z0-9_]*)\|\s*\(", body))
        calls.difference_update({"return", "error", "if", "on", "end", "set"})
        unexpected = calls - HELPER_CALLS[name]
        if unexpected:
            issues.append("未許可呼出し: " + ",".join(sorted(unexpected)))
        return issues

    def executable_source(self, source: str) -> str:
        source = APPLE_SCRIPT_LITERALS.sub("", source)
        source = APPLE_SCRIPT_COMMENTS.sub("", source)
        return re.sub(r"¬[ \t]*\r?\n[ \t]*", " ", source)

    def raw_handler(self, name: str, signature: str) -> str:
        pattern = re.compile(
            rf"(?ms)^on {re.escape(signature)}\s*$.*?^end {re.escape(name)}\s*$"
        )
        match = pattern.search(self.source)
        self.assertIsNotNone(match, f"必要なAppleScriptハンドラーがありません: {name}")
        return match.group(0)

    def extract_handler(self, name: str, signature: str) -> str:
        handler = self.raw_handler(name, signature)
        self.assertFalse(
            self.handler_issues(name, handler),
            f"副作用・動的実行・未許可呼出しのある本番ハンドラーは検査実行しません: {name}",
        )
        return handler

    def keychain_helper_issues(self, handler: str) -> list[str]:
        executable = self.executable_source(handler)
        issues = []
        if KEYCHAIN_READ_ONLY_FORBIDDEN.search(executable):
            issues.append("Keychain前処理にUI・送信・clipboard・動的実行があります")
        body = executable.split("\n", 1)[1]
        calls = set(re.findall(r"\b(?:my\s+)?([A-Za-z][A-Za-z0-9_]*)\s*\(", body))
        calls.update(re.findall(r"\bmy\s+([A-Za-z][A-Za-z0-9_]*)\b", body))
        calls.update(re.findall(r"\b([A-Za-z][A-Za-z0-9_]*)\s*:", body))
        calls.update(re.findall(r"\|([A-Za-z][A-Za-z0-9_]*)\|\s*\(", body))
        calls.difference_update({"return", "error", "if", "on", "end", "set"})
        if calls - KEYCHAIN_HELPER_CALLS:
            issues.append("Keychain前処理に未許可呼出しがあります")
        selectors = re.sub(r"\|([A-Za-z][A-Za-z0-9_]*)\|", r"\1", executable)
        for selector, pattern in {
            "setLaunchPath": r"\bsetLaunchPath\s*:",
            "setArguments": r"\bsetArguments\s*:",
            "launch": r"\blaunch\s*\(",
        }.items():
            if len(re.findall(pattern, selectors, re.I)) != 1:
                issues.append(f"Keychain前処理の{selector}呼出しが1回ではありません")
        return issues

    def extract_run_entry(self) -> str:
        match = re.search(r"(?ms)^on run argv\s*$.*?^end run\s*$", self.source)
        self.assertIsNotNone(match, "本番のrun入口が見つかりません")
        return match.group(0)

    def run_entry_issues(self, entry: str) -> list[str]:
        executable_entry = self.executable_source(entry)
        issues = []
        if EXTERNAL_EFFECT.search(executable_entry):
            issues.append("入口内の直接操作または動的実行")
        body = executable_entry.split("\n", 1)[1].rsplit("\nend run", 1)[0]
        statements = [line.strip() for line in body.splitlines() if line.strip()]
        expected = (
            r"(?i)^set slackURL to my keychainSlackURL\(\)$",
            r"(?i)^set lockPath to my jobcanLockPath\(\)$",
            r"(?i)^return my runSafeJobcanTouch\(slackURL,\s*lockPath,\s*me\)$",
        )
        if len(statements) != len(expected):
            issues.append("入口文が安全な3文契約と一致しない")
        for statement, pattern in zip(statements, expected):
            if re.fullmatch(pattern, statement) is None:
                issues.append("入口に許可されていない文または呼出しがある")
                break
        return issues

    def run_entry_statements(self) -> list[str]:
        entry = self.extract_run_entry()
        issues = self.run_entry_issues(entry)
        self.assertFalse(
            issues,
            "本番run入口はKeychain取得と純粋なロックパス取得の後、安全ワークフローへscript receiverを渡すだけに限定してください",
        )
        body = entry.split("\n", 1)[1].rsplit("\nend run", 1)[0]
        return [line.strip() for line in body.splitlines() if line.strip()]

    def top_level_executable_statements(self, source: str) -> list[str]:
        source = self.executable_source(source)
        active_handler = None
        statements = []
        for line in source.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.lower().startswith("use "):
                continue
            if active_handler is None:
                start = re.match(r"(?i)^on\s+([A-Za-z][A-Za-z0-9_]*)\b", stripped)
                if start:
                    active_handler = start.group(1).lower()
                    continue
                statements.append(stripped)
                continue
            if line == line.lstrip():
                finish = re.fullmatch(r"(?i)end\s+([A-Za-z][A-Za-z0-9_]*)", stripped)
                if finish and finish.group(1).lower() == active_handler:
                    active_handler = None
        if active_handler is not None:
            statements.append("<unclosed handler>")
        return statements

    def key_code_statements(self, source: str) -> list[str]:
        key_source = self.executable_source(source)
        return [
            re.sub(r"\s+", " ", line.strip()).lower()
            for line in key_source.splitlines()
            if re.search(r"(?i)\bkey\s+code\b", line)
        ]

    def run_osascript(self, handlers: str, run_body: str, *arguments: str) -> str:
        self.assertIsNone(
            EXTERNAL_EFFECT.search(
                self.executable_source(handlers)
            ),
            "副作用を含む本番コードはosascriptで実行しません",
        )
        program = (
            'use framework "Foundation"\n'
            + handlers
            + TEST_EFFECTS
            + "\non run argv\n"
            + run_body
            + "\nend run\n"
        )
        with tempfile.TemporaryDirectory(prefix="hir318-osascript-") as directory:
            script_path = Path(directory) / "test.applescript"
            script_path.write_text(program, encoding="utf-8")
            completed = subprocess.run(
                [str(OSASCRIPT), "-l", "AppleScript", str(script_path), *arguments],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        self.assertEqual(
            completed.returncode,
            0,
            f"AppleScript検査に失敗しました: {completed.stderr.strip()}",
        )
        return completed.stdout.strip()

    def url_handlers(self) -> str:
        return "\n\n".join(
            (
                self.extract_handler(
                    "isValidSlackIdentifier", "isValidSlackIdentifier(candidateValue)"
                ),
                self.extract_handler("isValidSlackURL", "isValidSlackURL(candidateURL)"),
            )
        )

    def lock_handlers(self) -> str:
        acquire = self.extract_handler(
            "tryAcquireJobcanLock", "tryAcquireJobcanLock(lockPath)"
        )
        self.assertRegex(
            acquire,
            r"(?i)initWithPath:\s*\(?\s*\(?lockPath\b",
            "テスト用の一時パスを使わないロック取得処理は実行しません",
        )
        return "\n\n".join(
            (
                self.extract_handler("tryAcquireJobcanLock", "tryAcquireJobcanLock(lockPath)"),
                self.extract_handler("releaseJobcanLock", "releaseJobcanLock(lockObject)"),
            )
        )

    def safe_workflow_handlers(self) -> str:
        return "\n\n".join(
            (
                self.url_handlers(),
                self.lock_handlers(),
                self.extract_handler(
                    "runSafeJobcanTouch",
                    "runSafeJobcanTouch(candidateURL, lockPath, effects)",
                ),
            )
        )

    def test_existing_raycast_keychain_and_send_order_are_preserved(self) -> None:
        self.assertIn("# @raycast.schemaVersion 1", self.source)
        self.assertIn("# @raycast.title Jobcan touch", self.source)
        self.assertIn("# @raycast.mode silent", self.source)
        self.assertRegex(self.source, r"(?i)on keychainSlackURL\(\)")
        self.assertIn("find-generic-password", self.source)
        expected_key_events = [
            "key code 36",
            "key code 36 using {command down}",
        ]
        key_events = self.key_code_statements(self.source)
        self.assertEqual(
            key_events,
            expected_key_events,
            "コメントを除いた実行可能なキー操作は無修飾ReturnとCommand-Returnの2件だけである必要があります",
        )
        self.assertEqual(
            self.key_code_statements(
                self.source + "\nkey code 36 using {option down} -- extra\n"
            ),
            expected_key_events + ["key code 36 using {option down}"],
            "行末コメント付きの追加キー操作を実行可能な命令として列挙できません",
        )

    def test_keychain_preflight_is_confined_to_read_only_lookup(self) -> None:
        handler = self.raw_handler("keychainSlackURL", "keychainSlackURL()")
        self.assertFalse(
            self.keychain_helper_issues(handler),
            "送信前のKeychain取得処理は読取専用の許可済み呼出しだけにしてください",
        )
        launch_paths = re.findall(r'(?im)\bsetLaunchPath:\s*"([^"]+)"', handler)
        self.assertEqual(len(launch_paths), 1)
        self.assertEqual(Path(launch_paths[0]).as_posix(), "/usr/bin/security")
        arguments_match = re.search(r"(?is)setArguments:\s*\{([^}]*)\}", handler)
        self.assertIsNotNone(arguments_match, "Keychain読取引数が見つかりません")
        arguments = re.fullmatch(
            r'(?is)\s*"find-generic-password"\s*,\s*"-s"\s*,\s*"([^"]+)"'
            r'\s*,\s*"-a"\s*,\s*"([^"]+)"\s*,\s*"-w"\s*',
            arguments_match.group(1),
        )
        self.assertIsNotNone(
            arguments,
            "Keychainコマンドは追加引数なしの汎用パスワード読取形式だけを使ってください",
        )

    def test_safety_scanner_rejects_unsafe_keychain_handler(self) -> None:
        unsafe = (
            "on keychainSlackURL()\n"
            "    tell application \"Slack\" to activate\n"
            "    return \"\"\nend keychainSlackURL"
        )
        self.assertTrue(self.keychain_helper_issues(unsafe))
        destructive_arguments = (
            "on keychainSlackURL()\n"
            '    process\'s setLaunchPath:"/usr/bin/security"\n'
            '    process\'s setArguments:{"find-generic-password", "-s", '
            '"synthetic-service", "-a", "synthetic-account", "-w"}\n'
            '    process\'s setArguments:{"delete-generic-password", "-s", '
            '"synthetic-service", "-a", "synthetic-account"}\n'
            "    process's |launch|()\n"
            "end keychainSlackURL"
        )
        self.assertTrue(
            self.keychain_helper_issues(destructive_arguments),
            "2回目のKeychain引数設定を安全な読取専用処理として許容しました",
        )

    def test_synthetic_slack_url_inputs(self) -> None:
        cases = (
            ("slack://channel?team=T123&id=D456", True),
            ("", False),
            ("https://channel?team=T123&id=D456", False),
            ("slack://channel?team=&id=D456", False),
            ("slack://channel?team=T123&id=", False),
            ("slack://channel?team=T123", False),
            ("slack://channel?id=D456", False),
            ("slack://channel?team=T123&id=D456&extra=x", False),
            ("slack://channel?team=T 123&id=D456", False),
            ("slack://channel?id=D456&team=T123", False),
        )
        statements = []
        for index, (url, expected) in enumerate(cases, start=1):
            result = "true" if expected else "false"
            statements.append(
                f'if (my isValidSlackURL("{url}")) is not {result} then '
                f'error "URL case {index} failed" number 1'
            )
        body = "\n".join(statements) + '\nreturn "PASS"'
        self.assertEqual(self.run_osascript(self.url_handlers(), body), "PASS")

    def test_run_entry_delegates_before_any_external_effect(self) -> None:
        self.run_entry_statements()
        self.assertEqual(
            self.top_level_executable_statements(self.source),
            [],
            "実行入口の外にトップレベル操作を置けません",
        )

    def test_safety_scanner_rejects_dynamic_execution_and_unapproved_selectors(self) -> None:
        unsafe_handlers = (
            "on runSafeJobcanTouch(candidateURL, lockPath, effects)\n"
            "    run script candidateURL\nend runSafeJobcanTouch",
            "on runSafeJobcanTouch(candidateURL, lockPath, effects)\n"
            "    run ¬\n        script candidateURL\nend runSafeJobcanTouch",
            "on runSafeJobcanTouch(candidateURL, lockPath, effects)\n"
            "    set resultValue to current application's NSAppleScript's alloc()'s "
            "executeAndReturnError:errorValue\nend runSafeJobcanTouch",
            "on runSafeJobcanTouch(candidateURL, lockPath, effects)\n"
            "    my unapprovedPreparation\nend runSafeJobcanTouch",
            "on runSafeJobcanTouch(candidateURL, lockPath, effects)\n"
            "    current application's NSFileManager's |unapprovedSelector|()\n"
            "end runSafeJobcanTouch",
        )
        for handler in unsafe_handlers:
            with self.subTest(handler=handler.splitlines()[1].strip()):
                self.assertTrue(
                    self.handler_issues("runSafeJobcanTouch", handler),
                    "副作用・動的実行または未許可呼出しが実行前検査を通過しました",
                )

    def test_run_entry_rejects_effect_factory_before_guards(self) -> None:
        unsafe_entry = """on run argv
set slackURL to my keychainSlackURL()
set lockPath to my jobcanLockPath()
set effects to my jobcanTouchEffects()
return my runSafeJobcanTouch(slackURL, lockPath, effects)
end run"""
        self.assertTrue(
            self.run_entry_issues(unsafe_entry),
            "URL・排他ガード前の効果オブジェクト生成を許容しました",
        )

    def test_lock_path_handler_has_no_external_effect(self) -> None:
        handler = self.extract_handler("jobcanLockPath", "jobcanLockPath()")
        body = 'set lockPath to my jobcanLockPath()\nif lockPath is "" then error "missing path" number 1\nreturn "PASS"'
        self.assertEqual(self.run_osascript(handler, body), "PASS")

    def test_entry_rejects_invalid_url_and_lock_conflict_before_effects(self) -> None:
        handlers = self.safe_workflow_handlers()
        with tempfile.TemporaryDirectory(prefix="hir318-entry-") as directory:
            lock_path = str(Path(directory) / "send.lock")
            body = '''
set TestEffects's callCount to 0
set invalidResult to my runSafeJobcanTouch("slack://channel?team=&id=D456", item 1 of argv, TestEffects)
if invalidResult is not "blocked_invalid_url" then error "invalid URL was not stopped" number 1
if TestEffects's callCount is not 0 then error "invalid URL reached external effects" number 1
set fileManager to current application's NSFileManager's defaultManager()
if fileManager's fileExistsAtPath:(item 1 of argv) then error "invalid URL touched the lock path" number 1
set heldLock to my tryAcquireJobcanLock(item 1 of argv)
if heldLock is missing value then error "fixture lock acquisition failed" number 1
set duplicateResult to my runSafeJobcanTouch("slack://channel?team=T123&id=D456", item 1 of argv, TestEffects)
if duplicateResult is not "blocked_duplicate" then error "competing run was not stopped" number 1
if TestEffects's callCount is not 0 then error "competing run reached external effects" number 1
my releaseJobcanLock(heldLock)
return "PASS"
'''
            self.assertEqual(self.run_osascript(handlers, body, lock_path), "PASS")

    def test_caught_operation_error_releases_lock(self) -> None:
        handlers = self.safe_workflow_handlers()
        with tempfile.TemporaryDirectory(prefix="hir318-error-lock-") as directory:
            lock_path = str(Path(directory) / "send.lock")
            body = '''
set TestEffects's callCount to 0
set TestEffects's shouldRaise to true
set resultValue to my runSafeJobcanTouch("slack://channel?team=T123&id=D456", item 1 of argv, TestEffects)
if resultValue is not "operation_failed" then error "synthetic failure was not handled" number 1
if TestEffects's callCount is not 1 then error "synthetic operation was not called once" number 1
set reacquiredLock to my tryAcquireJobcanLock(item 1 of argv)
if reacquiredLock is missing value then error "caught error left the lock held" number 1
my releaseJobcanLock(reacquiredLock)
return "PASS"
'''
            self.assertEqual(self.run_osascript(handlers, body, lock_path), "PASS")

    def test_lock_is_exclusive_and_releases_after_normal_exit(self) -> None:
        handlers = self.lock_handlers()
        with tempfile.TemporaryDirectory(prefix="hir318-lock-") as directory:
            lock_path = str(Path(directory) / "send.lock")
            body = '''
set firstLock to my tryAcquireJobcanLock(item 1 of argv)
if firstLock is missing value then error "first acquisition failed" number 1
set secondLock to my tryAcquireJobcanLock(item 1 of argv)
if secondLock is not missing value then
    my releaseJobcanLock(secondLock)
    error "competing acquisition succeeded" number 1
end if
my releaseJobcanLock(firstLock)
set thirdLock to my tryAcquireJobcanLock(item 1 of argv)
if thirdLock is missing value then error "normal release did not unlock" number 1
my releaseJobcanLock(thirdLock)
return "PASS"
'''
            self.assertEqual(self.run_osascript(handlers, body, lock_path), "PASS")

    def test_abnormal_exit_requires_explicit_manual_recovery(self) -> None:
        handlers = self.lock_handlers()
        with tempfile.TemporaryDirectory(prefix="hir318-crash-lock-") as directory:
            lock_path = Path(directory) / "send.lock"
            ready_path = Path(directory) / "locked"
            child_body = '''
set lockObject to my tryAcquireJobcanLock(item 1 of argv)
if lockObject is missing value then error "child acquisition failed" number 1
set signalText to current application's NSString's stringWithString:"ready"
set signalData to signalText's dataUsingEncoding:(current application's NSUTF8StringEncoding)
current application's NSFileManager's defaultManager()'s createFileAtPath:(item 2 of argv) contents:signalData attributes:(missing value)
delay 30
return "finished"
'''
            child_program = (
                'use framework "Foundation"\n'
                + handlers
                + "\non run argv\n"
                + child_body
                + "\nend run\n"
            )
            child_script = Path(directory) / "child.applescript"
            child_script.write_text(child_program, encoding="utf-8")
            child = subprocess.Popen(
                [str(OSASCRIPT), "-l", "AppleScript", str(child_script), str(lock_path), str(ready_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            def try_acquire() -> str:
                body = '''
set lockObject to my tryAcquireJobcanLock(item 1 of argv)
if lockObject is missing value then return "BLOCKED"
my releaseJobcanLock(lockObject)
return "ACQUIRED"
'''
                return self.run_osascript(handlers, body, str(lock_path))

            try:
                deadline = time.monotonic() + 10
                while not ready_path.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if child.poll() is not None:
                    _, stderr = child.communicate(timeout=2)
                    self.fail(
                        "異常終了検査用の子プロセスがロックを保持できませんでした: "
                        + stderr.strip()
                    )
                self.assertTrue(ready_path.exists(), "子プロセスがロック取得を通知しませんでした")
                self.assertEqual(try_acquire(), "BLOCKED", "実行中の排他が機能しません")
                child.kill()
                child.wait(timeout=8)
                self.assertEqual(
                    try_acquire(),
                    "BLOCKED",
                    "異常終了したロックを自動で解除しました。手動復旧が必要です",
                )
                lock_path.unlink(missing_ok=True)
                self.assertEqual(
                    try_acquire(),
                    "ACQUIRED",
                    "一時ディレクトリ内のロックを手動削除しても復旧できません",
                )
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=8)


if __name__ == "__main__":
    unittest.main()
