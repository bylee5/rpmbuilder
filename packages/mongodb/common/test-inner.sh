# test-inner.sh : mongodb 서버 공통 설치 → 기동 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log, start_unit, wait_unit / OLD_VER, NEW_VER, REPO_ID, REL, PKG, TARGET_OS

UNIT=/usr/lib/systemd/system/mongod.service
CONF=/etc/mongodb/mongod.conf
LOGFILE=/data/mongodb/logs/mongod.log
ADMIN_PW='PkgTest#2026'

# mongosh 실행 (인증 없이 / 관리자 계정으로)
msh()      { mongosh --quiet "$@"; }
msh_auth() { mongosh --quiet -u admin -p "$ADMIN_PW" --authenticationDatabase admin "$@"; }

start_mongod() { start_unit "$UNIT" "mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' | grep -qx 1" "$LOGFILE" 120; }
stop_mongod() {
  # 정상 종료(shutdown 명령) 후에는 연결이 끊기므로 mongosh 종료 코드는 무시
  printf '\033[0;36m    $ mongosh -u admin ... --eval "db.adminCommand({shutdown:1})"\033[0m\n'
  msh_auth admin --eval 'db.adminCommand({shutdown: 1})' >/dev/null 2>&1 || :
  wait_unit
}

# ---------- 검사용 클라이언트: mongosh (패키지에 포함되지 않으므로 MongoDB 공식 저장소에서 설치) ----------
log "검사 준비: mongosh 설치 (MongoDB 공식 저장소)"
case "$TARGET_OS" in
  al2023) MONGO_REPO_PATH="amazon/2023" ;;
  *)      MONGO_REPO_PATH="redhat/9" ;;
esac
cat > /etc/yum.repos.d/mongodb-org-mongosh.repo <<EOF
[mongodb-org-mongosh]
name=MongoDB official (mongosh only, for test)
baseurl=https://repo.mongodb.org/yum/$MONGO_REPO_PATH/mongodb-org/8.0/\$basearch/
includepkgs=mongodb-mongosh*
gpgcheck=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
enabled=1
EOF
run "dnf -y -q install mongodb-mongosh >/dev/null"
check "mongosh 설치됨" "command -v mongosh"

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mongodb-$OLD_VER"
run "yum install -y --best mongodb-$OLD_VER"
run "yum list installed mongodb 2>/dev/null | grep -E '^mongodb\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mongodb | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mongodb | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mongodb 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mongodb | grep -qx 2"
check "/opt/mongodb/bin/mongod"            "[ -x /opt/mongodb/bin/mongod ]"
check "mongod --version = $OLD_VER"        "/opt/mongodb/bin/mongod --version | grep -q 'db version v$OLD_VER\$'"
check "/usr/local/bin/mongod → /opt/mongodb/bin/mongod" \
  "[ \"\$(readlink -f /usr/local/bin/mongod)\" = /opt/mongodb/bin/mongod ]"
check "/usr/local/bin/mongos → /opt/mongodb/bin/mongos" \
  "[ \"\$(readlink -f /usr/local/bin/mongos)\" = /opt/mongodb/bin/mongos ]"
check "mongod 이 PATH 에서 실행됨"         "command -v mongod | grep -qx /usr/local/bin/mongod"
check "install_compass 제외됨"             "[ ! -e /opt/mongodb/bin/install_compass ]"
check "$CONF 설치됨"                       "[ -f $CONF ]"
check "mongod.service 설치됨"              "[ -f $UNIT ]"
check "mongodb 계정 생성됨"                "id mongodb"
for d in data logs; do
  check "/data/mongodb/$d (mongodb 소유)"  "[ \"\$(stat -c %U /data/mongodb/$d)\" = mongodb ]"
done
check "mongod 라이브러리 누락 없음 (ldd)"  "! ldd /opt/mongodb/bin/mongod | grep -q 'not found'"
check "mongos 라이브러리 누락 없음 (ldd)"  "! ldd /opt/mongodb/bin/mongos | grep -q 'not found'"

# ---------- 7) 첫 기동 / 관리자 계정 / 데이터 저장 ----------
log "7) 첫 기동 ($OLD_VER)"
check "기동 전 dbPath 비어 있음" "[ -z \"\$(ls -A /data/mongodb/data)\" ]"
if start_mongod; then
  check "첫 기동 시 데이터 파일 생성됨"    "[ -f /data/mongodb/data/WiredTiger ]"
  check "데이터 파일 mongodb 소유"         "[ \"\$(stat -c %U /data/mongodb/data/WiredTiger)\" = mongodb ]"
  check "소켓 파일 생성됨 (/data/mongodb)" "[ -S /data/mongodb/mongodb-27017.sock ]"
  check "외부 주소로는 listen 하지 않음 (bindIp 127.0.0.1)" \
    "grep -q '\"bindIp\":\"127.0.0.1\"' $LOGFILE"
  # 계정이 없을 때만 localhost exception 으로 첫 관리자 생성 가능
  run "mongosh --quiet admin --eval 'db.createUser({user: \"admin\", pwd: \"$ADMIN_PW\", roles: [\"root\"]})' >/dev/null"
  check "인증 활성화: 계정 생성 후 인증 없이 조회 거부" \
    "! msh --eval 'db.adminCommand({listDatabases: 1}).ok' 2>/dev/null"
  check "관리자 계정으로 접속" "msh_auth --eval 'db.adminCommand({listDatabases: 1}).ok' | grep -qx 1"
  check "서버 버전 $OLD_VER"   "msh_auth --eval 'db.version()' | grep -qx '$OLD_VER'"
  # 새로 만든 데이터의 FCV 는 서버 메이저 버전과 같아야 함 (예: 8.3.16 → 8.3)
  check "featureCompatibilityVersion = ${OLD_VER%.*}" \
    "msh_auth admin --eval 'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version' | grep -qx '${OLD_VER%.*}'"
  run "msh_auth pkgtest --eval 'db.t.insertOne({v: \"$OLD_VER\"})' >/dev/null"
  stop_mongod
else
  FAIL=$((FAIL+1)); FAILED+=("mongod 기동 ($OLD_VER)")
fi

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update mongodb"
echo "# test-marker: 운영자가 수정한 설정" >> $CONF
run "yum check-update mongodb; [ \$? -eq 100 ]"
run "yum update -y --best mongodb"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed mongodb 2>/dev/null | grep -E '^mongodb\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' mongodb | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q mongodb | wc -l) -eq 1 ]"
check "mongod --version = $NEW_VER"        "/opt/mongodb/bin/mongod --version | grep -q 'db version v$NEW_VER\$'"
check "수정한 mongod.conf 보존됨"          "grep -q 'test-marker' $CONF"
check "명령어 링크 유지"                   "[ \"\$(readlink -f /usr/local/bin/mongod)\" = /opt/mongodb/bin/mongod ]"
check "mongod 라이브러리 누락 없음 (ldd)"  "! ldd /opt/mongodb/bin/mongod | grep -q 'not found'"
if start_mongod; then
  check "서버 버전 $NEW_VER"               "msh_auth --eval 'db.version()' | grep -qx '$NEW_VER'"
  check "업데이트 전 데이터 유지"          "msh_auth pkgtest --eval 'db.t.findOne().v' | grep -qx '$OLD_VER'"
  check "관리자 계정 유지"                 "msh_auth --eval 'db.adminCommand({listDatabases: 1}).ok' | grep -qx 1"
  stop_mongod
else
  FAIL=$((FAIL+1)); FAILED+=("mongod 기동 ($NEW_VER)")
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mongodb"
run "yum remove -y mongodb"
check "패키지 삭제됨"                      "! rpm -q mongodb"
check "/opt/mongodb 삭제됨"                "[ ! -e /opt/mongodb/bin/mongod ]"
check "/usr/local/bin/mongod 링크 삭제됨"  "[ ! -e /usr/local/bin/mongod ] && [ ! -L /usr/local/bin/mongod ]"
check "데이터 보존 (/data/mongodb/data)"   "[ -f /data/mongodb/data/WiredTiger ]"
check "수정한 mongod.conf 는 .rpmsave 로 보존" "grep -q 'test-marker' $CONF.rpmsave"
