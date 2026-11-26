#!/usr/bin/env bash
# =============================================================================
# test-rpm.sh : 패키지의 빌드 → 저장소 → 설치 → 업데이트 → 삭제를
#               깨끗한 docker 컨테이너에서 처음부터 끝까지 검사한다.
#
# 사용법:
#   sh test-rpm.sh [패키지] [이전 버전] [새 버전]
#   패키지 = 저장소 ID(mysql84) 또는 폴더 경로(packages/mysql/mysql84)
#
# 예:
#   sh test-rpm.sh                          # mysql84: 다운로드 가능한 최신 두 버전으로 설치 → 업데이트
#   sh test-rpm.sh mongodb83                # mongodb83: 최신 두 버전
#   sh test-rpm.sh mongosh2                 # mongosh2: 최신 두 버전
#   sh test-rpm.sh mysql84 8.4.11 8.4.13    # 버전 직접 지정
#   SKIP_BUILD=1 sh test-rpm.sh mongodb83   # 빌드 건너뛰고 저장소에 있는 RPM 으로만 검사
#   KEEP=1 sh test-rpm.sh                   # 검사 후 컨테이너를 남겨서 직접 확인
#   OUT_DIR=_build/testrepo/al2023/postgresql19 sh test-rpm.sh postgresql19 19rc2 19.0
#                                           # 출시 후보 등 배포하지 않을 RPM 은 별도 저장소에서 검사
#
# 패키지 폴더 구성 (packages/<제품>/<저장소 ID>/):
#   <저장소 ID>.spec  spec 파일 (폴더 이름 = 저장소 ID)
#   test-env.sh      검사 설정: 패키지 이름, 버전 매크로, tarball 주소 (호스트에서 읽음)
#                    버전 목록 함수 list_versions() 가 있으면 자동 선택에 사용
#   test-inner.sh    설치/기동/업데이트/삭제 검사 6~9단계 (컨테이너에서 실행)
#   버전 폴더에 test-env.sh / test-inner.sh 가 없으면 packages/<제품>/common/ 의 것을 사용
#
# 진행 순서:
#   [호스트]   1) build-rpm.sh 로 두 버전 빌드 (저장소에 이미 있으면 건너뜀)
#   [컨테이너] 2) /etc/yum.repos.d/<저장소 ID>.repo 작성 (baseurl=file:///repo)
#              3) createrepo_c --update /repo
#              4) yum clean metadata --repo <저장소 ID>
#              5) 버전 미지정 시 이 저장소의 최신 버전이 선택되는지 (Epoch 2)
#              6~9) 패키지 폴더의 test-inner.sh (설치 → 기동 → 업데이트 → 삭제)
#
# 저장소 디렉터리: dist/<os>/<저장소 ID>  (예: dist/al2023/mysql84)
#
# 환경변수:
#   TARGET_OS=al2023            al2023 | el9
#   REPO_ID=<폴더 이름>         컨테이너에 만들 저장소 ID
#   TEST_IMAGE=<이미지>         검사용 OS 이미지 (기본: al2023 → amazonlinux:2023, el9 → rockylinux/rockylinux:9)
#   BUILD_MODE=container        build-rpm.sh 빌드 방식 (기본: container)
#   REL=1                       빌드·검사할 Release 번호 (spec/설정을 고쳤으면 올림)
#   SKIP_BUILD=1                빌드 단계 생략
#   KEEP=1                      검사 후 컨테이너 유지
#   MISS_LIMIT=3                버전 자동 확인 시 연속으로 없는 버전이 이만큼이면 확인 종료
#   OUT_DIR=<경로>              저장소 디렉터리 (기본: dist/<os>/<저장소 ID>, 상대 경로 가능)
#
# 참고: 컨테이너에는 systemd 가 없으므로 서버는 설치된 서비스 유닛의
#       ExecStartPre/ExecStart/User 값을 읽어 같은 명령으로 직접 실행한다.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    [OK] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[오류] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 인자: [패키지] [이전 버전] [새 버전] ----------
# 패키지는 저장소 ID(mysql84) 또는 폴더 경로(packages/mysql/mysql84)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
find_pkg_dir() {
  local name="${1%/}" d
  if [ -f "$name/$(basename "$name").spec" ]; then echo "$name"; return; fi
  for d in "$SCRIPT_DIR"/packages/*/"$name"; do
    [ -f "$d/$name.spec" ] && { echo "$d"; return; }
  done
}
PKG_DIR="$(find_pkg_dir mysql84)"
if [ $# -gt 0 ] && [ -n "$(find_pkg_dir "$1")" ]; then PKG_DIR="$(find_pkg_dir "$1")"; shift; fi
[ $# -gt 0 ] && ! [[ "$1" =~ ^[0-9] ]] && die "패키지를 찾을 수 없습니다: $1 (packages/*/$1/$1.spec)"
OLD_VER="${1:-}"
NEW_VER="${2:-}"

TARGET_OS="${TARGET_OS:-al2023}"
REPO_ID="${REPO_ID:-$(basename "$PKG_DIR")}"
SPEC="$PKG_DIR/$(basename "$PKG_DIR").spec"
COMMON_DIR="$PKG_DIR/../common"
REL="${REL:-1}"
ARCH="$(uname -m)"
BASE_DIR="$(pwd)"
OUT_DIR="${OUT_DIR:-dist/$TARGET_OS/$REPO_ID}"
# 상대 경로는 현재 위치 기준 (예: OUT_DIR=_build/testrepo/al2023/postgresql19)
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$BASE_DIR/$OUT_DIR" ;; esac

# 검사 파일: 버전 폴더에 있으면 그것을, 없으면 같은 제품의 common 폴더 것을 사용
pkg_file() {
  if   [ -f "$PKG_DIR/$1" ];    then echo "$PKG_DIR/$1"
  elif [ -f "$COMMON_DIR/$1" ]; then echo "$COMMON_DIR/$1"
  fi
}
TEST_ENV="$(pkg_file test-env.sh)"
TEST_INNER="$(pkg_file test-inner.sh)"

case "$TARGET_OS" in
  el9)    TEST_IMAGE="${TEST_IMAGE:-rockylinux/rockylinux:9}" ;;
  al2023) TEST_IMAGE="${TEST_IMAGE:-amazonlinux:2023}" ;;
  *)      die "TARGET_OS 는 el9 또는 al2023 이어야 합니다: $TARGET_OS" ;;
esac

[ -f "$SPEC" ]          || die "spec 파일이 없습니다: $SPEC"
[ -n "$TEST_ENV" ]      || die "검사 설정이 없습니다: $PKG_DIR/test-env.sh (또는 ../common/test-env.sh)"
[ -n "$TEST_INNER" ]    || die "검사 스크립트가 없습니다: $PKG_DIR/test-inner.sh (또는 ../common/test-inner.sh)"
command -v docker >/dev/null 2>&1 || die "docker 가 필요합니다."
docker info >/dev/null 2>&1 || die "docker 를 사용할 수 없습니다. 'systemctl start docker' 로 시작하세요."

# 제품별 설정: PKG, VER_MACRO, REPO_NAME, VER_PREFIX, version_url()
# shellcheck source=/dev/null
. "$TEST_ENV"
[ -n "${PKG:-}" ] && [ -n "${VER_MACRO:-}" ] && [ -n "${VER_PREFIX:-}" ] \
  || die "$TEST_ENV 에 PKG, VER_MACRO, VER_PREFIX 가 필요합니다."

# ---------- 버전 미지정 시: 다운로드 가능한 최신 버전 2개 자동 선택 ----------
# <VER_PREFIX>.0 부터 차례로 tarball 주소를 확인한다. 회수된 릴리스처럼 중간이 비어
# 있을 수 있어, 연속 MISS_LIMIT 개가 없을 때 확인을 멈춘다.
# test-env.sh 에 list_versions() 가 있으면 그 목록(낮은 → 높은 순)을 쓰고,
# 그중 tarball 을 실제로 받을 수 있는 최신 2개를 고른다.
detect_versions() {
  local n=0 miss=0 found=() v
  command -v curl >/dev/null 2>&1 || die "버전 자동 확인에 curl 이 필요합니다. (또는 버전을 직접 지정)"
  if declare -F list_versions >/dev/null; then
    echo "    $VER_PREFIX.x 버전 목록 확인 중 (test-env.sh 의 list_versions) ..." >&2
    while read -r v; do
      [ -n "$v" ] || continue
      if curl -sfIL --max-time 60 -o /dev/null "$(version_url "$v")"; then
        found=("$v" ${found[@]+"${found[@]}"})
        [ "${#found[@]}" -ge 2 ] && break
      fi
    done < <(list_versions | sort -rV)
    [ "${#found[@]}" -ge 2 ] || die "다운로드 가능한 $VER_PREFIX.x 버전이 2개 미만입니다: ${found[*]:-없음}"
    echo "    선택: ${found[*]}" >&2
    echo "${found[0]} ${found[1]}"
    return
  fi
  echo "    $VER_PREFIX.x 다운로드 가능 버전 확인 중 ($(version_url "$VER_PREFIX.0" | cut -d/ -f3)) ..." >&2
  while [ "$miss" -lt "${MISS_LIMIT:-3}" ]; do
    if curl -sfIL --max-time 60 -o /dev/null "$(version_url "$VER_PREFIX.$n")"; then
      found+=("$VER_PREFIX.$n"); miss=0
      # 긴급 수정 릴리스 (예: MySQL 8.4.13.1) 도 확인
      local h=1
      while curl -sfIL --max-time 60 -o /dev/null "$(version_url "$VER_PREFIX.$n.$h")"; do
        found+=("$VER_PREFIX.$n.$h"); h=$((h+1))
      done
    else
      miss=$((miss+1))
    fi
    n=$((n+1))
  done
  [ "${#found[@]}" -ge 2 ] || die "다운로드 가능한 $VER_PREFIX.x 버전이 2개 미만입니다: ${found[*]:-없음}"
  echo "    발견: ${found[*]}" >&2
  echo "${found[${#found[@]}-2]} ${found[${#found[@]}-1]}"
}
if [ -z "$OLD_VER" ] || [ -z "$NEW_VER" ]; then
  log "검사 버전 자동 선택 (최신 2개)"
  read -r OLD_VER NEW_VER < <(detect_versions) || true
  [ -n "$NEW_VER" ] || die "버전 자동 확인 실패"
fi

log "검사 설정"
echo "    패키지      : $PKG  ($SPEC)"
echo "    버전        : $OLD_VER-$REL → $NEW_VER-$REL"
echo "    저장소      : $OUT_DIR  (저장소 ID: $REPO_ID)"
echo "    검사 이미지 : $TEST_IMAGE"

# ---------- 1) 빌드 ----------
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  log "1) 빌드 생략 (SKIP_BUILD=1)"
else
  for ver in "$OLD_VER" "$NEW_VER"; do
    if ls "$OUT_DIR/$PKG-$ver-$REL".*.rpm >/dev/null 2>&1; then
      log "1) 빌드: $PKG $ver-$REL → 저장소에 이미 있어 건너뜀"
      ls -1 "$OUT_DIR/$PKG-$ver-$REL".*.rpm | sed 's/^/    /'
    else
      log "1) 빌드: $PKG $ver-$REL"
      echo "    \$ sh build-rpm.sh $SPEC $TARGET_OS --define \"$VER_MACRO $ver\" --define \"rel $REL\""
      BUILD_MODE="${BUILD_MODE:-container}" OUT_DIR="$OUT_DIR" bash "$SCRIPT_DIR/build-rpm.sh" \
        "$SPEC" "$TARGET_OS" --define "$VER_MACRO $ver" --define "rel $REL"
    fi
  done
fi

for ver in "$OLD_VER" "$NEW_VER"; do
  ls "$OUT_DIR/$PKG-$ver"-*.rpm >/dev/null 2>&1 || die "저장소에 $PKG $ver RPM 이 없습니다: $OUT_DIR"
done

# ---------- 2~9) 컨테이너 안에서 실행할 검사 스크립트 ----------
# 공통 부분(검사 함수 + 2~5단계) + 제품별 test-inner.sh(6~9단계) + 결과
WORK_DIR="$BASE_DIR/_build/test-$TARGET_OS-$REPO_ID"
mkdir -p "$WORK_DIR"
{
cat <<'COMMON'
set -uo pipefail
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
PASS=0; FAIL=0; FAILED=()

# 명령 실행 (화면에 명령을 보여주고, 실패하면 실패로 기록)
run() {
  printf '\033[0;36m    $ %s\033[0m\n' "$*"
  if ! eval "$@"; then
    printf '\033[1;31m    [실패] %s\033[0m\n' "$*"
    FAIL=$((FAIL+1)); FAILED+=("$*")
    return 1
  fi
}

# 조건 검사 (출력은 숨기고, 실패하면 마지막 출력 일부를 보여줌)
check() {
  local desc="$1"; shift
  if out="$(eval "$@" 2>&1)"; then
    printf '\033[1;32m    [PASS] %s\033[0m\n' "$desc"; PASS=$((PASS+1))
  else
    printf '\033[1;31m    [FAIL] %s\033[0m\n' "$desc"
    [ -n "$out" ] && echo "$out" | tail -5 | sed 's/^/           /'
    FAIL=$((FAIL+1)); FAILED+=("$desc")
  fi
}

# 서비스 유닛의 ExecStartPre / ExecStart / User 그대로 실행 (컨테이너에는 systemd 가 없음)
#   start_unit <유닛 파일> <기동 확인 명령> <에러 로그> <대기 초>
#   systemd 처럼 $$ 를 $ 로 바꾸고, ExecStartPre 가 실패하면 기동하지 않는다.
#   Environment= 값(예: Environment="A=b c")도 같은 방식으로 전달한다.
SVC_PID=""
start_unit() {
  local unit="$1" ready="$2" errlog="$3" wait_sec="${4:-120}" exec_cmd user pre e envs=()
  exec_cmd="$(sed -n 's/^ExecStart=//p' "$unit")"
  user="$(sed -n 's/^User=//p' "$unit")"
  while IFS= read -r e; do
    e="${e#\"}"; e="${e%\"}"
    [ -n "$e" ] && envs+=("$e")
  done < <(sed -n 's/^Environment=//p' "$unit")
  while IFS= read -r pre; do
    [ -n "$pre" ] || continue
    pre="${pre//\$\$/\$}"
    printf '\033[0;36m    $ runuser -u %s -- %s\033[0m\n' "$user" "${pre:0:100}..."
    if ! runuser -u "$user" -- env ${envs[@]+"${envs[@]}"} bash -c "$pre"; then
      echo "    ExecStartPre 실패. 에러 로그:"
      tail -20 "$errlog" 2>/dev/null | sed 's/^/      /'
      return 1
    fi
  done < <(sed -n 's/^ExecStartPre=//p' "$unit")
  printf '\033[0;36m    $ runuser -u %s -- %s &\033[0m\n' "$user" "$exec_cmd"
  # shellcheck disable=SC2086
  runuser -u "$user" -- env ${envs[@]+"${envs[@]}"} $exec_cmd >/tmp/service.out 2>&1 &
  SVC_PID=$!
  for _ in $(seq 1 "$wait_sec"); do
    eval "$ready" >/dev/null 2>&1 && return 0
    kill -0 "$SVC_PID" 2>/dev/null || break
    sleep 1
  done
  echo "    서버 기동 실패. 에러 로그:"
  tail -20 "$errlog" 2>/dev/null | sed 's/^/      /'
  tail -5 /tmp/service.out 2>/dev/null | sed 's/^/      /'
  return 1
}
# 종료 명령을 보낸 뒤 서버 프로세스가 끝날 때까지 대기
wait_unit() { [ -n "$SVC_PID" ] && wait "$SVC_PID" 2>/dev/null; SVC_PID=""; }

# ---------- 준비 ----------
log "준비: 검사 도구 설치"
run "dnf -y -q install createrepo_c glibc-common util-linux >/dev/null"

# ---------- 2) 저장소 설정 ----------
log "2) 저장소 설정: /etc/yum.repos.d/$REPO_ID.repo"
cat > /etc/yum.repos.d/$REPO_ID.repo <<EOF
[$REPO_ID]
name=$REPO_NAME by DBA (test)
baseurl=file:///repo
enabled=1
gpgcheck=0
EOF
sed 's/^/    /' /etc/yum.repos.d/$REPO_ID.repo

# ---------- 3) 저장소 목록 갱신 ----------
log "3) 저장소 목록 갱신"
run "createrepo_c --update /repo"
check "repodata 생성됨" "[ -f /repo/repodata/repomd.xml ]"

# ---------- 4) 메타데이터 캐시 정리 ----------
log "4) 메타데이터 캐시 정리"
run "yum clean metadata --repo $REPO_ID"

# ---------- 5) 버전 선택 확인 ----------
log "5) 저장소 버전 목록"
run "yum list --showduplicates $PKG 2>/dev/null | grep -E '^$PKG\.' | sed 's/^/    /'"
check "저장소에 $OLD_VER 있음" "yum list --showduplicates $PKG 2>/dev/null | grep -E '^$PKG\.' | grep -q '2:$OLD_VER-.*$REPO_ID'"
check "저장소에 $NEW_VER 있음" "yum list --showduplicates $PKG 2>/dev/null | grep -E '^$PKG\.' | grep -q '2:$NEW_VER-.*$REPO_ID'"
check "버전 미지정 시 $REPO_ID 의 $NEW_VER 선택" \
  "[ \"\$(dnf repoquery -q --latest-limit 1 --arch \$(uname -m) --qf '%{repoid} %{version}' $PKG 2>/dev/null)\" = '$REPO_ID $NEW_VER' ]"

# ---------- 6~9) 제품별 검사 ----------
COMMON
cat "$TEST_INNER"
cat <<'RESULT'

# ---------- 결과 ----------
log "결과: PASS $PASS / FAIL $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '    실패 항목:\n'
  printf '      - %s\n' "${FAILED[@]}"
  exit 1
fi
printf '\033[1;32m    모든 검사 통과\033[0m\n'
RESULT
} > "$WORK_DIR/inner-test.sh"
# Windows 에서 편집한 경우 대비: CR 제거
sed -i 's/\r$//' "$WORK_DIR/inner-test.sh"

# ---------- 컨테이너 실행 ----------
CONTAINER_NAME="rpmtest-${TARGET_OS}-${REPO_ID}-$$"
RM_OPT=(--rm)
[ "${KEEP:-0}" = "1" ] && RM_OPT=()

PROXY_ENV=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  [ -n "${!v:-}" ] && PROXY_ENV+=(-e "$v=${!v}")
done

trap 'echo; docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; exit 130' INT TERM

log "컨테이너 검사 시작: $CONTAINER_NAME ($TEST_IMAGE)"
set +e
# 저장소 디렉터리는 쓰기 가능하게 연결 (createrepo_c --update 가 repodata 를 갱신)
docker run ${RM_OPT[@]+"${RM_OPT[@]}"} --name "$CONTAINER_NAME" \
  -v "$OUT_DIR":/repo:z \
  -v "$WORK_DIR/inner-test.sh":/work/inner-test.sh:ro,z \
  -e OLD_VER="$OLD_VER" -e NEW_VER="$NEW_VER" -e REPO_ID="$REPO_ID" -e REL="$REL" \
  -e PKG="$PKG" -e REPO_NAME="${REPO_NAME:-$REPO_ID}" -e TARGET_OS="$TARGET_OS" \
  ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
  "$TEST_IMAGE" bash /work/inner-test.sh
rc=$?
set -e
trap - INT TERM

if [ "${KEEP:-0}" = "1" ]; then
  echo
  echo "    컨테이너를 남겨두었습니다 (종료 상태). 안을 확인하려면:"
  echo "      docker commit $CONTAINER_NAME rpmtest:debug"
  echo "      docker run -it --rm -v $OUT_DIR:/repo:z rpmtest:debug bash"
  echo "    정리:"
  echo "      docker rm $CONTAINER_NAME && docker image rm rpmtest:debug"
fi

[ "$rc" -eq 0 ] && ok "검사 성공" || die "검사 실패 (위 [FAIL] 항목 확인)"
