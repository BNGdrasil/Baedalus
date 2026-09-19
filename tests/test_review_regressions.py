"""Local regression checks; no Docker daemon, SSH, or production data needed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
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
            # 사전 점검이 읽는 compose config 대역 출력이다. 빈 값이 없는 상태로 둔다.
            (root / 'config-output').write_text(
                'name: bnbong\nservices:\n  auth-server:\n    environment:\n'
                '      ENVIRONMENT: production\n      LOG_LEVEL: INFO\n')
            commands = {
                'flock': 'exit 0',
                # 새 image는 응답하지 않고 롤백본만 응답하게 만든다.
                'curl': 'grep -q "^AUTH_SERVER_IMAGE=rollback/" "$DEPLOY_DIR/.env" && exit 0\nexit 1',
                'docker': '''case "$*" in
  *" config "*) cat "$DEPLOY_DIR/config-output" ;;
  "inspect --type container --format {{.Image}} "*) echo old-image-id ;;
  "inspect --type container --format {{.Config.Image}} "*) echo ghcr.io/bngdrasil/bidar:main ;;
  "inspect --type container --format {{json .State}} "*) echo '{"Status":"restarting"}' ;;
  "image inspect "*) echo ghcr.io/bngdrasil/bidar@sha256:fake ;;
  "logs "*) echo "container log line" ;;
  *" up "*) grep '^AUTH_SERVER_IMAGE=' "$DEPLOY_DIR/.env" >> "$DEPLOY_DIR/observed" ;;
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


class DeployImageOutage20260919(unittest.TestCase):
    """2026-09-19 게이트웨이 중단의 재발 방지 검사.

    Docker와 curl을 대역으로 바꾸어 실행하므로 Docker 데몬과 운영 VM이 필요하지 않다.
    """

    SCRIPT = ROOT / 'vm2-deployment/deploy-image.sh'

    DOCKER_STUB = r'''case "$*" in
  *" config "*) cat "$DEPLOY_DIR/config-output" ;;
  "inspect --type container --format {{.Image}} "*) echo old-image-id ;;
  "inspect --type container --format {{.Config.Image}} "*) echo ghcr.io/bngdrasil/bifrost:main ;;
  "inspect --type container --format {{json .State}} "*) echo '{"Status":"restarting","ExitCode":1}' ;;
  "image inspect "*) echo ghcr.io/bngdrasil/bifrost@sha256:fake ;;
  "logs "*) echo "ValidationError: bool_parsing, input_value=" ;;
  *" up "*) echo "$*" >> "$DEPLOY_DIR/observed-up" ;;
esac
exit 0'''

    # 롤백본만 응답하게 만드는 curl 대역이다. 새 image가 떠 있는 동안에는 실패한다.
    CURL_ROLLBACK_ONLY = r'''grep -q "^GATEWAY_IMAGE=rollback/" "$DEPLOY_DIR/.env" && exit 0
exit 1'''

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.root / 'docker-compose.yml').write_text('services: {}\n')
        (self.root / '.env').write_text(
            'GATEWAY_IMAGE=ghcr.io/bngdrasil/bifrost:main\nOTHER=keep\n')
        self.stub('flock', 'exit 0')
        self.stub('docker', self.DOCKER_STUB)
        self.addCleanup(self._tmp.cleanup)

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def write_config(self, empty_keys=()):
        """compose config 대역 출력을 만든다. empty_keys에 적은 항목만 빈 문자열이 된다."""
        lines = ['name: bnbong', 'services:', '  gateway:', '    environment:',
                 '      ENVIRONMENT: production', '      LOG_LEVEL: INFO']
        for key in empty_keys:
            lines.append('      %s: ""' % key)
        lines += ['    image: ghcr.io/bngdrasil/bifrost:main', 'networks:',
                  '  api-network:', '    name: api-network']
        (self.root / 'config-output').write_text('\n'.join(lines) + '\n')

    def run_deploy(self):
        env = dict(os.environ,
                   PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   DEPLOY_DIR=str(self.root), HEALTH_RETRIES='1', HEALTH_INTERVAL='0')
        return subprocess.run(
            ['bash', str(self.SCRIPT), 'gateway', 'ghcr.io/bngdrasil/bifrost:sha-1a2b3c4'],
            env=env, capture_output=True, text=True, timeout=30)

    def failure_logs(self):
        d = self.root / 'deploy-failures'
        return sorted(d.glob('*-gateway.log')) if d.exists() else []

    # --- (a) 빈 env 값이 있으면 컨테이너를 교체하지 않고 중단한다 --------------------
    def test_empty_environment_value_aborts_before_replacing_container(self):
        self.write_config(empty_keys=['ENABLE_METRICS', 'MAX_REQUEST_BODY_BYTES'])
        self.stub('curl', 'exit 0')

        result = self.run_deploy()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('ENABLE_METRICS', result.stderr)
        self.assertIn('MAX_REQUEST_BODY_BYTES', result.stderr)
        # 컨테이너 교체가 일어나지 않아야 하고 .env도 그대로 남아 있어야 한다.
        self.assertFalse((self.root / 'observed-up').exists(), result.stdout)
        self.assertIn('GATEWAY_IMAGE=ghcr.io/bngdrasil/bifrost:main',
                      (self.root / '.env').read_text())

    # --- (b) health 실패는 되돌리기 전에 실패 기록을 남긴다 -------------------------
    def test_health_failure_writes_failure_log_before_rollback(self):
        self.write_config()
        self.stub('curl', self.CURL_ROLLBACK_ONLY)

        result = self.run_deploy()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        logs = self.failure_logs()
        self.assertEqual(len(logs), 1, result.stdout + result.stderr)
        body = logs[0].read_text()
        self.assertIn('phase   : new-image', body)
        self.assertIn('bool_parsing', body)
        self.assertIn('"Status":"restarting"', body)
        # 롤백본이 health 확인을 통과했으므로 중단 경고는 나오지 않는다.
        self.assertNotIn('서비스 중단 상태다', result.stderr)

    # --- (c) 롤백본까지 health에 실패하면 종료 코드 3으로 알린다 ---------------------
    def test_failed_rollback_reports_outage_with_exit_code_three(self):
        self.write_config()
        self.stub('curl', 'exit 1')

        result = self.run_deploy()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn('서비스 중단 상태다', result.stderr)
        body = ''.join(f.read_text() for f in self.failure_logs())
        self.assertIn('phase   : new-image', body)
        self.assertIn('phase   : rollback', body)


class BackupRetentionAndShip(unittest.TestCase):
    """R2: 보존 정책과 전송과 잠금이 서로 맞물려 동작하는지 확인한다."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.metrics = self.root / 'metrics'
        self.notify_log = self.root / 'notify.log'
        self.notify = self.bin / 'notify-stub.sh'
        self.notify.write_text('#!/bin/sh\nprintf "%s|%s|%s\\n" "$1" "$2" "$3" >> "$NOTIFY_LOG"\n')
        self.notify.chmod(0o755)
        self.recipients = self.root / 'recipients'
        self.recipients.write_text('test-placeholder-not-a-real-recipient\n')
        self.recipients.chmod(0o600)
        self.addCleanup(self._tmp.cleanup)

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def env(self, **extra):
        base = dict(
            os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            BK_ENV_FILE=str(self.root / 'absent-env'),
            BK_SECRET_DIR=str(self.root),
            BACKUP_ROOT=str(self.root),
            STATE_DIR=str(self.state),
            LOCK_DIR=str(self.root / 'locks'),
            BK_LOCK_FILE=str(self.state / 'backup.lock'),
            BK_LOCK_WAIT_SEC='0',
            METRICS_DIR=str(self.metrics),
            METRICS_ENABLED='1',
            NOTIFY_SCRIPT=str(self.notify),
            NOTIFY_LOG=str(self.notify_log),
            AGE_RECIPIENTS_FILE=str(self.recipients),
            SHIP_ENCRYPTION='age',
            SHIP_SSH_DIR=str(self.root / 'ssh'),
            SHIP_OUTBOUND_DIR=str(self.root / 'outbound'),
        )
        base.pop('BK_LOCK_HELD', None)
        base.update(extra)
        return base

    def make_runs(self, run_ids, shipped=False, group='postgresql'):
        made = []
        for run_id in run_ids:
            d = self.root / group / run_id
            d.mkdir(parents=True)
            (d / 'SUCCESS').touch()
            (d / 'postgresql-bngdrasil.dump').write_text('dummy dump ' + run_id + '\n')
            if shipped:
                (d / 'SHIPPED').touch()
            made.append(d)
        return made

    def run_script(self, name, *args, **env_extra):
        return subprocess.run(['bash', str(ROOT / 'backup' / name), *args],
                              env=self.env(**env_extra), capture_output=True,
                              text=True, timeout=60)

    # --- 1. 미전송 성공본은 dry-run 에서도 실제 실행에서도 삭제되지 않는다 ------------
    def test_unshipped_successes_are_never_deleted(self):
        runs = self.make_runs(['20260101T001000Z', '20260101T061000Z', '20260101T121000Z'])

        dry = self.run_script('retention.sh', '--dry-run')
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertNotIn('삭제 예정', dry.stdout)

        real = self.run_script('retention.sh')
        self.assertEqual(real.returncode, 0, real.stdout + real.stderr)
        self.assertNotIn('삭제:', real.stdout)
        for d in runs:
            self.assertTrue(d.exists(), d)
        self.assertEqual(self.notify_log.exists(), False)

        metric = (self.metrics / 'bngdrasil-backup-unshipped.prom').read_text()
        self.assertIn('bngdrasil_backup_unshipped_total{component="postgresql"} 3', metric)

    # --- 1-b. SHIPPED 표시를 붙이면 세대 정책대로 정리된다 ---------------------------
    def test_shipped_successes_follow_generation_policy(self):
        runs = self.make_runs(['20260101T001000Z', '20260101T061000Z', '20260101T121000Z'],
                              shipped=True)
        result = self.run_script('retention.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(runs[2].exists(), '같은 날의 가장 최근 성공본은 남아야 한다')
        self.assertFalse(runs[0].exists(), result.stdout)
        self.assertFalse(runs[1].exists(), result.stdout)

    # --- 1-c. 전송을 쓰지 않는 호스트에서는 SHIPPED 를 요구하지 않는다 -----------------
    def test_retention_without_shipping_still_cleans_up(self):
        runs = self.make_runs(['20260101T001000Z', '20260101T061000Z', '20260101T121000Z'])
        result = self.run_script('retention.sh', SHIP_ENABLED='false')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(runs[2].exists())
        self.assertFalse(runs[0].exists())

    # --- 2. 미전송이 허용치를 넘으면 삭제하지 않은 채 실패로 드러낸다 -------------------
    def test_unshipped_pileup_fails_and_notifies(self):
        runs = self.make_runs(['2026010%dT001000Z' % i for i in range(1, 10)])
        result = self.run_script('retention.sh', RETENTION_MAX_UNSHIPPED='8')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for d in runs:
            self.assertTrue(d.exists(), d)
        self.assertTrue(self.notify_log.exists(), result.stdout + result.stderr)
        logged = self.notify_log.read_text()
        self.assertIn('warning|retention|', logged)
        self.assertIn('허용치', logged)

    # --- 3. 전송 실패는 run.sh 전체 결과에 반영되고 로컬 성공본은 남는다 ---------------
    def test_ship_failure_surfaces_in_run_and_retry_path_recovers(self):
        run_dir = self.make_runs(['20260101T001000Z'])[0]
        self.stub('age', 'exec cat')
        self.stub('rsync', 'exit 1')
        self.stub('ssh', 'exit 0')

        failed = self.run_script('run.sh', RUN_POSTGRESQL='false', REDIS_TARGETS='',
                                 SQLITE_TARGETS='', RUN_NOTIFY='0', SHIP_ENABLED='true')
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        last_run = (self.state / 'last-run.json').read_text()
        self.assertIn('"failed_steps": "ship"', last_run)
        self.assertIn('"status": "failed"', last_run)
        self.assertTrue((run_dir / 'SUCCESS').exists())
        self.assertFalse((run_dir / 'SHIPPED').exists())
        self.assertFalse((run_dir / 'SHIPPING').exists())
        self.assertEqual(list((self.root / 'outbound').glob('*')), [])

        # 재시도 timer 가 실행하는 경로. 미전송분만 다시 보낸다.
        self.stub('rsync', 'exit 0')
        retry = self.run_script('ship.sh')
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertTrue((run_dir / 'SHIPPED').exists())
        self.assertFalse((run_dir / 'SHIPPING').exists())
        self.assertIn('성공 1건', retry.stdout)
        metric = (self.metrics / 'bngdrasil-backup-unshipped.prom').read_text()
        self.assertIn('bngdrasil_backup_unshipped_total{component="postgresql"} 0', metric)

    # --- 3-b. 원격 검증에 실패하면 SHIPPED 표시를 남기지 않는다 ----------------------
    def test_remote_verification_failure_blocks_shipped_marker(self):
        run_dir = self.make_runs(['20260101T001000Z'])[0]
        self.stub('age', 'exec cat')
        self.stub('rsync', 'exit 0')
        # 첫 번째 호출(원격 디렉터리 준비)은 성공하고 검증 호출은 실패하게 만든다.
        self.stub('ssh', 'case "$*" in *sha256sum*) exit 1 ;; esac\nexit 0')
        result = self.run_script('ship.sh')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((run_dir / 'SHIPPED').exists())
        self.assertFalse((run_dir / 'SHIPPING').exists())
        self.assertTrue((run_dir / 'SUCCESS').exists())
        self.assertIn('원격 체크섬 검증에 실패', result.stderr)

    # --- 4. 전송 중에는 보존 정책이 같은 잠금에 막힌다 -------------------------------
    def test_retention_is_blocked_while_shipping_holds_the_lock(self):
        run_dir = self.make_runs(['20260101T001000Z'])[0]
        self.stub('age', 'exec cat')
        self.stub('rsync', 'sleep 5\nexit 0')
        self.stub('ssh', 'exit 0')
        with subprocess.Popen(['bash', str(ROOT / 'backup/ship.sh')], env=self.env(),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as shipping:
            try:
                marker = run_dir / 'SHIPPING'
                deadline = time.time() + 20
                while not marker.exists() and time.time() < deadline:
                    if shipping.poll() is not None:
                        self.fail('ship.sh 가 잠금을 잡기 전에 끝났다')
                    time.sleep(0.05)
                self.assertTrue(marker.exists(), 'SHIPPING 표시가 생기지 않았다')
                blocked = self.run_script('retention.sh', BK_LOCK_WAIT_SEC='1')
                self.assertEqual(blocked.returncode, 1, blocked.stdout + blocked.stderr)
                self.assertIn('잠금', blocked.stderr)
                self.assertTrue(run_dir.exists())
            finally:
                shipping.wait(timeout=60)
        self.assertEqual(shipping.returncode, 0)

    # --- 5. 디스크 여유 부족 경로는 그대로 유지된다 ----------------------------------
    def test_pg_backup_refuses_to_start_without_free_space(self):
        result = self.run_script('pg-backup.sh', PG_MIN_FREE_BYTES=str(1 << 62),
                                 PG_DATABASES='dummy', PG_DUMP_CMD='false',
                                 PG_DUMPALL_CMD='false', PG_RESTORE_CMD='false')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('디스크 여유가 부족합니다', result.stderr)
        self.assertEqual(list((self.root / 'postgresql').glob('2*')), [])
        state = json.loads((self.state / 'postgresql-last-run.json').read_text())
        self.assertEqual(state['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
