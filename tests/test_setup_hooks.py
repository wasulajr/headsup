"""Execute setup's real hook-wiring step only, in disposable settings fixtures."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / "setup.sh").read_text()
STEP = SETUP[SETUP.index('header "Step 9/9'):SETUP.index('# Allow rules so the headsup skills')]


class HookWiringTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / "settings.json"

    def run_step(self, approve=True):
        harness = '''set -eu
SCRIPT_DIR="$1"; SETTINGS="$2"
header(){ :; }; ok(){ :; }; note(){ :; }; warn(){ :; }
fatal(){ echo "$*" >&2; exit 1; }
confirm(){ return ''' + ("0" if approve else "1") + "; }\n" + STEP
        return subprocess.run(["bash", "-c", harness, "test", str(ROOT), str(self.settings)],
                              text=True, capture_output=True)

    def write(self, settings):
        self.settings.write_text(json.dumps(settings))

    def read(self):
        return json.loads(self.settings.read_text())

    def test_preserves_all_existing_hooks_and_settings_idempotently(self):
        guard = {"matcher": "Bash", "hooks": [{"type": "command", "command": "deploy-guard.sh", "timeout": 60}]}
        memory = {"hooks": [{"type": "command", "command": "memory-reindex.sh"}]}
        original = {"permissions": {"deny": ["Bash(rm:*)"]}, "env": {"KEEP": "yes"},
                    "hooks": {"PreToolUse": [guard, guard], "SessionStart": [memory],
                              "CustomEvent": [memory]}}
        self.write(original)
        self.settings.chmod(0o600)
        self.assertEqual(self.run_step().returncode, 0)
        result = self.read()
        for key in ("permissions", "env"):
            self.assertEqual(result[key], original[key])
        for event, entries in original["hooks"].items():
            self.assertEqual(result["hooks"][event][:len(entries)], entries)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(Path(str(self.settings) + ".bak").read_text()), original)
        before = self.settings.read_bytes()
        self.assertEqual(self.run_step().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(json.loads(Path(str(self.settings) + ".bak").read_text()), original)

    def test_repairs_partial_install_and_preserves_matcher_variants(self):
        self.assertEqual(self.run_step().returncode, 0)
        canonical = self.read()["hooks"]
        variant = dict(canonical["PreToolUse"][0], matcher="Bash", timeout=99)
        self.write({"hooks": {"SessionStart": canonical["SessionStart"], "PreToolUse": [variant]}})
        self.assertEqual(self.run_step().returncode, 0)
        result = self.read()["hooks"]
        self.assertEqual(len(result["SessionStart"]), 1)
        self.assertEqual(result["PreToolUse"], [variant] + canonical["PreToolUse"])
        self.assertEqual(set(result), set(canonical))
        self.assertEqual(self.run_step().returncode, 0)
        self.assertEqual(self.read()["hooks"], result)

    def test_existing_registration_at_later_index_is_not_duplicated(self):
        self.assertEqual(self.run_step().returncode, 0)
        settings = self.read()
        extra = {"hooks": [{"type": "command", "command": "mail-inject.sh"}]}
        for entries in settings["hooks"].values():
            entries.insert(0, extra)
        self.write(settings)
        self.assertEqual(self.run_step().returncode, 0)
        self.assertEqual(self.read(), settings)

    def test_empty_and_missing_hooks(self):
        for settings in ({}, {"permissions": {"allow": []}}, {"hooks": {}}):
            with self.subTest(settings=settings):
                self.write(settings)
                self.assertEqual(self.run_step().returncode, 0)
                self.assertEqual(len(self.read()["hooks"]), 6)

    def test_invalid_settings_fail_without_changing_original_or_backup(self):
        for raw in ('{', '', '{} {}', '[]', 'null', '{"hooks":null}',
                    '{"hooks":[]}', '{"hooks":{"Stop":{}}}', '{"hooks":{"Stop":[null]}}'):
            with self.subTest(raw=raw):
                self.settings.write_text(raw)
                backup = Path(str(self.settings) + ".bak")
                backup.write_text("existing backup")
                result = self.run_step()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("original settings left unchanged", result.stderr)
                self.assertEqual(self.settings.read_text(), raw)
                self.assertEqual(backup.read_text(), "existing backup")
                self.assertEqual(list(self.settings.parent.glob("*.hooks.*")), [])

    def test_declining_leaves_settings_untouched(self):
        self.write({"env": {"KEEP": "yes"}})
        before = self.settings.read_bytes()
        self.assertEqual(self.run_step(approve=False).returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(Path(str(self.settings) + ".bak").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
