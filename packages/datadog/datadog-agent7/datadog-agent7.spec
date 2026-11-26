# datadog-agent: Datadog Agent 7 공식 RPM → 사내 RPM (재패키징)
#
#   이름     : datadog-agent         (공식 패키지와 같은 이름: 벤더 installer 가 이 이름으로 동작)
#   Epoch    : 2      → 사내 패키지 규칙. 공식 패키지(Epoch 1)보다 항상 우선
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (datadog-agent7)
#
# 재패키징 방식
#   공식 RPM(yum.datadoghq.com)의 파일·권한·설치 스크립트를 그대로 옮기고
#   이름/버전 규칙(Epoch, Release)만 사내 규칙으로 바꾼다.
#   - 설치 스크립트(%pre, %preun, %posttrans)는 공식 RPM 에서 추출해 그대로 사용
#     (계정 dd-agent 생성, systemd 유닛 설치, 권한 설정은 벤더 installer 가 수행)
#   - 의존성/충돌도 공식 RPM 과 동일
#
# 설정 (패키지에 포함하지 않음)
#   /etc/datadog-agent/datadog.yaml 은 서버에서 직접 작성한다 (api_key, site 등).
#     cp /etc/datadog-agent/datadog.yaml.example /etc/datadog-agent/datadog.yaml
#     chown dd-agent:dd-agent /etc/datadog-agent/datadog.yaml; chmod 640 /etc/datadog-agent/datadog.yaml
#   패키지 파일이 아니므로 업데이트/삭제 시에도 그대로 남는다.
#
# 설치 후 사용 순서:
#   yum install datadog-agent
#   (datadog.yaml 작성)
#   systemctl enable --now datadog-agent
#   datadog-agent status
#
# 빌드:
#   sh build-rpm.sh packages/datadog/datadog-agent7/datadog-agent7.spec al2023                               → 7.86.0-1.DBA
#   sh build-rpm.sh packages/datadog/datadog-agent7/datadog-agent7.spec al2023 --define "dd_ver 7.85.5"      → 7.85.5-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?dd_ver:%global dd_ver 7.86.0}
%{!?dd_vendor_rel:%global dd_vendor_rel 1}
%{!?rel:%global rel 1}
%global major      7
%global vendor_rpm datadog-agent-%{dd_ver}-%{dd_vendor_rel}.%{_arch}.rpm

# --- 미리 빌드된 패키지 그대로 옮김 ---
%global debug_package       %{nil}
# strip, bytecompile, buildroot 경로 검사 등 후처리 안 함 (벤더 파일 그대로 유지)
%global __os_install_post   %{nil}
%global __arch_install_post %{nil}
%global _binary_payload     w3.zstdio
%global _build_id_links     none
# 공식 RPM 과 같이 자동 의존성/Provides 생성 안 함
AutoReqProv:    no

Name:           datadog-agent
Epoch:          2
Version:        %{dd_ver}
Release:        %{rel}%{?dist}
Summary:        Datadog Agent (repackaged from the official RPM)
License:        Apache-2.0
URL:            https://docs.datadoghq.com/agent/
Source0:        https://yum.datadoghq.com/stable/%{major}/%{_arch}/%{vendor_rpm}
ExclusiveArch:  x86_64 aarch64
BuildRequires:  cpio

# 공식 RPM 과 같은 의존성/충돌
Requires(pre):  shadow-utils
Requires:       coreutils findutils glibc-common grep shadow-utils
Conflicts:      datadog-iot-agent

%description
Datadog Agent %{dd_ver}, repackaged from the official RPM (%{vendor_rpm})
with the company versioning rules. Files and install scripts are unchanged.
Configuration (/etc/datadog-agent/datadog.yaml) is not included.

%prep
%setup -q -c -T
# 원본 RPM 의 이름/버전 확인 (다른 파일이 섞이는 것 방지)
[ "$(rpm -qp --qf '%%{NAME} %%{VERSION}' %{SOURCE0} 2>/dev/null)" = "datadog-agent %{dd_ver}" ] \
  || { echo "원본 RPM 이 datadog-agent %{dd_ver} 가 아닙니다: %{SOURCE0}" >&2; exit 1; }

# 설치 스크립트 추출 (아래 %%pre -f 등으로 그대로 사용)
for t in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS; do
  rpm -qp --qf "%%{$t}" %{SOURCE0} 2>/dev/null > script-$t.sh
  [ "$(cat script-$t.sh)" = "(none)" ] && : > script-$t.sh
done
# 공식 RPM 에 없는 단계가 생기면(벤더 변경) 이 spec 도 함께 고쳐야 하므로 빌드 중단
for t in POSTIN POSTUN PRETRANS; do
  [ ! -s script-$t.sh ] || { echo "공식 RPM 에 $t 스크립트가 새로 생겼습니다. spec 을 확인하세요." >&2; exit 1; }
done

# 파일 목록 + 권한 (파일 종류, 권한, 이름) → %%files 목록
#   (파일 이름에 공백이 있을 수 있어 따옴표로 감쌈. 링크는 권한 지정 없이)
#   파일이 1만 개가 넘으므로 이 구간은 명령 출력(set -x)을 끈다
{ set +x; } 2>/dev/null
rpm -qp --qf '[%%{FILEMODES} %%{FILENAMES}\n]' %{SOURCE0} 2>/dev/null | while read -r mode path; do
  type=$(( mode & 0170000 ))
  perm=$(printf '%%04o' $(( mode & 07777 )))
  if [ "$type" -eq $(( 0040000 )) ]; then
    printf '%%%%dir %%%%attr(%%s,root,root) "%%s"\n' "$perm" "$path"
  elif [ "$type" -eq $(( 0120000 )) ]; then
    printf '"%%s"\n' "$path"
  else
    printf '%%%%attr(%%s,root,root) "%%s"\n' "$perm" "$path"
  fi
done > files.list
echo "파일 목록: $(wc -l < files.list) 개"
set -x
# 공식 RPM 은 모든 파일이 root 소유: 다르면 위 목록 생성 방식을 고쳐야 함
[ -z "$(rpm -qp --qf '[%%{FILEUSERNAME}:%%{FILEGROUPNAME}\n]' %{SOURCE0} 2>/dev/null | grep -v '^root:root$')" ] \
  || { echo "공식 RPM 에 root 가 아닌 소유자가 있습니다. spec 을 확인하세요." >&2; exit 1; }

%build
# 미리 빌드된 패키지이므로 빌드 단계 없음

%install
mkdir -p %{buildroot}
cd %{buildroot}
rpm2cpio %{SOURCE0} | cpio -idm --quiet

%pre -f script-PREIN.sh
%preun -f script-PREUN.sh
%posttrans -f script-POSTTRANS.sh

%files -f files.list
