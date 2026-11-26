# mongodb-tools: MongoDB Database Tools 100.x OS별 tarball → 사내 RPM
#
#   이름     : mongodb-tools
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb, mongosh 와 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mongodb-tools100)
#
# 구성
#   바이너리 : /opt/mongodb-tools/bin     (경로에 버전 없음, 업그레이드 시 제자리 교체)
#   명령어   : /usr/local/bin/mongodump, mongorestore, mongoexport, mongoimport,
#              mongostat, mongotop, mongofiles, bsondump   (패키지가 링크를 직접 소유)
#   서버(mongodb 패키지)와 독립: 100.x 는 지원되는 모든 서버 버전에서 사용 가능.
#
# 빌드 (대상 OS 에 맞는 tarball 을 자동 선택):
#   sh build-rpm.sh packages/mongodb/mongodb-tools100/mongodb-tools100.spec al2023                                → 100.20.1-1.DBA
#   sh build-rpm.sh packages/mongodb/mongodb-tools100/mongodb-tools100.spec al2023 --define "tools_ver 100.20.0"  → 100.20.0-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?tools_ver:%global tools_ver 100.20.1}
%{!?rel:%global rel 1}
%global major      100
%global prefix_dir /opt/mongodb-tools

# 대상 OS 별 tarball 이름 (빌드하는 OS 의 매크로로 판단)
%if 0%{?amzn} == 2023
%global tools_os   amazon2023
%else
%if 0%{?rhel} == 9
%global tools_os   rhel93
%endif
%endif
%{!?tools_os:%{error:지원하지 않는 대상 OS 입니다 (al2023, el9 만 지원)}}
%global tarname    mongodb-database-tools-%{tools_os}-%{_arch}-%{tools_ver}

# --- 미리 빌드된 바이너리 처리 ---
%global debug_package     %{nil}
%global __os_install_post %{nil}
%global _binary_payload   w3.zstdio
%global _build_id_links   none
%global __provides_exclude_from ^%{prefix_dir}/.*$

Name:           mongodb-tools
Epoch:          2
Version:        %{tools_ver}
Release:        %{rel}%{?dist}
Summary:        MongoDB Database Tools (mongodump, mongorestore, ...)
License:        Apache-2.0
URL:            https://www.mongodb.com/try/download/database-tools
Source0:        https://fastdl.mongodb.org/tools/db/%{tarname}.tgz
ExclusiveArch:  x86_64 aarch64

%description
MongoDB Database Tools %{tools_ver}, repackaged from the vendor tarball
(%{tarname}). Installed under %{prefix_dir}.
Commands: mongodump, mongorestore, mongoexport, mongoimport, mongostat,
mongotop, mongofiles, bsondump

%prep
%setup -q -n %{tarname}

%build
# 미리 빌드된 바이너리이므로 빌드 단계 없음

%install
install -d %{buildroot}%{prefix_dir}
cp -a bin %{buildroot}%{prefix_dir}/
for f in LICENSE.md README.md THIRD-PARTY-NOTICES; do
  [ -f "$f" ] && install -m 0644 "$f" %{buildroot}%{prefix_dir}/ || :
done

# 명령어 링크: /usr/local/bin/<명령> → /opt/mongodb-tools/bin/<명령> (상대 경로)
install -d %{buildroot}/usr/local/bin
rm -f bin-links.list
for f in %{buildroot}%{prefix_dir}/bin/*; do
  n="$(basename "$f")"
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$n" in
    mongo*|bsondump)
      ln -s ../../..%{prefix_dir}/bin/$n %{buildroot}/usr/local/bin/$n
      echo "/usr/local/bin/$n" >> bin-links.list ;;
  esac
done

%files -f bin-links.list
%{prefix_dir}
