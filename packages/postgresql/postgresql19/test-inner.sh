# test-inner.sh : postgresql19 설치 → 기동 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log, start_unit, wait_unit / OLD_VER, NEW_VER, REPO_ID, REL, PKG

UNIT=/usr/lib/systemd/system/postgresql.service
CONF=/etc/postgresql/postgresql.conf
DATA=/data/postgresql/data
PSQL="runuser -u postgres -- /usr/local/bin/psql -X -At"

start_pg() { start_unit "$UNIT" "runuser -u postgres -- /opt/postgresql/bin/pg_isready -q" "/data/postgresql/logs/postgresql-$(LC_ALL=C date +%a).log" 120; }
stop_pg()  { run "runuser -u postgres -- /opt/postgresql/bin/pg_ctl -D $DATA stop -m fast >/dev/null"; wait_unit; }

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: postgresql-$OLD_VER"
run "yum install -y --best postgresql-$OLD_VER"
run "yum list installed postgresql 2>/dev/null | grep -E '^postgresql\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' postgresql | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' postgresql | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed postgresql 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' postgresql | grep -qx 2"
check "postgres --version = $OLD_VER"      "/opt/postgresql/bin/postgres --version | grep -q ') $OLD_VER\$'"
check "/usr/local/bin/psql → /opt/postgresql/bin/psql" \
  "[ \"\$(readlink -f /usr/local/bin/psql)\" = /opt/postgresql/bin/psql ]"
check "psql 이 PATH 에서 실행됨"           "command -v psql | grep -qx /usr/local/bin/psql"
check "contrib 확장 포함 (pg_stat_statements, uuid-ossp)" \
  "[ -f /opt/postgresql/lib/pg_stat_statements.so ] && [ -f /opt/postgresql/share/extension/uuid-ossp.control ]"
check "$CONF 설치됨"                       "[ -f $CONF ]"
check "pg_hosts.conf 설치됨 (PostgreSQL 19)" "[ -f /etc/postgresql/pg_hosts.conf ]"
check "pg_hba.conf 는 postgres 소유 0640"  "[ \"\$(stat -c '%U %a' /etc/postgresql/pg_hba.conf)\" = 'postgres 640' ]"
check "postgresql.service 설치됨"          "[ -f $UNIT ]"
check "postgres 계정 생성됨"               "id postgres"
check "$DATA 권한 0700 (postgres 소유)"    "[ \"\$(stat -c '%U %a' $DATA)\" = 'postgres 700' ]"
check "/data/postgresql/logs (postgres 소유)" "[ \"\$(stat -c %U /data/postgresql/logs)\" = postgres ]"
check "postgres 라이브러리 누락 없음 (ldd)" "! ldd /opt/postgresql/bin/postgres | grep -q 'not found'"
check "psql 라이브러리 누락 없음 (ldd)"    "! ldd /opt/postgresql/bin/psql | grep -q 'not found'"

# ---------- 7) 자동 초기화 / 기동 / 데이터 저장 ----------
log "7) 첫 기동: 자동 initdb ($OLD_VER)"
check "기동 전 datadir 비어 있음" "[ -z \"\$(ls -A $DATA)\" ]"
if start_pg; then
  check "자동 initdb 로 데이터 생성됨"     "[ -f $DATA/PG_VERSION ]"
  check "서버 버전 $OLD_VER (peer 인증으로 접속)" "$PSQL -c 'SHOW server_version' | grep -q '^$OLD_VER'"
  check "server_encoding = UTF8"           "$PSQL -c 'SHOW server_encoding' | grep -qx UTF8"
  check "lc_collate = C.UTF-8"             "$PSQL -c \"SELECT datcollate FROM pg_database WHERE datname='postgres'\" | grep -qx C.UTF-8"
  check "data_checksums = on"              "$PSQL -c 'SHOW data_checksums' | grep -qx on"
  check "/etc/postgresql 설정 사용"        "$PSQL -c 'SHOW config_file' | grep -qx $CONF"
  check "localhost 에서만 listen"          "$PSQL -c 'SHOW listen_addresses' | grep -qx localhost"
  check "timezone = Asia/Seoul"            "$PSQL -c 'SHOW timezone' | grep -qx Asia/Seoul"
  check "log_timezone = Asia/Seoul"        "$PSQL -c 'SHOW log_timezone' | grep -qx Asia/Seoul"
  check "pg_stat_statements 로드됨"        "$PSQL -c 'SHOW shared_preload_libraries' | grep -q pg_stat_statements"
  check "로그 파일 생성 (/data/postgresql/logs)" "ls /data/postgresql/logs/postgresql-*.log"
  run "$PSQL -c 'CREATE DATABASE pkgtest' >/dev/null"
  run "$PSQL -d pkgtest -c \"CREATE EXTENSION \\\"uuid-ossp\\\"; CREATE EXTENSION pg_stat_statements; CREATE TABLE t (v text); INSERT INTO t VALUES ('$OLD_VER')\" >/dev/null"
  check "확장 동작 (uuid_generate_v4)"     "$PSQL -d pkgtest -c 'SELECT uuid_generate_v4()' | grep -qE '^[0-9a-f-]{36}\$'"
  check "TCP 접속은 비밀번호 필요 (scram)" "! runuser -u postgres -- /usr/local/bin/psql -X -At -h 127.0.0.1 -w -c 'SELECT 1' 2>/dev/null"
  stop_pg
else
  FAIL=$((FAIL+1)); FAILED+=("postgres 기동 ($OLD_VER)")
fi

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update postgresql"
echo "# test-marker: 운영자가 수정한 설정" >> $CONF
run "yum check-update postgresql; [ \$? -eq 100 ]"
run "yum update -y --best postgresql"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed postgresql 2>/dev/null | grep -E '^postgresql\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' postgresql | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q postgresql | wc -l) -eq 1 ]"
check "postgres --version = $NEW_VER"      "/opt/postgresql/bin/postgres --version | grep -q ') $NEW_VER\$'"
check "수정한 postgresql.conf 보존됨"      "grep -q 'test-marker' $CONF"
check "명령어 링크 유지"                   "[ \"\$(readlink -f /usr/local/bin/psql)\" = /opt/postgresql/bin/psql ]"
check "postgres 라이브러리 누락 없음 (ldd)" "! ldd /opt/postgresql/bin/postgres | grep -q 'not found'"
if start_pg; then
  check "서버 버전 $NEW_VER"               "$PSQL -c 'SHOW server_version' | grep -q '^$NEW_VER'"
  check "업데이트 전 데이터 유지"          "$PSQL -d pkgtest -c 'SELECT v FROM t' | grep -qx '$OLD_VER'"
  check "확장 동작 (uuid_generate_v4)"     "$PSQL -d pkgtest -c 'SELECT uuid_generate_v4()' | grep -qE '^[0-9a-f-]{36}\$'"
  stop_pg
else
  FAIL=$((FAIL+1)); FAILED+=("postgres 기동 ($NEW_VER)")
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove postgresql"
run "yum remove -y postgresql"
check "패키지 삭제됨"                      "! rpm -q postgresql"
check "/opt/postgresql 삭제됨"             "[ ! -e /opt/postgresql/bin/postgres ]"
check "/usr/local/bin/psql 링크 삭제됨"    "[ ! -e /usr/local/bin/psql ] && [ ! -L /usr/local/bin/psql ]"
check "데이터 보존 ($DATA)"                "[ -f $DATA/PG_VERSION ]"
check "수정한 postgresql.conf 는 .rpmsave 로 보존" "grep -q 'test-marker' $CONF.rpmsave"
