# test-env.sh : test-rpm.sh 가 읽는 mssqltop0 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mssqltop              # RPM 패키지 이름
VER_MACRO=mstop_ver       # 버전을 지정하는 spec 매크로 (--define "mstop_ver X")
REPO_NAME="mssqltop 0"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"
# 릴리스가 하나뿐일 때도 검사 (이전 = 새 버전, 업데이트 단계는 생략)
MIN_VERSIONS=1

# spec 의 Source0 과 같아야 함
version_url() { echo "https://github.com/bylee5/mssqltop/archive/refs/tags/v$1.tar.gz"; }

# GitHub 태그 목록 (정식 버전 vX.Y.Z 만, 메이저 VER_PREFIX, 낮은 버전 → 높은 버전 순서로 출력)
list_versions() {
  curl -sf --max-time 60 "https://api.github.com/repos/bylee5/mssqltop/tags?per_page=100" \
    | grep -oE '"name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | grep "^$VER_PREFIX\." | sort -uV
}

# ---------- 접속 검사용 SQL Server (검사 컨테이너와 같은 docker 네트워크의 보조 컨테이너) ----------
# 검사가 끝나면 지운다. 비밀번호는 검사마다 새로 만드는 일회용 값.
# 2022-latest / 2025-latest 는 일부 Docker 버전에서 레이어 풀기 실패(invalid tar header) → 고정 태그 사용
MSSQL_IMAGE="${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU20-ubuntu-22.04}"
MSSQL_NET="rpmtest-net-$$"
MSSQL_NAME="rpmtest-mssql-$$"

test_setup() {
  local pw="Rpm#Test${RANDOM}${RANDOM}x"
  docker network create "$MSSQL_NET" >/dev/null || return 1
  echo "    SQL Server 컨테이너 시작: $MSSQL_NAME ($MSSQL_IMAGE)"
  docker run -d --name "$MSSQL_NAME" --network "$MSSQL_NET" --network-alias mssql \
    -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$pw" -e MSSQL_PID=Developer \
    "$MSSQL_IMAGE" >/dev/null || return 1
  TEST_RUN_ARGS+=(--network "$MSSQL_NET" -e MSSQL_TEST_HOST=mssql -e MSSQL_TEST_PW="$pw")
}

test_cleanup() {
  docker rm -f "$MSSQL_NAME"
  docker network rm "$MSSQL_NET"
}
