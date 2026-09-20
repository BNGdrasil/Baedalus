-- VM3 PostgreSQL 모니터링 전용 역할.
--
--   sudo -u postgres psql -p 5432 -f postgres-exporter-role.sql
--   sudo -u postgres psql -p 5432 -c '\password bngdrasil_exporter'
--
-- 두 번째 명령은 비밀번호를 프롬프트로 받아서 서버에 보내므로, 셸 이력과 프로세스
-- 인자에 비밀번호가 남지 않는다. 이 파일에도 비밀번호를 적지 않는다.
--
-- 2026-09 기준으로 VM3 에는 PostgreSQL 17 이 5432 에, 이전 세대인 14 가 5433 에 있다.
-- 두 클러스터를 모두 관측하려면 같은 파일을 포트만 바꾸어 한 번씩 더 실행한다.
-- PostgreSQL 14 에도 pg_monitor 역할이 있으므로 이 스크립트를 그대로 쓸 수 있다.

\set ON_ERROR_STOP on

-- 역할이 이미 있으면 다시 만들지 않는다. 같은 파일을 여러 번 실행해도 안전하다.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bngdrasil_exporter') THEN
        CREATE ROLE bngdrasil_exporter WITH LOGIN;
        RAISE NOTICE '역할 bngdrasil_exporter 를 만들었습니다. \password 로 비밀번호를 지정하십시오.';
    ELSE
        RAISE NOTICE '역할 bngdrasil_exporter 가 이미 있으므로 그대로 둡니다.';
    END IF;
END
$$;

-- 지표 조회에 필요한 최소 권한만 준다. pg_monitor 는 pg_read_all_settings 와
-- pg_read_all_stats 와 pg_stat_scan_tables 를 묶은 내장 역할이며, 사용자 데이터를
-- 읽을 권한은 포함하지 않는다.
GRANT pg_monitor TO bngdrasil_exporter;

-- 슈퍼유저 권한과 역할 생성 권한, 복제 권한은 명시적으로 제거한다.
ALTER ROLE bngdrasil_exporter NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

-- exporter 가 접속할 데이터베이스. postgres 데이터베이스 한 곳에만 붙어도 클러스터
-- 전체의 통계를 읽을 수 있다.
GRANT CONNECT ON DATABASE postgres TO bngdrasil_exporter;

-- 동시 접속 수를 제한해 두면, exporter 가 비정상적으로 재시도하더라도 운영 접속을
-- 밀어내지 않는다.
ALTER ROLE bngdrasil_exporter CONNECTION LIMIT 5;

-- 확인용 조회. 결과에 rolsuper 가 f 로 나와야 한다.
SELECT rolname, rolsuper, rolcanlogin, rolconnlimit
  FROM pg_roles
 WHERE rolname = 'bngdrasil_exporter';
