"""Local regression checks; no Docker daemon, SSH, or production data needed."""
import json
import os
from pathlib import Path
import re
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


class RemoteExporterPreflight(unittest.TestCase):
    """monitoring/remote-exporters 설치 스크립트의 사전 점검 회귀 검사.

    2026-09-19 에 VM1 과 VM3 에 올린 node-exporter 컨테이너가 9100 을 잡고 있는 상태에서
    설치 스크립트를 그대로 돌리면 유닛이 조용히 기동에 실패한다. 그 상황을 가짜 ss 와
    가짜 docker 로 재현한다. 운영 VM 과 systemd 와 Docker 데몬이 모두 필요하지 않다.
    """

    EXPORTER_DIR = ROOT / 'monitoring/remote-exporters'

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # 기본 대역은 모두 "점유 없음" 상태다. 각 시험이 필요한 것만 덮어쓴다.
        self.stub('ss', 'exit 0')
        self.stub('docker', 'exit 0')
        self.stub('systemctl', 'exit 0')
        # 다운로드가 일어났는지 보려고 curl 호출을 파일로 남긴다.
        self.stub('curl', 'echo "$@" >> "$PREFLIGHT_TMP/curl-called"\nexit 1')
        self.addCleanup(self._tmp.cleanup)

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def env(self, **extra):
        base = dict(os.environ,
                    PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                    PREFLIGHT_TMP=str(self.root))
        base.update(extra)
        return base

    def run_installer(self, script, *args, **envextra):
        return subprocess.run(['bash', str(self.EXPORTER_DIR / script), *args],
                              env=self.env(**envextra), capture_output=True,
                              text=True, timeout=60)

    def textfile_dir(self):
        return str(self.root / 'state/node_exporter/textfile_collector')

    # --- (a) 다른 프로세스가 포트를 잡고 있으면 내려받기 전에 멈춘다 -------------------
    def test_foreign_listener_aborts_before_download(self):
        # 컨테이너가 --network host 로 도는 상태를 흉내 낸 와일드카드 바인딩이다.
        self.stub('ss', 'echo \'LISTEN 0 4096 *:9100 *:* '
                        'users:(("node_exporter",pid=4242,fd=3))\'')
        self.stub('systemctl', 'case "$*" in\n'
                               '  "show -p MainPID --value node_exporter.service") echo 0 ;;\n'
                               'esac\nexit 0')
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    EX_ALLOW_NONROOT='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('9100', result.stderr)
        self.assertIn('pid=4242', result.stderr)
        self.assertIn('전환하는 절차', result.stderr)
        # 점검이 다운로드보다 먼저 돌아야 하므로 curl 은 한 번도 불리지 않는다.
        self.assertFalse((self.root / 'curl-called').exists(), result.stdout)

    def test_foreign_listener_on_specific_address_also_aborts(self):
        """와일드카드가 아니라 지정 주소 바인딩도 똑같이 충돌로 본다."""
        self.stub('ss', 'echo \'LISTEN 0 4096 10.0.1.133:9100 *:* '
                        'users:(("node_exporter",pid=777,fd=3))\'')
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    EX_ALLOW_NONROOT='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'curl-called').exists(), result.stdout)

    def test_same_unit_listener_is_allowed_to_reinstall(self):
        """같은 유닛이 듣고 있는 재설치는 통과해야 한다."""
        self.stub('ss', 'echo \'LISTEN 0 4096 10.0.1.133:9100 *:* '
                        'users:(("node_exporter",pid=4242,fd=3))\'')
        self.stub('systemctl', 'case "$*" in\n'
                               '  "show -p MainPID --value node_exporter.service") echo 4242 ;;\n'
                               'esac\nexit 0')
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    '--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('같은 유닛을 다시 설치합니다', result.stdout)

    # --- (b) 남아 있는 컨테이너를 찾으면 멈춘다 ------------------------------------
    def test_existing_docker_container_aborts_install(self):
        self.stub('docker', 'case "$*" in\n'
                            '  "ps -a"*) echo '
                            '\'node-exporter|prom/node-exporter:v1.9.1|Up 20 hours\' ;;\n'
                            'esac\nexit 0')
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    EX_ALLOW_NONROOT='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('prom/node-exporter:v1.9.1', result.stderr)
        self.assertIn('docker stop node-exporter', result.stderr)
        self.assertFalse((self.root / 'curl-called').exists(), result.stdout)

    def test_stopped_docker_container_also_aborts_install(self):
        """restart 정책 때문에 되살아날 수 있으므로 중지된 컨테이너도 충돌로 본다."""
        self.stub('docker', 'case "$*" in\n'
                            '  "ps -a"*) echo '
                            '\'node-exporter|prom/node-exporter:v1.9.1|Exited (0) 2 days ago\' ;;\n'
                            'esac\nexit 0')
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    EX_ALLOW_NONROOT='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Exited', result.stderr)

    # --- (c) 점유가 없으면 dry-run 이 정상으로 끝난다 -------------------------------
    def test_clean_host_dry_run_succeeds(self):
        result = self.run_installer('install-node-exporter.sh',
                                    '--listen-address', '10.0.1.133',
                                    '--textfile-dir', self.textfile_dir(),
                                    '--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('9100 포트를 듣고 있는 프로세스가 없습니다', result.stdout)
        self.assertIn('컨테이너는 없습니다', result.stdout)
        self.assertFalse((self.root / 'curl-called').exists(), result.stdout)

    def test_port_check_also_guards_nginx_and_postgres_installers(self):
        """같은 점검이 나머지 두 스크립트에도 각자의 포트로 걸려 있어야 한다."""
        for script, address, port in [
                ('install-nginx-exporter.sh', '10.0.1.133', '9113'),
                ('install-postgres-exporter.sh', '10.0.2.134', '9187')]:
            with self.subTest(script=script):
                self.stub('ss', 'echo \'LISTEN 0 4096 *:%s *:* '
                                'users:(("other",pid=31337,fd=3))\'' % port)
                result = self.run_installer(script, '--listen-address', address,
                                            EX_ALLOW_NONROOT='1')
                self.assertNotEqual(result.returncode, 0,
                                    result.stdout + result.stderr)
                self.assertIn(port, result.stderr)
                self.assertIn('pid=31337', result.stderr)
                self.assertFalse((self.root / 'curl-called').exists(), result.stdout)

    # --- (d) 상위 디렉터리의 others 실행 비트를 좁은 범위에서만 고친다 ------------------
    def test_traversal_fix_touches_only_exporter_owned_directories(self):
        base = self.root / 'fs'
        outsider = base / 'var'
        owned = outsider / 'node_exporter'
        target = owned / 'textfile_collector'
        target.mkdir(parents=True)
        # VM3 에서 확인한 상태를 그대로 만든다. 상위가 0700 이라 비root 사용자가 막힌다.
        for d in (base, outsider, owned, target):
            d.chmod(0o700)

        script = ('set -euo pipefail\n'
                  '. "%s/lib/common.sh"\n'
                  'EX_COMPONENT=test\n'
                  'ex_ensure_traversable "%s"\n' % (self.EXPORTER_DIR, target))
        result = subprocess.run(['bash', '-c', script], env=self.env(),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # exporter 전용 경로와 목표 디렉터리만 0755 가 된다.
        self.assertEqual(owned.stat().st_mode & 0o777, 0o755, result.stdout)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755, result.stdout)
        # 이름이 node_exporter 계열이 아닌 상위는 그대로 두고 경고만 남긴다.
        self.assertEqual(outsider.stat().st_mode & 0o777, 0o700, result.stdout)
        self.assertIn(str(outsider), result.stderr)

    def test_traversal_fix_is_report_only_in_dry_run(self):
        owned = self.root / 'fs2/node_exporter'
        target = owned / 'textfile_collector'
        target.mkdir(parents=True)
        owned.chmod(0o700)
        target.chmod(0o700)

        script = ('set -euo pipefail\n'
                  'EX_DRY_RUN=1\n'
                  '. "%s/lib/common.sh"\n'
                  'EX_COMPONENT=test\n'
                  'ex_ensure_traversable "%s"\n' % (self.EXPORTER_DIR, target))
        result = subprocess.run(['bash', '-c', script], env=self.env(),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('(dry-run) chmod 0755', result.stdout)
        self.assertEqual(owned.stat().st_mode & 0o777, 0o700, result.stdout)

class MonitoringBindMountSources(unittest.TestCase):
    """2026-09-21 오리진 probe 전면 실패의 재발 방지 검사.

    .gitignore 의 *.pem 규칙이 monitoring/blackbox/cloudflare-origin-ca.pem 을 무시했고,
    deploy-monitoring.yml 은 러너가 checkout 한 monitoring/ 을 그대로 VM2 로 rsync 하므로
    그 파일이 VM2 에 도착하지 않았다. 그 자리에 compose 가 단일 파일 bind mount 를 걸자
    Docker 가 빈 디렉터리를 만들었고, 컨테이너 안에서는 CA 파일이 디렉터리로 보여서 모든
    오리진 probe 가 1ms 도 되지 않아 "is a directory" 오류로 끝났다.

    저장소 파일만 읽으므로 Docker 데몬과 SSH 와 운영 VM 이 모두 필요하지 않다.
    """

    COMPOSE = ROOT / 'monitoring/docker-compose.monitoring.yml'
    BLACKBOX = ROOT / 'monitoring/blackbox/blackbox.yml'

    # compose 의 짧은 문법 mount 한 줄이다. "- ./monitoring/<원본>:<대상>[:<옵션>]" 형태만
    # 받는다. 긴 문법으로 적힌 항목은 지금 모두 /var/run/docker.sock 같은 호스트 절대
    # 경로라서 이 검사의 대상이 아니다.
    MOUNT_RE = re.compile(
        r'^\s*-\s*(\./monitoring/[^:\s]+):(/[^:\s]+?)(?::([a-z,]+))?\s*$')

    def mounts(self):
        """compose 에서 ./monitoring/ 아래를 원본으로 삼는 mount 를 (원본, 대상) 으로 돌려준다."""
        found = []
        for line in self.COMPOSE.read_text().splitlines():
            m = self.MOUNT_RE.match(line)
            if m:
                found.append((m.group(1), m.group(2)))
        # 정규식이나 compose 의 표기가 바뀌어서 한 건도 잡히지 않으면 이 검사는
        # 아무것도 보지 않으면서 통과하게 된다. 그 상태를 실패로 못 박는다.
        self.assertGreaterEqual(
            len(found), 10,
            'compose 에서 ./monitoring/ mount 를 거의 찾지 못했다. MOUNT_RE 나 compose 표기를 확인한다.')
        return found

    def test_bind_mount_sources_exist_and_are_tracked(self):
        """compose 가 참조하는 원본은 모두 존재해야 하고 무시 대상이 아니어야 한다.

        무시되는 파일은 clean checkout 에 들어오지 않으므로 rsync 가 보낼 수 없다.
        이 검사는 고치기 전의 .gitignore 에서 반드시 실패한다.
        """
        missing = []
        ignored = []
        for source, _target in self.mounts():
            relative = source[len('./'):]
            path = ROOT / relative
            if not path.exists():
                missing.append(source)
                continue
            # 종료 코드 0 은 "무시된다" 는 뜻이다. 부정 규칙에 걸린 경로는 0 이 아니다.
            result = subprocess.run(['git', 'check-ignore', '-q', '--', relative],
                                    cwd=str(ROOT), capture_output=True, timeout=30)
            if result.returncode == 0:
                ignored.append(source)

        self.assertEqual(missing, [], 'compose 가 mount 하는 원본이 저장소에 없다.')
        self.assertEqual(
            ignored, [],
            'compose 가 mount 하는 원본이 .gitignore 로 무시되고 있다. '
            '배포는 checkout 의 내용만 보내므로 이 경로는 VM2 에 도착하지 않고, '
            'Docker 가 그 자리에 빈 디렉터리를 만든다.')

    def test_blackbox_ca_file_points_at_a_compose_mount_target(self):
        """blackbox.yml 의 ca_file 은 compose 가 실제로 mount 하는 대상 경로여야 한다.

        두 파일 가운데 한쪽만 고치면 컨테이너는 정상으로 뜨고 probe 시점에만 실패한다.
        그 실패는 오리진이 죽은 것과 지표에서 구분되지 않으므로 여기에서 묶어 둔다.
        """
        ca_files = re.findall(r'^\s*ca_file:\s*(\S+)\s*$',
                              self.BLACKBOX.read_text(), re.MULTILINE)
        self.assertEqual(len(ca_files), 1,
                         'blackbox.yml 의 ca_file 항목이 하나가 아니다: %r' % (ca_files,))
        ca_file = ca_files[0]

        targets = {target: source for source, target in self.mounts()}
        self.assertIn(ca_file, targets,
                      'blackbox.yml 의 ca_file 경로를 compose 가 mount 하지 않는다. '
                      '이 상태에서는 컨테이너 안에 CA 파일이 없어서 오리진 probe 가 전부 실패한다.')

        # 원본 쪽도 함께 본다. 빈 파일이거나 인증서가 아니면 exporter 는 기동에
        # 성공하고 probe 에서만 실패한다.
        source = ROOT / targets[ca_file][len('./'):]
        self.assertTrue(source.is_file(), '%s 가 일반 파일이 아니다.' % source)
        body = source.read_text()
        self.assertIn('BEGIN CERTIFICATE', body,
                      '%s 에 인증서가 들어 있지 않다.' % source)
        self.assertNotIn('PRIVATE KEY', body,
                         '%s 에 개인 키가 들어 있다. 이 파일은 공개 루트 묶음이어야 한다.' % source)


if __name__ == '__main__':
    unittest.main()
