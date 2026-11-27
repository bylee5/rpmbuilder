# test-env.sh : test-rpm.sh 가 읽는 mysqltop0 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mysqltop              # RPM 패키지 이름
VER_MACRO=mytop_ver       # 버전을 지정하는 spec 매크로 (--define "mytop_ver X")
REPO_NAME="mysqltop 0"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"
# 릴리스가 하나뿐일 때도 검사 (이전 = 새 버전, 업데이트 단계는 생략)
MIN_VERSIONS=1

# spec 의 Source0 과 같아야 함
version_url() { echo "https://github.com/bylee5/mysqltop/archive/refs/tags/v$1.tar.gz"; }

# GitHub 태그 목록 (정식 버전 vX.Y.Z 만, 메이저 VER_PREFIX, 낮은 버전 → 높은 버전 순서로 출력)
list_versions() {
  curl -sf --max-time 60 "https://api.github.com/repos/bylee5/mysqltop/tags?per_page=100" \
    | grep -oE '"name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | grep "^$VER_PREFIX\." | sort -uV
}

# ---------- 접속 검사용 MySQL 8.4 (검사 컨테이너와 같은 docker 네트워크의 보조 컨테이너) ----------
# 검사가 끝나면 지운다. 비밀번호는 검사마다 새로 만드는 일회용 값.
# MySQL 8.4 기본 인증(caching_sha2_password)과 자동 생성 TLS 인증서로 접속을 확인한다.
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"
MYSQL_NET="rpmtest-net-$$"
MYSQL_NAME="rpmtest-mysql-$$"

test_setup() {
  local pw="RpmTest${RANDOM}${RANDOM}x"
  docker network create "$MYSQL_NET" >/dev/null || return 1
  echo "    MySQL 컨테이너 시작: $MYSQL_NAME ($MYSQL_IMAGE)"
  docker run -d --name "$MYSQL_NAME" --network "$MYSQL_NET" --network-alias mysql \
    -e MYSQL_ROOT_PASSWORD="$pw" "$MYSQL_IMAGE" >/dev/null || return 1
  TEST_RUN_ARGS+=(--network "$MYSQL_NET" -e MYSQL_TEST_HOST=mysql -e MYSQL_TEST_PW="$pw")
}

test_cleanup() {
  docker rm -f "$MYSQL_NAME"
  docker network rm "$MYSQL_NET"
}
