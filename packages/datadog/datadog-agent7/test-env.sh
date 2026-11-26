# test-env.sh : test-rpm.sh 가 읽는 datadog-agent7 검사 설정 (호스트에서 source)
#   사용 가능한 변수: SPEC, TARGET_OS, ARCH

PKG=datadog-agent         # RPM 패키지 이름
VER_MACRO=dd_ver          # 버전을 지정하는 spec 매크로 (--define "dd_ver X")
REPO_NAME="Datadog Agent 7"
VER_PREFIX="$(sed -n 's/^%global[[:space:]]\{1,\}major[[:space:]]\{1,\}//p' "$SPEC" | head -1)"

_dd_repo="https://yum.datadoghq.com/stable/$VER_PREFIX/$ARCH"
# spec 의 Source0 과 같아야 함 (공식 RPM, 벤더 Release 1)
version_url() { echo "$_dd_repo/datadog-agent-$1-1.$ARCH.rpm"; }

# 공식 yum 저장소의 목록(primary.xml)에서 datadog-agent 버전 추출
list_versions() {
  local primary
  primary="$(curl -sf --max-time 60 "$_dd_repo/repodata/repomd.xml" | grep -oE 'repodata/[^"]*primary\.xml\.gz' | head -1)"
  [ -n "$primary" ] || return 0
  curl -sf --max-time 300 "$_dd_repo/$primary" | gunzip \
    | grep -oE "<location href=\"datadog-agent-$VER_PREFIX\.[0-9]+\.[0-9]+-1\.$ARCH\.rpm\"" \
    | grep -oE "$VER_PREFIX\.[0-9]+\.[0-9]+" | sort -uV
}
