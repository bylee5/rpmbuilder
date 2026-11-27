# test-inner.sh : mysqltop 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG, TARGET_OS
#   접속 대상:
#     - MySQL 8.4 : test-env.sh 의 test_setup 이 띄운 보조 컨테이너 (MYSQL_TEST_HOST, MYSQL_TEST_PW), TCP
#     - MariaDB   : 이 컨테이너 안에 OS 저장소 패키지로 띄움, 유닉스 소켓 (root, unix_socket 인증)
#   릴리스가 하나뿐이면 OLD_VER = NEW_VER 이고 업데이트 단계(8)는 생략한다.

# ---------- 검사용 서버: MariaDB (OS 저장소, 유닉스 소켓 접속 검사에만 사용) ----------
log "검사 준비: MariaDB 서버 설치 (OS 저장소)"
case "$TARGET_OS" in
  al2023) MARIA_PKG="mariadb105-server" ;;
  *)      MARIA_PKG="mariadb-server" ;;
esac
run "dnf -y -q install $MARIA_PKG procps-ng >/dev/null"
SOCK=/tmp/mariadb.sock
install -d -o mysql -g mysql /tmp/mdb
run "mysql_install_db --user=mysql --datadir=/tmp/mdb >/dev/null 2>&1"
(mysqld_safe --user=mysql --datadir=/tmp/mdb --socket=$SOCK --skip-networking >/dev/null 2>&1 &)
for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 1; done

# 일반 사용자 (설정 파일 우선순위 검사용)
id tester >/dev/null 2>&1 || useradd -m tester

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mysqltop-$OLD_VER"
run "yum install -y --best mysqltop-$OLD_VER"
run "yum list installed mysqltop 2>/dev/null | grep -E '^mysqltop\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mysqltop | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mysqltop | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mysqltop 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mysqltop | grep -qx 2"
check "python3-cryptography 함께 설치됨 (Recommends)" "rpm -q python3-cryptography"
check "/opt/mysqltop/bin/mysqltop"         "[ -x /opt/mysqltop/bin/mysqltop ]"
check "/usr/local/bin/mysqltop → /opt/mysqltop/bin/mysqltop" \
  "[ \"\$(readlink -f /usr/local/bin/mysqltop)\" = /opt/mysqltop/bin/mysqltop ]"
check "mysqltop 이 PATH 에서 실행됨"       "command -v mysqltop | grep -qx /usr/local/bin/mysqltop"
check "mysqltop --version = $OLD_VER"      "mysqltop --version | grep -qx 'mysqltop $OLD_VER'"
check "설정 파일 /etc/mysqltop/mysqltop.ini (noreplace)" \
  "rpm -qc mysqltop | grep -qx /etc/mysqltop/mysqltop.ini && [ -f /etc/mysqltop/mysqltop.ini ]"
check "PyMySQL 을 /opt 에서 읽음"          "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/mysqltop/lib\"); import pymysql; assert pymysql.__file__.startswith(\"/opt/mysqltop/lib/\")'"
# (pipefail: 긴 출력을 grep -q 로 바로 받으면 SIGPIPE 로 실패할 수 있어 파일로 저장 후 확인)
check "바이트코드 포함 (.pyc)"             "rpm -ql mysqltop >/tmp/ql.out; grep -q '/opt/mysqltop/lib/mysqltop/__pycache__/cli\..*\.pyc$' /tmp/ql.out"
check "시스템 python 에 PyMySQL 노출 안 됨" "! /usr/bin/python3 -c 'import pymysql' 2>/dev/null"
check "Provides 에 python 모듈 노출 안 됨" "! rpm -q --provides mysqltop | grep -qi 'pymysql'"

# ---------- 7) 실행 ----------
log "7) 실행 확인 ($OLD_VER)"
export MYSQL_PWD="$MYSQL_TEST_PW"
SRV="$MYSQL_TEST_HOST"
printf '    MySQL 기동 대기 (%s)' "$SRV"
for _ in $(seq 1 90); do
  timeout 20 mysqltop -b -m S -c 1 -u root "$SRV" >/dev/null 2>&1 && break
  printf '.'; sleep 2
done
echo
check "batch 접속 (MySQL 8.4, TCP + TLS, S 모드)" "timeout 60 mysqltop -b -m S -c 1 -i 1 -u root $SRV >/tmp/b1.out 2>&1; grep -q . /tmp/b1.out"
run "sed 's/^/    /' /tmp/b1.out | head -5"
check "batch 접속 (TLS 없이, caching_sha2 RSA)" "timeout 60 mysqltop -b -m S -c 1 -u root --ssl-mode DISABLED $SRV >/tmp/b5.out 2>&1"
check "batch 접속 (MariaDB, 유닉스 소켓)"  "env -u MYSQL_PWD timeout 60 mysqltop -b -m S -c 1 -u root -S $SOCK >/tmp/b4.out 2>&1; grep -q . /tmp/b4.out"
check "설정 파일 없이 --list"              "mysqltop --list >/tmp/list.out 2>&1"
cat >> /etc/mysqltop/mysqltop.ini <<EOF

[server:local-test]
server = $SRV
user = root
groups = test

[server:local-maria]
server = root@$SOCK
groups = test
EOF
check "/etc 설정의 서버가 --list 에 보임"  "mysqltop --list >/tmp/list.out 2>&1; grep -q 'local-test' /tmp/list.out"
check "batch 접속 (설정 파일의 서버 이름)" "timeout 60 mysqltop -b -m Q -c 1 -i 1 local-test >/tmp/b2.out 2>&1"
check "batch 접속 (그룹, A 모드 2회)"      "timeout 60 mysqltop -b -m A -c 2 -i 1 -g test >/tmp/b3.out 2>&1; grep -q local-test /tmp/b3.out && grep -q local-maria /tmp/b3.out"
check "MYSQLTOP_PASSWORD_<NAME> 으로 비밀번호 전달" \
  "env -u MYSQL_PWD MYSQLTOP_PASSWORD_LOCAL_TEST=\"\$MYSQL_TEST_PW\" timeout 60 mysqltop -b -m S -c 1 local-test >/dev/null 2>&1"
check "잘못된 비밀번호는 접근 거부 안내"   "! MYSQL_PWD=wrong timeout 60 mysqltop -b -c 1 -u root $SRV </dev/null >/tmp/bad.out 2>&1; grep -qi 'access denied' /tmp/bad.out"
check "일반 사용자도 실행 가능"            "runuser -u tester -- env MYSQL_PWD=\"\$MYSQL_PWD\" timeout 60 /usr/local/bin/mysqltop -b -m S -c 1 -u root $SRV >/dev/null 2>&1"
check "일반 사용자 실행 시 /opt 에 쓰지 않음" "[ -z \"\$(find /opt/mysqltop -newer /tmp/b1.out -user tester)\" ]"
check "~/.mysqltop.ini 가 /etc 보다 우선" \
  "runuser -u tester -- sh -c 'printf \"[server:mine]\nserver = $SRV\n\" > ~/.mysqltop.ini; mysqltop --list' 2>&1 | grep -q mine"
check "설정 파일의 password 키는 거부"     "! MYSQLTOP_CONFIG=/tmp/bad.ini sh -c 'printf \"[server:x]\nserver = h\npassword = x\n\" > /tmp/bad.ini; mysqltop --list' >/dev/null 2>&1"

# ---------- 8) 업데이트 ----------
if [ "$OLD_VER" = "$NEW_VER" ]; then
  log "8) 업데이트 검사 생략: 저장소의 릴리스가 하나뿐 ($NEW_VER)"
else
  log "8) 업데이트: yum update mysqltop"
  run "yum check-update mysqltop; [ \$? -eq 100 ]"
  run "yum update -y --best mysqltop"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
  run "yum list installed mysqltop 2>/dev/null | grep -E '^mysqltop\.' | sed 's/^/    /'"
  check "설치 버전 $NEW_VER"               "rpm -q --qf '%{VERSION}' mysqltop | grep -qx '$NEW_VER'"
  check "패키지가 하나만 설치됨"           "[ \$(rpm -q mysqltop | wc -l) -eq 1 ]"
  check "mysqltop --version = $NEW_VER"    "mysqltop --version | grep -qx 'mysqltop $NEW_VER'"
  check "수정한 설정 파일 유지 (noreplace)" "grep -q 'local-test' /etc/mysqltop/mysqltop.ini"
  check "명령어 링크 유지"                 "[ \"\$(readlink -f /usr/local/bin/mysqltop)\" = /opt/mysqltop/bin/mysqltop ]"
  check "batch 접속"                       "timeout 60 mysqltop -b -m S -c 1 -u root $SRV >/dev/null 2>&1"
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mysqltop"
run "yum remove -y mysqltop"
check "패키지 삭제됨"                      "! rpm -q mysqltop"
check "/opt/mysqltop 삭제됨"               "[ ! -e /opt/mysqltop ]"
check "/usr/local/bin/mysqltop 링크 삭제됨" "[ ! -e /usr/local/bin/mysqltop ] && [ ! -L /usr/local/bin/mysqltop ]"
check "수정한 설정 파일은 .rpmsave 로 보존" "[ -f /etc/mysqltop/mysqltop.ini.rpmsave ]"
check "사용자 설정 ~/.mysqltop.ini 유지"   "[ -f /home/tester/.mysqltop.ini ]"

mysqladmin -S "$SOCK" -u root shutdown >/dev/null 2>&1 || :
