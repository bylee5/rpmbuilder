# test-env.sh : test-rpm.sh 가 읽는 mysql 공통 검사 설정 (mysql84, mysql97, mysql2610 ...)
#   버전 폴더에 같은 이름의 파일을 두면 그 파일을 대신 사용
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=mysql                 # RPM 패키지 이름
VER_MACRO=mysql_ver       # 버전을 지정하는 spec 매크로 (--define "mysql_ver X")
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"
REPO_NAME="MySQL $VER_PREFIX"   # 저장소 설명 (예: MySQL 8.4)
_glibc="$(sed -n 's/^%global[[:space:]]\{1,\}glibc[[:space:]]\{1,\}//p' "$SPEC" | head -1)"

# 버전 자동 선택 시 다운로드 가능 여부를 확인할 주소 (spec 의 Source0 과 같아야 함)
version_url() { echo "http://dev.mysql.com/get/mysql-$1-linux-glibc$_glibc-$ARCH.tar.xz"; }
