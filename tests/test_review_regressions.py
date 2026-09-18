"""Local regression checks; no Docker daemon, SSH, or production data needed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReviewRegressions(unittest.TestCase):
    def test_failed_deploy_persists_previous_image_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            (root / 'docker-compose.yml').write_text('services: {}\n')
            (root / '.env').write_text('AUTH_SERVER_IMAGE=ghcr.io/bngdrasil/bidar:main\nOTHER=keep\n')
            commands = {
                'flock': 'exit 0',
                'curl': 'exit 1',
                'docker': '''case "$*" in
  "inspect --type container --format {{.Image}} "*) echo old-image-id ;;
  "inspect --type container --format {{.Config.Image}} "*) echo ghcr.io/bngdrasil/bidar:main ;;
  "image inspect "*) echo ghcr.io/bngdrasil/bidar@sha256:fake ;;
  "compose "*) grep '^AUTH_SERVER_IMAGE=' "$DEPLOY_DIR/.env" >> "$DEPLOY_DIR/observed" ;;
esac
exit 0''',
            }
            for name, code in commands.items():
                p = bin_dir / name
                p.write_text('#!/bin/sh\n' + code + '\n')
                p.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                       DEPLOY_DIR=tmp, HEALTH_RETRIES='1', HEALTH_INTERVAL='0')
            result = subprocess.run(['bash', str(ROOT / 'vm2-deployment/deploy-image.sh'),
                                     'auth-server', 'ghcr.io/bngdrasil/bidar:main'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            observed = (root / 'observed').read_text().splitlines()
            self.assertEqual(len(observed), 2)
            self.assertTrue(observed[1].startswith('AUTH_SERVER_IMAGE=rollback/vm2-auth:'), observed)
            self.assertIn('OTHER=keep', (root / '.env').read_text())

    def test_ship_dry_run_does_not_record_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            for name in ['age', 'rsync']:
                p = bin_dir / name
                p.write_text('#!/bin/sh\nexit 99\n')
                p.chmod(0o755)
            key = root / 'recipients'
            key.write_text('test-placeholder-not-a-real-recipient\n')
            key.chmod(0o600)
            state = root / 'state'
            state.mkdir()
            previous = state / 'ship-last-success.json'
            previous.write_text('{"finished_epoch": 123}\n')
            run = root / 'postgresql/20260101T000000Z'
            run.mkdir(parents=True)
            (run / 'SUCCESS').touch()
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                       BK_ENV_FILE=str(root / 'absent-env'), BK_SECRET_DIR=tmp,
                       BACKUP_ROOT=tmp, STATE_DIR=str(state), LOCK_DIR=str(root / 'locks'),
                       METRICS_DIR=str(root / 'metrics'), AGE_RECIPIENTS_FILE=str(key),
                       SHIP_ENCRYPTION='age', SHIP_SSH_DIR=str(root / 'ssh'),
                       SHIP_OUTBOUND_DIR=str(root / 'outbound'), METRICS_ENABLED='1')
            result = subprocess.run(['bash', str(ROOT / 'backup/ship.sh'), '--dry-run'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(previous.read_text(), '{"finished_epoch": 123}\n')
            self.assertFalse((state / 'ship-last-run.json').exists())
            self.assertFalse((root / 'metrics/bngdrasil-backup-ship.prom').exists())
            self.assertFalse((run / 'SHIPPED').exists())


if __name__ == '__main__':
    unittest.main()
