# test-inner.sh : mongodbtop 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG, TARGET_OS
#   릴리스가 하나뿐이면 OLD_VER = NEW_VER 이고 업데이트 단계(8)는 생략한다.

# ---------- 검사용 서버: mongod (MongoDB 공식 저장소, 접속 검사에만 사용) ----------
log "검사 준비: mongod 설치 (MongoDB 공식 저장소)"
case "$TARGET_OS" in
  al2023) MONGO_REPO_PATH="amazon/2023" ;;
  *)      MONGO_REPO_PATH="redhat/9" ;;
esac
cat > /etc/yum.repos.d/mongodb-org-test.repo <<EOF
[mongodb-org-test]
name=MongoDB official (server only, for test)
baseurl=https://repo.mongodb.org/yum/$MONGO_REPO_PATH/mongodb-org/8.0/\$basearch/
includepkgs=mongodb-org-server*
gpgcheck=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
enabled=1
EOF
run "dnf -y -q install mongodb-org-server procps-ng >/dev/null"
mkdir -p /tmp/mdb
run "mongod --dbpath /tmp/mdb --bind_ip 127.0.0.1 --port 27017 --fork --logpath /tmp/mdb/mongod.log >/dev/null"
URI="mongodb://127.0.0.1:27017"

# 일반 사용자 (설정 파일 우선순위 검사용)
id tester >/dev/null 2>&1 || useradd -m tester

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mongodbtop-$OLD_VER"
run "yum install -y --best mongodbtop-$OLD_VER"
run "yum list installed mongodbtop 2>/dev/null | grep -E '^mongodbtop\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mongodbtop | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mongodbtop | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mongodbtop 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mongodbtop | grep -qx 2"
check "/opt/mongodbtop/bin/mongodbtop"     "[ -x /opt/mongodbtop/bin/mongodbtop ]"
check "/usr/local/bin/mongodbtop → /opt/mongodbtop/bin/mongodbtop" \
  "[ \"\$(readlink -f /usr/local/bin/mongodbtop)\" = /opt/mongodbtop/bin/mongodbtop ]"
check "mongodbtop 이 PATH 에서 실행됨"     "command -v mongodbtop | grep -qx /usr/local/bin/mongodbtop"
check "mongodbtop --version = $OLD_VER"    "mongodbtop --version | grep -qx 'mongodbtop $OLD_VER'"
check "설정 파일 /etc/mongodbtop/mongodbtop.ini (noreplace)" \
  "rpm -qc mongodbtop | grep -qx /etc/mongodbtop/mongodbtop.ini && [ -f /etc/mongodbtop/mongodbtop.ini ]"
check "pymongo 를 /opt 에서 읽음"          "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/mongodbtop/lib\"); import pymongo; assert pymongo.__file__.startswith(\"/opt/mongodbtop/lib/\")'"
check "pymongo C 확장 사용 (has_c)"        "/usr/bin/python3 -I -c 'import sys; sys.path.insert(0, \"/opt/mongodbtop/lib\"); import pymongo; assert pymongo.has_c()'"
# (pipefail: 긴 출력을 grep -q 로 바로 받으면 SIGPIPE 로 실패할 수 있어 파일로 저장 후 확인)
check "바이트코드 포함 (.pyc)"             "rpm -ql mongodbtop >/tmp/ql.out; grep -q '/opt/mongodbtop/lib/mongodbtop/__pycache__/cli\..*\.pyc$' /tmp/ql.out"
check "pymongo C 확장 라이브러리 누락 없음 (ldd)" \
  "! find /opt/mongodbtop/lib -name '*.so' -exec ldd {} + | grep -q 'not found'"
check "시스템 python 에 pymongo 노출 안 됨" "! /usr/bin/python3 -c 'import pymongo' 2>/dev/null"
check "Provides 에 .so 노출 안 됨"         "! rpm -q --provides mongodbtop | grep -q '\.so'"

# ---------- 7) 실행 ----------
log "7) 실행 확인 ($OLD_VER)"
check "설정 파일 없이 --list (빈 목록)"    "mongodbtop --list >/tmp/list.out 2>&1; grep -q '/etc/mongodbtop/mongodbtop.ini' /tmp/list.out"
cat >> /etc/mongodbtop/mongodbtop.ini <<'EOF'

[server:local-test]
uri = mongodb://127.0.0.1:27017
groups = test
EOF
check "/etc 설정의 서버가 --list 에 보임"  "mongodbtop --list >/tmp/list.out 2>&1; grep -q 'local-test' /tmp/list.out"
check "batch 접속 (URI, S 모드)"           "timeout 60 mongodbtop -b -m S -c 1 -i 1 $URI >/tmp/b1.out 2>&1; grep -q . /tmp/b1.out"
run "sed 's/^/    /' /tmp/b1.out | head -5"
check "batch 접속 (설정 파일의 서버 이름)" "timeout 60 mongodbtop -b -m Q -c 1 -i 1 local-test >/tmp/b2.out 2>&1"
check "batch 접속 (그룹, A 모드 2회)"      "timeout 60 mongodbtop -b -m A -c 2 -i 1 -g test >/tmp/b3.out 2>&1; grep -q local-test /tmp/b3.out"
check "일반 사용자도 실행 가능"            "runuser -u tester -- timeout 60 /usr/local/bin/mongodbtop -b -m S -c 1 $URI >/dev/null 2>&1"
check "일반 사용자 실행 시 /opt 에 쓰지 않음" "[ -z \"\$(find /opt/mongodbtop -newer /tmp/b1.out -user tester)\" ]"
check "~/.mongodbtop.ini 가 /etc 보다 우선" \
  "runuser -u tester -- sh -c 'printf \"[server:mine]\nuri = $URI\n\" > ~/.mongodbtop.ini; mongodbtop --list' 2>&1 | grep -q mine"
check "설정 파일의 password 키는 거부"     "! MONGODBTOP_CONFIG=/tmp/bad.ini sh -c 'printf \"[server:x]\nuri = $URI\npassword = x\n\" > /tmp/bad.ini; mongodbtop --list' >/dev/null 2>&1"

# ---------- 8) 업데이트 ----------
if [ "$OLD_VER" = "$NEW_VER" ]; then
  log "8) 업데이트 검사 생략: 저장소의 릴리스가 하나뿐 ($NEW_VER)"
else
  log "8) 업데이트: yum update mongodbtop"
  run "yum check-update mongodbtop; [ \$? -eq 100 ]"
  run "yum update -y --best mongodbtop"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
  run "yum list installed mongodbtop 2>/dev/null | grep -E '^mongodbtop\.' | sed 's/^/    /'"
  check "설치 버전 $NEW_VER"               "rpm -q --qf '%{VERSION}' mongodbtop | grep -qx '$NEW_VER'"
  check "패키지가 하나만 설치됨"           "[ \$(rpm -q mongodbtop | wc -l) -eq 1 ]"
  check "mongodbtop --version = $NEW_VER"  "mongodbtop --version | grep -qx 'mongodbtop $NEW_VER'"
  check "수정한 설정 파일 유지 (noreplace)" "grep -q 'local-test' /etc/mongodbtop/mongodbtop.ini"
  check "명령어 링크 유지"                 "[ \"\$(readlink -f /usr/local/bin/mongodbtop)\" = /opt/mongodbtop/bin/mongodbtop ]"
  check "batch 접속"                       "timeout 60 mongodbtop -b -m S -c 1 $URI >/dev/null 2>&1"
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mongodbtop"
run "yum remove -y mongodbtop"
check "패키지 삭제됨"                      "! rpm -q mongodbtop"
check "/opt/mongodbtop 삭제됨"             "[ ! -e /opt/mongodbtop ]"
check "/usr/local/bin/mongodbtop 링크 삭제됨" "[ ! -e /usr/local/bin/mongodbtop ] && [ ! -L /usr/local/bin/mongodbtop ]"
check "수정한 설정 파일은 .rpmsave 로 보존" "[ -f /etc/mongodbtop/mongodbtop.ini.rpmsave ]"
check "사용자 설정 ~/.mongodbtop.ini 유지" "[ -f /home/tester/.mongodbtop.ini ]"

mongod --dbpath /tmp/mdb --shutdown >/dev/null 2>&1 || :
