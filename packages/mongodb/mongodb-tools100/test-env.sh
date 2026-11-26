# test-env.sh : test-rpm.sh 가 읽는 mongodb-tools100 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mongodb-tools         # RPM 패키지 이름
VER_MACRO=tools_ver       # 버전을 지정하는 spec 매크로 (--define "tools_ver X")
REPO_NAME="MongoDB Database Tools 100"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"

# OS 별 tarball (spec 의 tools_os 와 같아야 함)
case "$TARGET_OS" in
  al2023) _tools_os=amazon2023 ;;
  el9)    _tools_os=rhel93 ;;
esac
version_url() { echo "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-$_tools_os-$ARCH-$1.tgz"; }

# 100.20.1 처럼 중간 자리도 바뀌므로 GitHub 태그(100.x.y) 목록 사용
list_versions() {
  curl -sf --max-time 60 "https://api.github.com/repos/mongodb/mongo-tools/git/matching-refs/tags/$VER_PREFIX." \
    | grep -oE '"ref": *"refs/tags/[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -uV
}
