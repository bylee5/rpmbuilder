# test-inner.sh : mysql 공통 설치 → 기동 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log, start_unit, wait_unit / OLD_VER, NEW_VER, REPO_ID, REL, PKG

UNIT=/usr/lib/systemd/system/mysqld.service
ERRLOG=/data/mysql/logs/mysqld.err

# 긴급 수정 릴리스(예: 8.4.13.1)의 바이너리는 원래 버전(8.4.13)을 표시하므로 앞 세 자리로 비교
OLD_BIN="$(echo "$OLD_VER" | cut -d. -f1-3)"
NEW_BIN="$(echo "$NEW_VER" | cut -d. -f1-3)"

start_mysqld() { start_unit "$UNIT" "mysqladmin -uroot ping" "$ERRLOG" 300; }
stop_mysqld()  { run "mysqladmin -uroot shutdown"; wait_unit; }

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mysql-$OLD_VER"
run "yum install -y --best mysql-$OLD_VER"
run "yum list installed mysql 2>/dev/null | grep -E '^mysql\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mysql | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mysql | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mysql 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mysql | grep -qx 2"
check "/opt/mysql/bin/mysqld"              "[ -x /opt/mysql/bin/mysqld ]"
check "mysqld --version = $OLD_BIN"        "/opt/mysql/bin/mysqld --version | grep -q ' $OLD_BIN '"
check "/usr/local/bin/mysql → /opt/mysql/bin/mysql" \
  "[ \"\$(readlink -f /usr/local/bin/mysql)\" = /opt/mysql/bin/mysql ]"
check "mysql 이 PATH 에서 실행됨"          "command -v mysql | grep -qx /usr/local/bin/mysql"
check "alternatives 사용 안 함"            "[ ! -e /etc/alternatives/mysql-client ]"
check "/etc/mysql/my.cnf 설치됨"           "[ -f /etc/mysql/my.cnf ]"
check "mysqld.service 설치됨"              "[ -f $UNIT ]"
check "mysql 계정 생성됨"                  "id mysql"
for d in data logs binlog tmp; do
  check "/data/mysql/$d (mysql 소유)"      "[ \"\$(stat -c %U /data/mysql/$d)\" = mysql ]"
done
check "mysqld 라이브러리 누락 없음 (ldd)"  "! ldd /opt/mysql/bin/mysqld | grep -q 'not found'"
check "mysql 라이브러리 누락 없음 (ldd)"   "! ldd /opt/mysql/bin/mysql  | grep -q 'not found'"

# ---------- 7) 초기화 / 기동 / 데이터 저장 ----------
log "7) 첫 기동: 자동 초기화 ($OLD_VER)"
check "기동 전 datadir 비어 있음" "[ -z \"\$(ls -A /data/mysql/data)\" ]"
if start_mysqld; then
  check "자동 초기화로 데이터 생성됨"      "[ -d /data/mysql/data/mysql ]"
  check "데이터 파일 mysql 소유"           "[ \"\$(stat -c %U /data/mysql/data/mysql.ibd)\" = mysql ]"
  TMP_PW="$(sed -n 's/.*temporary password is generated for root@localhost: //p' "$ERRLOG" | tail -1)"
  check "임시 root 비밀번호가 에러 로그에 기록됨" "[ -n \"\$TMP_PW\" ]"
  check "임시 비밀번호는 만료 상태 (변경 전 쿼리 거부)" \
    "! mysql -uroot -p\"\$TMP_PW\" -N -e 'SELECT 1' 2>/dev/null"
  run "mysql -uroot -p\"\$TMP_PW\" --connect-expired-password -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'PkgTest#2026'\" 2>/dev/null"
  # 이후 접속은 ~/.my.cnf 의 비밀번호 사용 (옵션 파일에서 # 은 주석이므로 따옴표 필수)
  printf '[client]\nuser=root\npassword="PkgTest#2026"\n' > /root/.my.cnf; chmod 600 /root/.my.cnf
  check "서버 버전 $OLD_VER (클라이언트가 my.cnf 소켓으로 접속)" \
    "mysql -N -e 'SELECT VERSION()' | grep -q '^$OLD_BIN'"
  # my.cnf 에 설정한 값이 초기화에 반영됐는지 확인
  LCTN="$(sed -n 's/^lower_case_table_names[[:space:]]*=[[:space:]]*\([0-9]\).*/\1/p' /etc/mysql/my.cnf | tail -1)"
  check "lower_case_table_names = ${LCTN:-0} (my.cnf 값)" \
    "mysql -N -e 'SELECT @@lower_case_table_names' | grep -qx '${LCTN:-0}'"
  check "innodb_page_size = 16384"   "mysql -N -e 'SELECT @@innodb_page_size' | grep -qx 16384"
  run "mysql -uroot -e \"CREATE DATABASE pkgtest; CREATE TABLE pkgtest.t (v VARCHAR(20)); INSERT INTO pkgtest.t VALUES ('$OLD_VER');\""
  stop_mysqld
else
  FAIL=$((FAIL+1)); FAILED+=("mysqld 기동 ($OLD_VER)")
fi

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update mysql"
echo "# test-marker: 운영자가 수정한 설정" >> /etc/mysql/my.cnf
OLD_SUM="$(sha256sum /opt/mysql/bin/mysqld | cut -d' ' -f1)"
run "yum check-update mysql; [ \$? -eq 100 ]"
run "yum update -y --best mysql"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed mysql 2>/dev/null | grep -E '^mysql\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' mysql | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q mysql | wc -l) -eq 1 ]"
check "mysqld --version = $NEW_BIN"        "/opt/mysql/bin/mysqld --version | grep -q ' $NEW_BIN '"
check "mysqld 바이너리 교체됨"             "[ \"\$(sha256sum /opt/mysql/bin/mysqld | cut -d' ' -f1)\" != \"\$OLD_SUM\" ]"
check "수정한 my.cnf 보존됨"               "grep -q 'test-marker' /etc/mysql/my.cnf"
check "명령어 링크 유지"                   "[ \"\$(readlink -f /usr/local/bin/mysql)\" = /opt/mysql/bin/mysql ]"
check "mysqld 라이브러리 누락 없음 (ldd)"  "! ldd /opt/mysql/bin/mysqld | grep -q 'not found'"
if start_mysqld; then
  check "서버 버전 $NEW_BIN"               "mysql -uroot -N -e 'SELECT VERSION()' | grep -q '^$NEW_BIN'"
  check "업데이트 전 데이터 유지"          "mysql -uroot -N -e 'SELECT v FROM pkgtest.t' | grep -qx '$OLD_VER'"
  check "재기동 시 다시 초기화하지 않음"   "[ \$(grep -c 'temporary password' $ERRLOG) -eq 1 ]"
  stop_mysqld
else
  FAIL=$((FAIL+1)); FAILED+=("mysqld 기동 ($NEW_VER)")
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mysql"
run "yum remove -y mysql"
check "패키지 삭제됨"                      "! rpm -q mysql"
check "/opt/mysql 삭제됨"                  "[ ! -e /opt/mysql/bin/mysqld ]"
check "/usr/local/bin/mysql 링크 삭제됨"   "[ ! -e /usr/local/bin/mysql ] && [ ! -L /usr/local/bin/mysql ]"
check "데이터 보존 (/data/mysql/data)"     "[ -d /data/mysql/data/pkgtest ]"
check "수정한 my.cnf 는 .rpmsave 로 보존"  "grep -q 'test-marker' /etc/mysql/my.cnf.rpmsave"
