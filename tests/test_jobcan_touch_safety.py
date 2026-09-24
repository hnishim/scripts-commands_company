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


class JobcanTouchSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if platform.system() != "Darwin" or not OSASCRIPT.is_file():
            raise unittest.SkipTest("AppleScriptの実行にはmacOSが必要です")
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def extract_handler(self, name: str, signature: str) -> str:
        pattern = re.compile(
            rf"(?ms)^on {re.escape(signature)}\s*$.*?^end {re.escape(name)}\s*$"
        )
        match = pattern.search(self.source)
        self.assertIsNotNone(match, f"必要なAppleScriptハンドラーがありません: {name}")
        return match.group(0)

    def run_osascript(self, handlers: str, run_body: str, *arguments: str) -> str:
        program = (
            'use framework "Foundation"\n'
            + handlers
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
        return "\n\n".join(
            (
                self.extract_handler(
                    "tryAcquireJobcanLock", "tryAcquireJobcanLock(lockPath)"
                ),
                self.extract_handler("releaseJobcanLock", "releaseJobcanLock(lockObject)"),
            )
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

    def test_invalid_url_guard_precedes_slack_and_clipboard_actions(self) -> None:
        guard = re.search(
            r"(?i)if\s+not\s+isValidSlackURL\(slackURL\)\s+then\s+return",
            self.source,
        )
        self.assertIsNotNone(guard, "送信先URLの検証後に停止する境界がありません")
        side_effects = list(
            re.finditer(
                r'(?i)tell\s+application\s+"Slack"|open\s+location|openURL\s*:|'
                r"set\s+the\s+clipboard|keystroke|key\s+code",
                self.source,
            )
        )
        self.assertTrue(side_effects, "Slack操作・クリップボード操作が見つかりません")
        self.assertLess(
            guard.start(),
            min(effect.start() for effect in side_effects),
            "不正URLを拒否する前にSlackまたはクリップボードを操作します",
        )

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

    def test_abnormal_exit_does_not_auto_break_stale_lock(self) -> None:
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
                child.terminate()
                child.wait(timeout=8)
                self.assertEqual(
                    try_acquire(),
                    "BLOCKED",
                    "異常終了したロックを自動で解除しました。復旧は明示操作が必要です",
                )
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=8)


if __name__ == "__main__":
    unittest.main()
