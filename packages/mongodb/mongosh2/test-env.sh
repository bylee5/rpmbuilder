# test-env.sh : test-rpm.sh 가 읽는 mongosh2 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mongosh               # RPM 패키지 이름
VER_MACRO=msh_ver         # 버전을 지정하는 spec 매크로 (--define "msh_ver X")
REPO_NAME="MongoDB Shell 2"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"

case "$ARCH" in
  x86_64)  _msh_arch=x64 ;;
  aarch64) _msh_arch=arm64 ;;
esac
# spec 의 Source0 과 같아야 함
version_url() { echo "https://downloads.mongodb.com/compass/mongosh-$1-linux-$_msh_arch-openssl3.tgz"; }

# mongosh 는 2.14.3 처럼 중간 자리도 바뀌므로 순서대로 확인하는 대신 GitHub 릴리스 목록 사용
# (정식 릴리스만, 메이저 VER_PREFIX, 낮은 버전 → 높은 버전 순서로 출력)
list_versions() {
  curl -sf --max-time 60 "https://api.github.com/repos/mongodb-js/mongosh/releases?per_page=50" \
    | grep -oE '"tag_name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | grep "^$VER_PREFIX\." | sort -uV
}
