# test-inner.sh : mongosh2 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mongosh-$OLD_VER"
run "yum install -y --best mongosh-$OLD_VER"
run "yum list installed mongosh 2>/dev/null | grep -E '^mongosh\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mongosh | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mongosh | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mongosh 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mongosh | grep -qx 2"
check "/opt/mongosh/bin/mongosh"           "[ -x /opt/mongosh/bin/mongosh ]"
check "/usr/local/bin/mongosh → /opt/mongosh/bin/mongosh" \
  "[ \"\$(readlink -f /usr/local/bin/mongosh)\" = /opt/mongosh/bin/mongosh ]"
check "mongosh 이 PATH 에서 실행됨"        "command -v mongosh | grep -qx /usr/local/bin/mongosh"
check "mongosh --version = $OLD_VER"       "mongosh --version | grep -qx '$OLD_VER'"
check "암호화 라이브러리 포함 (mongosh_crypt_v1.so)" "[ -f /opt/mongosh/bin/mongosh_crypt_v1.so ]"
check "매뉴얼 설치됨"                      "[ -f /usr/share/man/man1/mongosh.1.gz ]"
check "mongosh 라이브러리 누락 없음 (ldd)" "! ldd /opt/mongosh/bin/mongosh | grep -q 'not found'"
check "시스템 OpenSSL 3 사용"              "ldd /opt/mongosh/bin/mongosh | grep -q 'libssl.so.3'"

# ---------- 7) 실행 (서버 없이) ----------
log "7) 실행 확인 ($OLD_VER)"
check "스크립트 실행 (--nodb)"             "mongosh --nodb --quiet --eval '1 + 1' | grep -qx 2"
check "일반 사용자도 실행 가능"            "runuser -u nobody -- /usr/local/bin/mongosh --nodb --quiet --eval 'version()' | grep -qx '$OLD_VER'"

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update mongosh"
run "yum check-update mongosh; [ \$? -eq 100 ]"
run "yum update -y --best mongosh"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed mongosh 2>/dev/null | grep -E '^mongosh\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' mongosh | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q mongosh | wc -l) -eq 1 ]"
check "mongosh --version = $NEW_VER"       "mongosh --version | grep -qx '$NEW_VER'"
check "명령어 링크 유지"                   "[ \"\$(readlink -f /usr/local/bin/mongosh)\" = /opt/mongosh/bin/mongosh ]"
check "스크립트 실행 (--nodb)"             "mongosh --nodb --quiet --eval '1 + 1' | grep -qx 2"

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mongosh"
run "yum remove -y mongosh"
check "패키지 삭제됨"                      "! rpm -q mongosh"
check "/opt/mongosh 삭제됨"                "[ ! -e /opt/mongosh/bin/mongosh ]"
check "/usr/local/bin/mongosh 링크 삭제됨" "[ ! -e /usr/local/bin/mongosh ] && [ ! -L /usr/local/bin/mongosh ]"
