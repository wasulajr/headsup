"""Execute the installer's actual hook-copy block, then run its installed hook."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CodexUtilizationInstall(unittest.TestCase):
    def test_fresh_install_contains_import_dependency_and_runs_incrementally(self):
        installer = (ROOT / 'setup-codex.sh').read_text()
        start = installer.index("printf '%s\\n' \"$SCRIPT_DIR\" > \"$HOOK_DIR/.headsup-repo\"")
        end = installer.index('header "Step 4/7', start)
        copy_block = installer[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'codex'
            hooks = target / 'hooks'
            hooks.mkdir(parents=True)
            env = {**os.environ, 'SCRIPT_DIR': str(ROOT), 'HOOK_DIR': str(hooks),
                   'CODEX_HOME': str(target), 'HEADSUP_CODEX_STATE_ROOT': str(Path(tmp) / 'state')}
            shell = 'set -eu\nDIM=""; RST=""\nok(){ :; }\nfatal(){ echo "$*" >&2; exit 1; }\n' + copy_block
            subprocess.run(['bash', '-c', shell], env=env, check=True, capture_output=True)
            self.assertTrue((hooks / 'headsup-codex-transcript.mjs').is_file())
            self.assertEqual((hooks / 'headsup-codex-utilization.mjs').read_bytes(),
                             (ROOT / 'hooks/headsup-codex-utilization.mjs').read_bytes())
            sid = '11111111-1111-1111-1111-111111111111'
            transcript = Path(tmp) / 'fixture.jsonl'
            transcript.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': sid}}) + '\n'
                + json.dumps({'type': 'event_msg', 'payload': {'type': 'token_count',
                    'info': {'total_token_usage': {'total_tokens': 123}}}}) + '\n')
            payload = json.dumps({'session_id': sid, 'transcript_path': str(transcript)})
            for _ in range(2):
                subprocess.run(['node', str(hooks / 'headsup-codex-utilization.mjs'), 'PreToolUse'],
                               env=env, input=payload, text=True, capture_output=True, check=True, timeout=5)
            snapshot = next((Path(tmp) / 'state/.state/util').glob('*.json'))
            data = json.loads(snapshot.read_text())
            self.assertEqual(data['sessionId'], sid)
            self.assertEqual(data['usage']['total_token_usage']['total_tokens'], 123)
            self.assertEqual(data['transcriptRead']['bytes'], 0)


if __name__ == '__main__':
    unittest.main()
