# test-inner.sh : mssqltop 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG, TARGET_OS
#   접속 대상: test-env.sh 의 test_setup 이 띄운 SQL Server (MSSQL_TEST_HOST, MSSQL_TEST_PW)
#   릴리스가 하나뿐이면 OLD_VER = NEW_VER 이고 업데이트 단계(8)는 생략한다.

# ---------- 6) 이전 버전 설치 (ODBC 드라이버 없이) ----------
log "6) 특정 버전 설치: mssqltop-$OLD_VER"
run "yum install -y --best mssqltop-$OLD_VER"
run "yum list installed mssqltop 2>/dev/null | grep -E '^mssqltop\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mssqltop | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mssqltop | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mssqltop 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mssqltop | grep -qx 2"
check "unixODBC 함께 설치됨"               "rpm -q unixODBC"
check "/opt/mssqltop/bin/mssqltop"         "[ -x /opt/mssqltop/bin/mssqltop ]"
check "/usr/local/bin/mssqltop → /opt/mssqltop/bin/mssqltop" \
  "[ \"\$(readlink -f /usr/local/bin/mssqltop)\" = /opt/mssqltop/bin/mssqltop ]"
check "mssqltop 이 PATH 에서 실행됨"       "command -v mssqltop | grep -qx /usr/local/bin/mssqltop"
check "mssqltop --version = $OLD_VER"      "mssqltop --version | grep -qx 'mssqltop $OLD_VER'"
check "설정 파일 /etc/mssqltop/mssqltop.ini (noreplace)" \
  "rpm -qc mssqltop | grep -qx /etc/mssqltop/mssqltop.ini && [ -f /etc/mssqltop/mssqltop.ini ]"
check "pyodbc 를 /opt 에서 읽음"           "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/mssqltop/lib\"); import pyodbc; assert pyodbc.__file__.startswith(\"/opt/mssqltop/lib/\")'"
# (pipefail: 긴 출력을 grep -q 로 바로 받으면 SIGPIPE 로 실패할 수 있어 파일로 저장 후 확인)
check "바이트코드 포함 (.pyc)"             "rpm -ql mssqltop >/tmp/ql.out; grep -q '/opt/mssqltop/lib/mssqltop/__pycache__/cli\..*\.pyc$' /tmp/ql.out"
check "pyodbc 라이브러리 누락 없음 (ldd)"  "! find /opt/mssqltop/lib -name '*.so' -exec ldd {} + | grep -q 'not found'"
check "시스템 python 에 pyodbc 노출 안 됨" "! /usr/bin/python3 -c 'import pyodbc' 2>/dev/null"
check "Provides 에 .so 노출 안 됨"         "! rpm -q --provides mssqltop | grep -q '\.so'"
check "드라이버 없을 때 설치 안내 출력"    "! timeout 60 mssqltop -b -c 1 127.0.0.1 >/tmp/nodrv.out 2>&1; grep -qi 'ODBC Driver' /tmp/nodrv.out"

# ---------- 7) 실행 (Microsoft ODBC 드라이버 설치 후 SQL Server 접속) ----------
log "7) 실행 확인 ($OLD_VER)"
run "curl -sSf -o /etc/yum.repos.d/mssql-release.repo https://packages.microsoft.com/config/rhel/9/prod.repo"
run "ACCEPT_EULA=Y dnf -y -q install msodbcsql18 >/dev/null"
check "msodbcsql18 설치됨"                 "rpm -q msodbcsql18"
check "pyodbc 가 드라이버를 찾음"          "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/mssqltop/lib\"); import pyodbc; assert any(\"SQL Server\" in d for d in pyodbc.drivers())'"

export MSSQL_PASSWORD="$MSSQL_TEST_PW"
SRV="sa@$MSSQL_TEST_HOST"
printf '    SQL Server 기동 대기 (%s)' "$MSSQL_TEST_HOST"
for _ in $(seq 1 90); do
  timeout 20 mssqltop -b -m S -c 1 --trust-cert "$SRV" >/dev/null 2>&1 && break
  printf '.'; sleep 2
done
echo
check "batch 접속 (주소, S 모드)"          "timeout 60 mssqltop -b -m S -c 1 -i 1 --trust-cert $SRV >/tmp/b1.out 2>&1; grep -q . /tmp/b1.out"
run "sed 's/^/    /' /tmp/b1.out | head -5"
check "설정 파일 없이 --list (빈 목록)"    "mssqltop --list >/tmp/list.out 2>&1; grep -q '/etc/mssqltop/mssqltop.ini' /tmp/list.out"
cat >> /etc/mssqltop/mssqltop.ini <<EOF

[server:local-test]
server = $MSSQL_TEST_HOST
user = sa
trust_cert = yes
groups = test
EOF
check "/etc 설정의 서버가 --list 에 보임"  "mssqltop --list >/tmp/list.out 2>&1; grep -q 'local-test' /tmp/list.out"
check "batch 접속 (설정 파일의 서버 이름)" "timeout 60 mssqltop -b -m Q -c 1 -i 1 local-test >/tmp/b2.out 2>&1"
check "batch 접속 (그룹, A 모드 2회)"      "timeout 60 mssqltop -b -m A -c 2 -i 1 -g test >/tmp/b3.out 2>&1; grep -q local-test /tmp/b3.out"
check "잘못된 비밀번호는 로그인 실패 안내" "! MSSQL_PASSWORD=wrong timeout 60 mssqltop -b -c 1 --trust-cert $SRV >/tmp/bad.out 2>&1; grep -qi 'login' /tmp/bad.out"
id tester >/dev/null 2>&1 || useradd -m tester
check "일반 사용자도 실행 가능"            "runuser -u tester -- env MSSQL_PASSWORD=\"\$MSSQL_PASSWORD\" timeout 60 /usr/local/bin/mssqltop -b -m S -c 1 --trust-cert $SRV >/dev/null 2>&1"
check "일반 사용자 실행 시 /opt 에 쓰지 않음" "[ -z \"\$(find /opt/mssqltop -newer /tmp/b1.out -user tester)\" ]"
check "~/.mssqltop.ini 가 /etc 보다 우선" \
  "runuser -u tester -- sh -c 'printf \"[server:mine]\nserver = $MSSQL_TEST_HOST\n\" > ~/.mssqltop.ini; mssqltop --list' 2>&1 | grep -q mine"
check "설정 파일의 password 키는 거부"     "! MSSQLTOP_CONFIG=/tmp/bad.ini sh -c 'printf \"[server:x]\nserver = h\npassword = x\n\" > /tmp/bad.ini; mssqltop --list' >/dev/null 2>&1"

# ---------- 8) 업데이트 ----------
if [ "$OLD_VER" = "$NEW_VER" ]; then
  log "8) 업데이트 검사 생략: 저장소의 릴리스가 하나뿐 ($NEW_VER)"
else
  log "8) 업데이트: yum update mssqltop"
  run "yum check-update mssqltop; [ \$? -eq 100 ]"
  run "yum update -y --best mssqltop"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
  run "yum list installed mssqltop 2>/dev/null | grep -E '^mssqltop\.' | sed 's/^/    /'"
  check "설치 버전 $NEW_VER"               "rpm -q --qf '%{VERSION}' mssqltop | grep -qx '$NEW_VER'"
  check "패키지가 하나만 설치됨"           "[ \$(rpm -q mssqltop | wc -l) -eq 1 ]"
  check "mssqltop --version = $NEW_VER"    "mssqltop --version | grep -qx 'mssqltop $NEW_VER'"
  check "수정한 설정 파일 유지 (noreplace)" "grep -q 'local-test' /etc/mssqltop/mssqltop.ini"
  check "명령어 링크 유지"                 "[ \"\$(readlink -f /usr/local/bin/mssqltop)\" = /opt/mssqltop/bin/mssqltop ]"
  check "batch 접속"                       "timeout 60 mssqltop -b -m S -c 1 --trust-cert $SRV >/dev/null 2>&1"
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mssqltop"
run "yum remove -y mssqltop"
check "패키지 삭제됨"                      "! rpm -q mssqltop"
check "/opt/mssqltop 삭제됨"               "[ ! -e /opt/mssqltop ]"
check "/usr/local/bin/mssqltop 링크 삭제됨" "[ ! -e /usr/local/bin/mssqltop ] && [ ! -L /usr/local/bin/mssqltop ]"
check "수정한 설정 파일은 .rpmsave 로 보존" "[ -f /etc/mssqltop/mssqltop.ini.rpmsave ]"
check "사용자 설정 ~/.mssqltop.ini 유지"   "[ -f /home/tester/.mssqltop.ini ]"
check "ODBC 드라이버는 그대로 (별도 패키지)" "rpm -q msodbcsql18"
