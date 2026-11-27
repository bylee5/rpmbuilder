# test-env.sh : test-rpm.sh 가 읽는 postgresqltop0 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=postgresqltop         # RPM 패키지 이름
VER_MACRO=ptop_ver        # 버전을 지정하는 spec 매크로 (--define "ptop_ver X")
REPO_NAME="postgresqltop 0"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"
# 릴리스가 하나뿐일 때도 검사 (이전 = 새 버전, 업데이트 단계는 생략)
MIN_VERSIONS=1

# spec 의 Source0 과 같아야 함
version_url() { echo "https://github.com/bylee5/postgresqltop/archive/refs/tags/v$1.tar.gz"; }

# GitHub 태그 목록 (정식 버전 vX.Y.Z 만, 메이저 VER_PREFIX, 낮은 버전 → 높은 버전 순서로 출력)
list_versions() {
  curl -sf --max-time 60 "https://api.github.com/repos/bylee5/postgresqltop/tags?per_page=100" \
    | grep -oE '"name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | grep "^$VER_PREFIX\." | sort -uV
}
