#!/usr/bin/env bash
# =============================================================================
# build-rpm.sh : spec 파일 하나로 RPM을 빌드한다.
#
# 사용법:
#   sh build-rpm.sh <spec 파일> <el9|al2023> [rpmbuild 옵션...]
#   (spec 폴더의 다른 파일과, 같은 제품의 ../common 폴더 파일을 빌드 재료로 사용)
#
# 예:
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023
#   sh build-rpm.sh packages/mongodb/mongodb83/mongodb83.spec al2023
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13"
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13" --define "rel 2"
#   BUILD_MODE=container sh build-rpm.sh packages/mysql/mysql84/mysql84.spec el9
#
# 릴리스 태그 (DIST_TAG):
#   기본값 .DBA → mysql-8.4.6-1.DBA.x86_64.rpm
#   DIST_TAG=.DBA.el9 처럼 바꾸거나, DIST_TAG= (빈 값)으로 OS 기본값(.el9) 사용
#
# 빌드 방식 (BUILD_MODE):
#   auto       이 서버 OS == 대상 OS 이면 local, 다르면 container (기본값)
#   local      이 서버에서 직접 빌드
#   container  docker(없으면 podman) 컨테이너에서 빌드 ← 정식 배포용 권장
#
# 컨테이너 빌드 옵션 (환경변수):
#   CONTAINER_RUNTIME=docker|podman  사용할 런타임 (기본: docker, 없으면 podman)
#   BASE_IMAGE=<이미지>              기반 OS 이미지 (사내 레지스트리 사용 시 지정)
#                                      기본: el9    → rockylinux/rockylinux:9
#                                            al2023 → amazonlinux:2023
#   REBUILD_IMAGE=1                  빌더 이미지를 강제로 다시 생성
#   IMAGE_MAX_AGE_DAYS=7             빌더 이미지가 이 일수보다 오래되면 자동 재생성
#                                      (OS 보안 업데이트 반영)
#
# 빌드 후 정리 (OUT_DIR을 yum 저장소로 사용):
#   - 빌드한 모든 버전의 RPM을 보관 (yum install mysql-<버전> 으로 선택 설치 가능)
#   - 저장소에 같은 버전-릴리스가 이미 있으면 빌드 전에 중단하고 다음 Release 번호를 안내
#     (공개된 RPM 덮어쓰기 방지, 꼭 덮어써야 하면 OVERWRITE=1)
#     PRUNE_OLD=1 로 실행하면 같은 패키지의 옛 버전을 지우고 최신 하나만 남김
#   - createrepo_c 로 저장소 목록(repodata) 자동 갱신
#
# 디렉터리 (현재 위치 기준, 환경변수로 변경 가능):
#   SRC_DIR  = ./sources        원본 tarball 보관
#   OUT_DIR  = ./dist/<os>/<저장소 ID>   결과 RPM (저장소 ID = spec 폴더 이름, 예: dist/al2023/mysql84)
#   WORK_DIR = ./_build/<os>    빌드 작업 공간 (매번 초기화)
# =============================================================================

# sh(dash 등)로 실행해도 bash로 다시 실행
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

# ---------- 공통 함수 ----------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    [OK] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    [주의] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[오류] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR>=3 && /^# =+$/ {exit} NR>=3 {sub(/^# ?/, ""); print}' "$0"
  exit 1
}

# ---------- 인자 확인 ----------
[ $# -ge 2 ] || usage
SPEC_ARG="$1"; TARGET_OS="$2"; shift 2
EXTRA_ARGS=("$@")

# 사내 릴리스 태그: spec의 %{?dist} 를 .DBA 로 바꿈 (명시적으로 빈 값이면 OS 기본값 사용)
DIST_TAG="${DIST_TAG-.DBA}"
if [ -n "$DIST_TAG" ]; then
  EXTRA_ARGS=(--define "dist $DIST_TAG" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
fi

[ -f "$SPEC_ARG" ] || die "spec 파일이 없습니다: $SPEC_ARG"
case "$TARGET_OS" in
  el9)    DEFAULT_BASE_IMAGE="rockylinux/rockylinux:9" ;;
  al2023) DEFAULT_BASE_IMAGE="amazonlinux:2023" ;;
  *)      die "대상 OS는 el9 또는 al2023 이어야 합니다: $TARGET_OS" ;;
esac
BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}"
BUILDER_IMAGE="${BUILDER_IMAGE:-rpmbuilder:$TARGET_OS}"
IMAGE_MAX_AGE_DAYS="${IMAGE_MAX_AGE_DAYS:-7}"
DNF_CACHE_VOLUME="rpmbuild-dnfcache-$TARGET_OS"

BASE_DIR="$(pwd)"
SPEC="$(readlink -f "$SPEC_ARG")"
SPEC_DIR="$(dirname "$SPEC")"
SPEC_NAME="$(basename "$SPEC")"
SRC_DIR="$(mkdir -p "${SRC_DIR:-$BASE_DIR/sources}" && readlink -f "${SRC_DIR:-$BASE_DIR/sources}")"
# 저장소는 spec 폴더 이름(= 저장소 ID, 예: mysql84) 별로 분리: dist/<os>/<저장소 ID>
REPO_ID="$(basename "$SPEC_DIR")"
# 같은 제품의 공통 파일 폴더 (예: packages/mysql/common): 있으면 빌드 재료로 함께 사용
COMMON_DIR=""
[ -d "$SPEC_DIR/../common" ] && COMMON_DIR="$(readlink -f "$SPEC_DIR/../common")"
OUT_DIR="$(mkdir -p "${OUT_DIR:-$BASE_DIR/dist/$TARGET_OS/$REPO_ID}" && readlink -f "${OUT_DIR:-$BASE_DIR/dist/$TARGET_OS/$REPO_ID}")"
WORK_DIR="${WORK_DIR:-$BASE_DIR/_build/$TARGET_OS}"

# ---------- 이 서버의 OS 판별 ----------
detect_host_os() {
  [ -r /etc/os-release ] || { echo unknown; return; }
  # shellcheck disable=SC1091
  . /etc/os-release
  local major="${VERSION_ID%%.*}"
  case "${ID:-}" in
    amzn)                            [ "$major" = "2023" ] && { echo al2023; return; } ;;
    rhel|rocky|almalinux|centos|ol)  [ "$major" = "9" ]    && { echo el9;    return; } ;;
  esac
  echo unknown
}
HOST_OS="$(detect_host_os)"

# ---------- 빌드 방식 결정 ----------
MODE="${BUILD_MODE:-auto}"
case "$MODE" in
  auto)            if [ "$HOST_OS" = "$TARGET_OS" ]; then MODE=local; else MODE=container; fi ;;
  local|container) ;;
  *)               die "BUILD_MODE는 auto, local, container 중 하나여야 합니다: $MODE" ;;
esac

# ---------- 컨테이너 런타임 선택 및 점검 ----------
RUNTIME=""
if [ "$MODE" = "container" ]; then
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 \
      || die "CONTAINER_RUNTIME=$CONTAINER_RUNTIME 이(가) 설치되어 있지 않습니다."
    RUNTIME="$CONTAINER_RUNTIME"
  elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
  else
    die "컨테이너 빌드에 docker 또는 podman이 필요합니다.
       → docker 설치 후 'systemctl enable --now docker' 로 시작하거나,
         간단히 'dnf install -y podman' 을 설치하세요."
  fi

  if ! "$RUNTIME" info >/dev/null 2>&1; then
    if [ "$RUNTIME" = "docker" ]; then
      die "docker를 사용할 수 없습니다 (데몬이 꺼져 있거나 권한 부족).
       → 'systemctl start docker' 로 데몬을 시작하거나,
         root가 아니면 docker 그룹에 추가: 'usermod -aG docker \$USER' 후 재로그인"
    else
      die "$RUNTIME 를 사용할 수 없습니다. '$RUNTIME info' 로 상태를 확인하세요."
    fi
  fi
fi

# 사내 프록시 환경이면 컨테이너에도 그대로 전달
PROXY_ENV=(); PROXY_BUILD_ARGS=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ -n "${!v:-}" ]; then
    PROXY_ENV+=(-e "$v=${!v}")
    PROXY_BUILD_ARGS+=(--build-arg "$v=${!v}")
  fi
done

log "빌드 설정"
echo "    spec        : $SPEC"
echo "    대상 OS     : $TARGET_OS   (이 서버: $HOST_OS)"
echo "    빌드 방식   : $MODE"
echo "    릴리스 태그 : ${DIST_TAG:-(OS 기본값)}"
if [ "$MODE" = "container" ]; then
  echo "    런타임      : $RUNTIME"
  echo "    기반 이미지 : $BASE_IMAGE"
  echo "    빌더 이미지 : $BUILDER_IMAGE"
fi
echo "    원본 보관   : $SRC_DIR"
echo "    결과 RPM    : $OUT_DIR"
[ ${#EXTRA_ARGS[@]} -gt 0 ] && echo "    추가 옵션   : ${EXTRA_ARGS[*]}"

# ---------- 작업 공간 준비 ----------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ---------- 실제 빌드 스크립트 (로컬/컨테이너 공용) ----------
# 환경변수: SPEC, SPEC_DIR, SRC_DIR, OUT_DIR, TOPDIR, IN_CONTAINER, HOST_UID, HOST_GID
cat > "$WORK_DIR/inner-build.sh" <<'INNER'
set -euo pipefail
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    [OK] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    [주의] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[오류] %s\033[0m\n' "$*" >&2; exit 1; }

# 컨테이너가 만든 파일(결과 RPM, 다운로드한 원본)의 소유자를 실행한 사용자로 되돌림
fix_owner() {
  if [ "${IN_CONTAINER:-0}" = "1" ] && [ -n "${HOST_UID:-}" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$OUT_DIR" "$SRC_DIR" 2>/dev/null || true
  fi
}
trap fix_owner EXIT

# 1) 필요한 도구 설치 (빌더 이미지에는 이미 들어 있으므로 보통 건너뜀)
log "빌드 도구 확인"
NEED=()
command -v rpmbuild >/dev/null 2>&1 || NEED+=(rpm-build)
command -v curl     >/dev/null 2>&1 || NEED+=(curl)
command -v xz       >/dev/null 2>&1 || NEED+=(xz)
command -v tar      >/dev/null 2>&1 || NEED+=(tar)
# %{_unitdir} 매크로가 정의되어 있지 않으면 systemd-rpm-macros 필요
[ "$(rpm --eval '%{_unitdir}' 2>/dev/null)" != '%{_unitdir}' ] || NEED+=(systemd-rpm-macros)
if [ ${#NEED[@]} -gt 0 ]; then
  command -v dnf >/dev/null 2>&1 || die "다음 도구가 필요합니다: ${NEED[*]}"
  [ "$(id -u)" -eq 0 ] || die "도구 설치에 root 권한이 필요합니다: ${NEED[*]}"
  echo "    설치: ${NEED[*]}"
  dnf -y -q install "${NEED[@]}" >/dev/null
fi
ok "rpmbuild $(rpmbuild --version | awk '{print $3}')"
[ "${IN_CONTAINER:-0}" = "1" ] && ok "컨테이너 OS: $(. /etc/os-release; echo "$PRETTY_NAME")"

# 2) rpmbuild 디렉터리
mkdir -p "$TOPDIR"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

# spec 디렉터리의 부속 파일(유닛 파일 등)을 SOURCES로 복사
# 같은 제품의 공통 파일(../common)을 먼저 복사하고, spec 폴더의 같은 이름 파일이 있으면 그것으로 덮어씀
if [ -n "${COMMON_DIR:-}" ] && [ -d "$COMMON_DIR" ]; then
  find "$COMMON_DIR" -maxdepth 1 -type f ! -name '*.spec' -exec cp -f {} "$TOPDIR/SOURCES/" \;
fi
find "$SPEC_DIR" -maxdepth 1 -type f ! -name '*.spec' -exec cp -f {} "$TOPDIR/SOURCES/" \;

# 3) Source 파일 확보
log "원본(Source) 파일 확인"
mapfile -t SRC_LIST < <(rpmspec -P "$SPEC" "$@" 2>/dev/null \
                        | awk 'tolower($1) ~ /^(source|patch)[0-9]*:$/ {print $2}')
[ ${#SRC_LIST[@]} -gt 0 ] || die "spec에서 Source를 읽지 못했습니다. 'rpmspec -P $SPEC' 로 확인하세요."

for src in "${SRC_LIST[@]}"; do
  name="$(basename "$src")"
  if [ -f "$TOPDIR/SOURCES/$name" ]; then
    ok "$name (spec 디렉터리)"
  elif [ -f "$SRC_DIR/$name" ]; then
    cp -f "$SRC_DIR/$name" "$TOPDIR/SOURCES/"
    ok "$name (원본 보관소)"
  elif [[ "$src" =~ ^(https?|ftp):// ]]; then
    echo "    다운로드: $src"
    if curl -fL --retry 3 --progress-bar -o "$SRC_DIR/$name.part" "$src"; then
      mv -f "$SRC_DIR/$name.part" "$SRC_DIR/$name"
      cp -f "$SRC_DIR/$name" "$TOPDIR/SOURCES/"
      ok "$name (다운로드, $(du -h "$SRC_DIR/$name" | cut -f1))"
    else
      rm -f "$SRC_DIR/$name.part"
      die "다운로드 실패: $src
       → 파일을 직접 받아 원본 보관소에 넣고 다시 실행하세요."
    fi
  else
    die "원본 파일이 없습니다: $name
       → 파일을 원본 보관소에 넣거나, spec의 Source를 다운로드 URL로 지정하세요."
  fi
done

# 4) BuildRequires 설치 (있을 때만)
if [ -n "$(rpmspec -q --buildrequires "$SPEC" "$@" 2>/dev/null)" ]; then
  log "BuildRequires 설치"
  if ! dnf builddep --help >/dev/null 2>&1; then
    dnf -y -q install dnf-plugins-core >/dev/null
  fi
  dnf -y -q builddep "$SPEC" "$@" >/dev/null
  ok "완료"
fi

# 4-1) 저장소에 같은 버전-릴리스가 이미 있으면 빌드 중단 (공개된 RPM 덮어쓰기 방지)
if [ "${OVERWRITE:-0}" != "1" ]; then
  mapfile -t EXPECT < <(rpmspec -q --qf '%{name}-%{version}-%{release}.%{arch}.rpm\n' "$SPEC" "$@" 2>/dev/null)
  for f in "${EXPECT[@]}"; do
    [ -f "$OUT_DIR/$f" ] || continue
    read -r pname pver < <(rpmspec -q --srpm --qf '%{name} %{version}\n' "$SPEC" "$@" 2>/dev/null)
    maxrel=0
    for e in "$OUT_DIR/$pname-$pver-"*.rpm; do
      [ -e "$e" ] || continue
      r="$(rpm -qp --qf '%{RELEASE}' "$e" 2>/dev/null)"; r="${r%%.*}"
      if [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt "$maxrel" ]; then maxrel="$r"; fi
    done
    die "저장소에 이미 같은 버전-릴리스가 있습니다: $f
       → Release 를 올려서 빌드하세요: --define \"rel $((maxrel+1))\"
         (같은 파일을 덮어쓰려면 OVERWRITE=1, 이미 설치한 서버가 있다면 권장하지 않음)"
  done
fi

# 5) 빌드
log "rpmbuild 실행"
rpmbuild -bb --define "_topdir $TOPDIR" "$@" "$SPEC"

mkdir -p "$OUT_DIR"
# 결과 RPM은 아래 검사를 통과한 경우에만 저장소(OUT_DIR)로 복사한다

# 6) 결과 검사
for rpm_file in $(find "$TOPDIR/RPMS" -name '*.rpm'); do
  name="$(basename "$rpm_file")"
  log "결과 검사: $name"
  echo "    크기     : $(du -h "$rpm_file" | cut -f1)"
  echo "    파일 수  : $(rpm -qlp "$rpm_file" 2>/dev/null | wc -l)"
  echo "    Requires :"
  rpm -qp --requires "$rpm_file" 2>/dev/null | grep -v '^rpmlib(' | sort -u | sed 's/^/      - /'

  # 설치 스크립트(%pre, %post 등) 문법 검사: 오류가 있으면 설치 단계에서 실패하므로 빌드에서 차단
  script_err=0
  for tag in PRETRANS PREIN POSTIN PREUN POSTUN POSTTRANS; do
    body="$(rpm -qp --qf "%{$tag}" "$rpm_file" 2>/dev/null)"
    [ -n "$body" ] && [ "$body" != "(none)" ] || continue
    if ! errmsg="$(printf '%s\n' "$body" | bash -n 2>&1)"; then
      warn "설치 스크립트 문법 오류: $tag"
      echo "$errmsg" | sed 's/^bash: /      /'
      script_err=1
    fi
  done
  if [ "$script_err" -eq 0 ]; then
    ok "설치 스크립트 문법 정상"
    cp -f "$rpm_file" "$OUT_DIR/"
    ok "저장소에 추가: $OUT_DIR/$name"
  else
    die "설치 스크립트에 문법 오류가 있어 RPM을 저장소에 넣지 않았습니다: $name
       → spec 의 해당 섹션을 수정하고 Release 를 올려 다시 빌드하세요.
         확인: rpm -qp --scripts $rpm_file"
  fi

  # 설치 가능 여부: 실제 설치하지 않고 의존성만 확인
  # (컨테이너에서는 추가 저장소가 없는 깨끗한 OS 기준으로 검사됨)
  if command -v dnf >/dev/null 2>&1; then
    out="$(dnf install --assumeno "$rpm_file" 2>&1 || true)"
    if echo "$out" | grep -qiE 'nothing provides|problem:|conflicts with'; then
      warn "의존성 문제가 있어 이 상태로는 설치되지 않습니다:"
      echo "$out" | grep -iE 'nothing provides|problem|conflict' | sed 's/^/      /'
      # 설치할 수 없는 RPM 이 저장소에 들어가지 않도록 위에서 복사한 파일을 지우고 중단
      rm -f "$OUT_DIR/$name"
      die "설치할 수 없는 RPM 이라 저장소에 넣지 않았습니다: $name
       → 번들 라이브러리라면 spec 의 __requires_exclude 에 추가하고, OS 패키지가 필요하면 Requires 를 확인하세요."
    else
      ok "의존성 해결 가능 (설치 가능)"
    fi
  fi
done
INNER

# ---------- 빌더 이미지 준비 (컨테이너 빌드) ----------
# 기반 OS 이미지에 빌드 도구를 미리 설치한 이미지를 만들어 재사용한다.
# → 매번 rpm-build를 설치하지 않아 빠르고, 일정 기간이 지나면 자동으로 새로 만들어
#   OS 보안 업데이트를 반영한다.
ensure_builder_image() {
  local need=0 reason="" built age

  if [ "${REBUILD_IMAGE:-0}" = "1" ]; then
    need=1; reason="REBUILD_IMAGE=1"
  elif ! "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    need=1; reason="이미지 없음, 최초 생성"
  else
    built="$("$RUNTIME" image inspect -f '{{ index .Config.Labels "rpmbuilder.built-epoch" }}' "$BUILDER_IMAGE" 2>/dev/null || true)"
    [[ "$built" =~ ^[0-9]+$ ]] || built=0
    age=$(( ( $(date +%s) - built ) / 86400 ))
    if [ "$age" -ge "$IMAGE_MAX_AGE_DAYS" ]; then
      need=1; reason="생성 후 ${age}일 경과"
    fi
  fi

  if [ "$need" -eq 0 ]; then
    ok "빌더 이미지 재사용: $BUILDER_IMAGE (생성 후 ${age}일)"
    return
  fi

  log "빌더 이미지 생성: $BUILDER_IMAGE ($reason)"
  local ctx="$WORK_DIR/image"
  mkdir -p "$ctx"
  cat > "$ctx/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG BUILT_EPOCH=0
RUN set -eux; \
    dnf -y install rpm-build dnf-plugins-core systemd-rpm-macros \
                   xz tar gzip bzip2 findutils; \
    command -v curl >/dev/null || dnf -y install curl-minimal; \
    if [ -f /etc/rocky-release ]; then dnf config-manager --set-enabled crb; fi; \
    dnf -y upgrade; \
    echo 'keepcache=1' >> /etc/dnf/dnf.conf; \
    dnf clean all
LABEL rpmbuilder.built-epoch="${BUILT_EPOCH}" \
      rpmbuilder.base-image="${BASE_IMAGE}" \
      rpmbuilder.purpose="rpmbuild"
DOCKERFILE

  "$RUNTIME" build --pull \
    -t "$BUILDER_IMAGE" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg BUILT_EPOCH="$(date +%s)" \
    ${PROXY_BUILD_ARGS[@]+"${PROXY_BUILD_ARGS[@]}"} \
    "$ctx" \
    || die "빌더 이미지 생성 실패.
       → 기반 이미지($BASE_IMAGE)를 받을 수 없다면 사내 레지스트리 이미지를 지정하세요:
         BASE_IMAGE=<사내레지스트리>/rockylinux:9 sh build-rpm.sh ..."
  ok "빌더 이미지 생성 완료"
}

# ---------- 실행 ----------
if [ "$MODE" = "local" ]; then
  SPEC="$SPEC" SPEC_DIR="$SPEC_DIR" COMMON_DIR="$COMMON_DIR" SRC_DIR="$SRC_DIR" OUT_DIR="$OUT_DIR" \
  TOPDIR="$WORK_DIR/rpmbuild" IN_CONTAINER=0 \
    bash "$WORK_DIR/inner-build.sh" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
else
  log "빌더 이미지 확인"
  ensure_builder_image

  CONTAINER_NAME="rpmbuild-${TARGET_OS}-$$"
  cleanup_container() { "$RUNTIME" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
  # Ctrl+C 시 컨테이너가 백그라운드에 남지 않도록 정리
  trap 'echo; warn "중단됨: 컨테이너($CONTAINER_NAME) 정리"; cleanup_container; exit 130' INT TERM

  # 터미널에서 실행하면 진행 표시와 Ctrl+C가 정상 동작하도록 TTY 연결
  TTY_OPT=()
  if [ -t 0 ] && [ -t 1 ]; then TTY_OPT=(-it); fi

  # docker는 root로 파일을 만들므로 일반 사용자로 실행했다면 소유자를 되돌림
  # (rootless podman은 사용자 매핑이 자동이므로 필요 없음)
  OWNER_ENV=()
  if [ "$RUNTIME" = "docker" ] && [ "$(id -u)" -ne 0 ]; then
    OWNER_ENV=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)")
  fi

  COMMON_OPT=()
  [ -n "$COMMON_DIR" ] && COMMON_OPT=(-v "$COMMON_DIR":/work/common:ro,z -e COMMON_DIR=/work/common)

  log "컨테이너 빌드 시작: $CONTAINER_NAME"
  # :z → SELinux 호스트에서 볼륨 접근 허용 (SELinux가 꺼져 있으면 무시됨)
  # dnf 캐시 볼륨 → BuildRequires 패키지를 매번 다시 받지 않음
  "$RUNTIME" run --rm --init --name "$CONTAINER_NAME" \
    ${TTY_OPT[@]+"${TTY_OPT[@]}"} \
    -v "$SPEC_DIR":/work/spec:ro,z \
    -v "$SRC_DIR":/work/sources:z \
    -v "$OUT_DIR":/work/out:z \
    -v "$WORK_DIR/inner-build.sh":/work/inner-build.sh:ro,z \
    -v "$DNF_CACHE_VOLUME":/var/cache/dnf \
    -e SPEC="/work/spec/$SPEC_NAME" \
    -e SPEC_DIR=/work/spec \
    -e SRC_DIR=/work/sources \
    -e OUT_DIR=/work/out \
    -e TOPDIR=/root/rpmbuild \
    -e IN_CONTAINER=1 \
    -e OVERWRITE="${OVERWRITE:-0}" \
    ${COMMON_OPT[@]+"${COMMON_OPT[@]}"} \
    ${OWNER_ENV[@]+"${OWNER_ENV[@]}"} \
    ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
    "$BUILDER_IMAGE" bash /work/inner-build.sh ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

  trap - INT TERM
fi

# ---------- 옛 버전 정리 (PRUNE_OLD=1 일 때만): 패키지별 최신 버전 하나만 남김 ----------
# 기본 정책: 모든 버전 보관
if [ "${PRUNE_OLD:-0}" = "1" ]; then
  log "옛 버전 RPM 정리 (최신 버전만 유지)"
  if python3 -c 'import rpm' >/dev/null 2>&1; then
    python3 - "$OUT_DIR" <<'PY'
import functools, os, sys, rpm
d = sys.argv[1]
ts = rpm.TransactionSet()
ts.setVSFlags(-1)          # 서명/다이제스트 검사 생략 (이름·버전만 읽음)
groups = {}
for f in sorted(os.listdir(d)):
    if not f.endswith(".rpm"):
        continue
    p = os.path.join(d, f)
    with open(p, "rb") as fh:
        h = ts.hdrFromFdno(fh.fileno())
    def s(v): return v.decode() if isinstance(v, bytes) else (str(v) if v is not None else None)
    key = (s(h["name"]), s(h["arch"]))
    evr = (s(h["epoch"]) or "0", s(h["version"]), s(h["release"]))
    groups.setdefault(key, []).append((evr, f))
removed = 0
for key, items in groups.items():
    items.sort(key=functools.cmp_to_key(lambda a, b: rpm.labelCompare(a[0], b[0])))
    keep = items[-1][1]
    for _, f in items[:-1]:
        os.remove(os.path.join(d, f))
        print(f"    삭제: {f}")
        removed += 1
    print(f"    유지: {keep}")
if removed == 0:
    print("    삭제할 옛 버전 없음")
PY
  else
    warn "python3-rpm 이 없어 옛 버전 정리를 건너뜁니다 ('dnf install -y python3-rpm')"
  fi
fi

if [ "${PRUNE_OLD:-0}" != "1" ]; then
  log "저장소 보관 현황 (모든 버전 보관)"
  for f in "$OUT_DIR"/*.rpm; do
    [ -e "$f" ] || continue
    rpm -qp --qf '%{NAME}  %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$f" 2>/dev/null
  done | sort -V | sed 's/^/    /'
  echo "    합계: $(ls "$OUT_DIR"/*.rpm 2>/dev/null | wc -l)개, $(du -ch "$OUT_DIR"/*.rpm 2>/dev/null | tail -1 | cut -f1)"
fi

# ---------- 저장소 목록(repodata) 갱신 ----------
log "저장소 목록 갱신"
if ! command -v createrepo_c >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    echo "    설치: createrepo_c"
    dnf -y -q install createrepo_c >/dev/null
  fi
fi
if command -v createrepo_c >/dev/null 2>&1; then
  createrepo_c --update -q "$OUT_DIR"
  ok "repodata 갱신 완료: $OUT_DIR/repodata"
else
  warn "createrepo_c 가 없어 저장소 목록을 갱신하지 못했습니다 ('dnf install -y createrepo_c')"
fi

# ---------- 마무리 ----------
log "완료"
ls -lh "$OUT_DIR"/*.rpm 2>/dev/null | awk '{print "    " $5 "  " $9}' \
  || warn "결과 RPM이 없습니다."
cat <<EOF

    다음 단계 (이 저장소를 쓰는 서버):
      dnf clean metadata --repo <저장소ID>     # 예: mysql84
      yum install <패키지명>  /  yum update <패키지명>
      rpm -qi <패키지명>           # 패키지 정보
      rpm -ql <패키지명> | head    # 설치된 파일
EOF
if [ "$MODE" = "container" ]; then
cat <<EOF

    컨테이너 정리 (필요 시):
      $RUNTIME image rm $BUILDER_IMAGE          # 빌더 이미지 삭제
      $RUNTIME volume rm $DNF_CACHE_VOLUME   # dnf 캐시 삭제
EOF
fi
