# test-env.sh : test-rpm.sh 가 읽는 mongodb 서버 공통 검사 설정 (mongodb83, mongodb90 ...)
#   버전 폴더에 같은 이름의 파일을 두면 그 파일을 대신 사용 (mongosh2, mongodb-tools100 은 자체 파일)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mongodb               # RPM 패키지 이름
VER_MACRO=mongo_ver       # 버전을 지정하는 spec 매크로 (--define "mongo_ver X")
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"
REPO_NAME="MongoDB $VER_PREFIX"   # 저장소 설명 (예: MongoDB 8.3)

# MongoDB 는 OS 별 tarball (spec 의 mongo_os 와 같아야 함)
case "$TARGET_OS" in
  al2023) _mongo_os=amazon2023 ;;
  el9)    _mongo_os=rhel93 ;;
esac
version_url() { echo "https://fastdl.mongodb.org/linux/mongodb-linux-$ARCH-$_mongo_os-$1.tgz"; }
