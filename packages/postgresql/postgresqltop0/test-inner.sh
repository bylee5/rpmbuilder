# test-inner.sh : postgresqltop 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG, TARGET_OS
#   릴리스가 하나뿐이면 OLD_VER = NEW_VER 이고 업데이트 단계(8)는 생략한다.

# ---------- 검사용 서버: PostgreSQL (OS 저장소, 접속 검사에만 사용) ----------
log "검사 준비: PostgreSQL 서버 설치 (OS 저장소)"
case "$TARGET_OS" in
  al2023) PG_PKGS="postgresql16-server postgresql16-contrib" ;;
  *)      PG_PKGS="postgresql-server postgresql-contrib" ;;
esac
run "dnf -y -q install $PG_PKGS procps-ng >/dev/null"
PG_PW="Rpm#Test${RANDOM}x"
PGDATA_T=/tmp/pgdata
install -d -o postgres -g postgres "$PGDATA_T"
printf '%s\n' "$PG_PW" > /tmp/pgpw; chown postgres /tmp/pgpw
run "runuser -u postgres -- initdb -D $PGDATA_T -U postgres --auth=scram-sha-256 --pwfile=/tmp/pgpw >/dev/null"
rm -f /tmp/pgpw
run "runuser -u postgres -- pg_ctl -D $PGDATA_T -l /tmp/pg.log -w -o \"-c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp -c shared_preload_libraries=pg_stat_statements\" start >/dev/null"
PGPASSWORD="$PG_PW" psql -h 127.0.0.1 -U postgres -qc 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements' >/dev/null 2>&1 || :
export PGPASSWORD="$PG_PW"
SRV="127.0.0.1:5432"

# 일반 사용자 (설정 파일 우선순위 검사용)
id tester >/dev/null 2>&1 || useradd -m tester

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: postgresqltop-$OLD_VER"
run "yum install -y --best postgresqltop-$OLD_VER"
run "yum list installed postgresqltop 2>/dev/null | grep -E '^postgresqltop\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' postgresqltop | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' postgresqltop | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed postgresqltop 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' postgresqltop | grep -qx 2"
check "OS 의 libpq 를 요구하지 않음"       "! rpm -q --requires postgresqltop | grep -qi 'libpq'"
check "/opt/postgresqltop/bin/postgresqltop" "[ -x /opt/postgresqltop/bin/postgresqltop ]"
check "/usr/local/bin/postgresqltop → /opt/postgresqltop/bin/postgresqltop" \
  "[ \"\$(readlink -f /usr/local/bin/postgresqltop)\" = /opt/postgresqltop/bin/postgresqltop ]"
check "postgresqltop 이 PATH 에서 실행됨"  "command -v postgresqltop | grep -qx /usr/local/bin/postgresqltop"
check "postgresqltop --version = $OLD_VER" "postgresqltop --version | grep -qx 'postgresqltop $OLD_VER'"
check "설정 파일 /etc/postgresqltop/postgresqltop.ini (noreplace)" \
  "rpm -qc postgresqltop | grep -qx /etc/postgresqltop/postgresqltop.ini && [ -f /etc/postgresqltop/postgresqltop.ini ]"
check "psycopg 를 /opt 에서 읽음"          "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/postgresqltop/lib\"); import psycopg; assert psycopg.__file__.startswith(\"/opt/postgresqltop/lib/\")'"
check "psycopg binary 구현 사용 (함께 담은 libpq)" \
  "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/postgresqltop/lib\"); import psycopg; assert psycopg.pq.__impl__ == \"binary\", psycopg.pq.__impl__'"
# (pipefail: 긴 출력을 grep -q 로 바로 받으면 SIGPIPE 로 실패할 수 있어 파일로 저장 후 확인)
check "바이트코드 포함 (.pyc)"             "rpm -ql postgresqltop >/tmp/ql.out; grep -q '/opt/postgresqltop/lib/postgresqltop/__pycache__/cli\..*\.pyc$' /tmp/ql.out"
check "C 확장 라이브러리 누락 없음 (ldd)"  "! find /opt/postgresqltop/lib -name '*.so*' -type f -exec ldd {} + | grep -q 'not found'"
check "시스템 python 에 psycopg 노출 안 됨" "! /usr/bin/python3 -c 'import psycopg' 2>/dev/null"
check "Provides 에 .so 노출 안 됨"         "! rpm -q --provides postgresqltop | grep -q '\.so'"

# ---------- 7) 실행 ----------
log "7) 실행 확인 ($OLD_VER)"
check "설정 파일 없이 --list"              "postgresqltop --list >/tmp/list.out 2>&1"
cat >> /etc/postgresqltop/postgresqltop.ini <<EOF

[server:local-test]
server = $SRV
user = postgres
groups = test

[server:local-sock]
server = /tmp
user = postgres
groups = test
EOF
check "/etc 설정의 서버가 --list 에 보임"  "postgresqltop --list >/tmp/list.out 2>&1; grep -q 'local-test' /tmp/list.out"
check "batch 접속 (주소, S 모드)"          "timeout 60 postgresqltop -b -m S -c 1 -i 1 -U postgres $SRV >/tmp/b1.out 2>&1; grep -q . /tmp/b1.out"
run "sed 's/^/    /' /tmp/b1.out | head -5"
check "batch 접속 (설정 파일의 서버 이름)" "timeout 60 postgresqltop -b -m Q -c 1 -i 1 local-test >/tmp/b2.out 2>&1"
check "batch 접속 (유닉스 소켓)"           "timeout 60 postgresqltop -b -m S -c 1 -i 1 local-sock >/tmp/b4.out 2>&1"
check "batch 접속 (그룹, A 모드 2회)"      "timeout 60 postgresqltop -b -m A -c 2 -i 1 -g test >/tmp/b3.out 2>&1; grep -q local-test /tmp/b3.out"
check "POSTGRESQLTOP_PASSWORD_<NAME> 으로 비밀번호 전달" \
  "env -u PGPASSWORD POSTGRESQLTOP_PASSWORD_LOCAL_TEST=\"\$PGPASSWORD\" timeout 60 postgresqltop -b -m S -c 1 local-test >/dev/null 2>&1"
check "잘못된 비밀번호는 인증 실패 안내"   "! PGPASSWORD=wrong timeout 60 postgresqltop -b -c 1 -U postgres $SRV </dev/null >/tmp/bad.out 2>&1; grep -qi 'password' /tmp/bad.out"
check "일반 사용자도 실행 가능"            "runuser -u tester -- env PGPASSWORD=\"\$PGPASSWORD\" timeout 60 /usr/local/bin/postgresqltop -b -m S -c 1 -U postgres $SRV >/dev/null 2>&1"
check "일반 사용자 실행 시 /opt 에 쓰지 않음" "[ -z \"\$(find /opt/postgresqltop -newer /tmp/b1.out -user tester)\" ]"
check "~/.postgresqltop.ini 가 /etc 보다 우선" \
  "runuser -u tester -- sh -c 'printf \"[server:mine]\nserver = $SRV\n\" > ~/.postgresqltop.ini; postgresqltop --list' 2>&1 | grep -q mine"
check "설정 파일의 password 키는 거부"     "! POSTGRESQLTOP_CONFIG=/tmp/bad.ini sh -c 'printf \"[server:x]\nserver = h\npassword = x\n\" > /tmp/bad.ini; postgresqltop --list' >/dev/null 2>&1"

# ---------- 8) 업데이트 ----------
if [ "$OLD_VER" = "$NEW_VER" ]; then
  log "8) 업데이트 검사 생략: 저장소의 릴리스가 하나뿐 ($NEW_VER)"
else
  log "8) 업데이트: yum update postgresqltop"
  run "yum check-update postgresqltop; [ \$? -eq 100 ]"
  run "yum update -y --best postgresqltop"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
  run "yum list installed postgresqltop 2>/dev/null | grep -E '^postgresqltop\.' | sed 's/^/    /'"
  check "설치 버전 $NEW_VER"               "rpm -q --qf '%{VERSION}' postgresqltop | grep -qx '$NEW_VER'"
  check "패키지가 하나만 설치됨"           "[ \$(rpm -q postgresqltop | wc -l) -eq 1 ]"
  check "postgresqltop --version = $NEW_VER" "postgresqltop --version | grep -qx 'postgresqltop $NEW_VER'"
  check "수정한 설정 파일 유지 (noreplace)" "grep -q 'local-test' /etc/postgresqltop/postgresqltop.ini"
  check "명령어 링크 유지"                 "[ \"\$(readlink -f /usr/local/bin/postgresqltop)\" = /opt/postgresqltop/bin/postgresqltop ]"
  check "batch 접속"                       "timeout 60 postgresqltop -b -m S -c 1 -U postgres $SRV >/dev/null 2>&1"
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove postgresqltop"
run "yum remove -y postgresqltop"
check "패키지 삭제됨"                      "! rpm -q postgresqltop"
check "/opt/postgresqltop 삭제됨"          "[ ! -e /opt/postgresqltop ]"
check "/usr/local/bin/postgresqltop 링크 삭제됨" "[ ! -e /usr/local/bin/postgresqltop ] && [ ! -L /usr/local/bin/postgresqltop ]"
check "수정한 설정 파일은 .rpmsave 로 보존" "[ -f /etc/postgresqltop/postgresqltop.ini.rpmsave ]"
check "사용자 설정 ~/.postgresqltop.ini 유지" "[ -f /home/tester/.postgresqltop.ini ]"
check "PostgreSQL 서버 패키지는 그대로 (별도 패키지)" "rpm -qa >/tmp/qa.out; grep -q 'postgresql.*-server' /tmp/qa.out"

runuser -u postgres -- pg_ctl -D "$PGDATA_T" -m fast stop >/dev/null 2>&1 || :
