# test-env.sh : test-rpm.sh 가 읽는 postgresql19 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=postgresql            # RPM 패키지 이름
VER_MACRO=pg_ver          # 버전을 지정하는 spec 매크로 (--define "pg_ver X")
REPO_NAME="PostgreSQL 19"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"

# spec 의 Source0 과 같아야 함
version_url() { echo "https://ftp.postgresql.org/pub/source/v$1/postgresql-$1.tar.bz2"; }

# 정식 릴리스(19.N)만. 정식 릴리스가 하나뿐이면 출시 후보로 직접 지정해서 검사:
#   OUT_DIR=_build/testrepo/al2023/postgresql19 sh test-rpm.sh postgresql19 19rc2 19.0
#   (출시 후보 RPM 이 배포 저장소(dist/)에 들어가지 않도록 OUT_DIR 을 따로 지정)
list_versions() {
  curl -sf --max-time 60 "https://ftp.postgresql.org/pub/source/" \
    | grep -oE "\"v$VER_PREFIX\.[0-9]+/\"" | grep -oE "$VER_PREFIX\.[0-9]+" | sort -uV
}
