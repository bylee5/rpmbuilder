# test-inner.sh : mongodb-tools100 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG

TOOLS="bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop"

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: mongodb-tools-$OLD_VER"
run "yum install -y --best mongodb-tools-$OLD_VER"
run "yum list installed mongodb-tools 2>/dev/null | grep -E '^mongodb-tools\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' mongodb-tools | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' mongodb-tools | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed mongodb-tools 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2"                            "rpm -q --qf '%{EPOCH}' mongodb-tools | grep -qx 2"
for t in $TOOLS; do
  check "$t: 링크 → /opt/mongodb-tools/bin/$t, 버전 $OLD_VER" \
    "[ \"\$(readlink -f /usr/local/bin/$t)\" = /opt/mongodb-tools/bin/$t ] && $t --version | grep -q 'version: $OLD_VER\$'"
done
check "mongodump 이 PATH 에서 실행됨"      "command -v mongodump | grep -qx /usr/local/bin/mongodump"
check "라이브러리 누락 없음 (ldd)" \
  "for t in $TOOLS; do ! ldd /opt/mongodb-tools/bin/\$t 2>&1 | grep -q 'not found' || exit 1; done"

# ---------- 7) 실행 (서버 없이) ----------
log "7) 실행 확인 ($OLD_VER)"
# 빈 BSON 문서 {} (5바이트) 를 만들어 bsondump 로 읽기
printf '\005\000\000\000\000' > /tmp/empty.bson
check "bsondump 로 BSON 파일 읽기"         "bsondump --quiet /tmp/empty.bson | grep -qx '{}'"
check "일반 사용자도 실행 가능"            "runuser -u nobody -- /usr/local/bin/mongodump --version | grep -q '$OLD_VER'"

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update mongodb-tools"
run "yum check-update mongodb-tools; [ \$? -eq 100 ]"
run "yum update -y --best mongodb-tools"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed mongodb-tools 2>/dev/null | grep -E '^mongodb-tools\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' mongodb-tools | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q mongodb-tools | wc -l) -eq 1 ]"
for t in $TOOLS; do
  check "$t: 버전 $NEW_VER"                "$t --version | grep -q 'version: $NEW_VER\$'"
done
check "bsondump 로 BSON 파일 읽기"         "bsondump --quiet /tmp/empty.bson | grep -qx '{}'"

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove mongodb-tools"
run "yum remove -y mongodb-tools"
check "패키지 삭제됨"                      "! rpm -q mongodb-tools"
check "/opt/mongodb-tools 삭제됨"          "[ ! -e /opt/mongodb-tools/bin/mongodump ]"
check "명령어 링크 모두 삭제됨" \
  "for t in $TOOLS; do [ ! -e /usr/local/bin/\$t ] && [ ! -L /usr/local/bin/\$t ] || exit 1; done"
