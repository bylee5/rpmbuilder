# mongosh: MongoDB Shell 2.x tarball → 사내 RPM
#
#   이름     : mongosh
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb 와 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mongosh2)
#
# 구성
#   바이너리 : /opt/mongosh/bin/mongosh   (경로에 버전 없음, 업그레이드 시 제자리 교체)
#   명령어   : /usr/local/bin/mongosh      (패키지가 링크를 직접 소유)
#   매뉴얼   : man mongosh
#   서버(mongodb 패키지)와 독립: 서버 버전과 관계없이 최신 mongosh 를 써도 된다.
#
# tarball: OS 공용 빌드 중 시스템 OpenSSL 3 을 쓰는 *-openssl3 빌드 (AL2023, EL9)
#
# 빌드:
#   sh build-rpm.sh packages/mongodb/mongosh2/mongosh2.spec al2023                               → 2.14.3-1.DBA
#   sh build-rpm.sh packages/mongodb/mongosh2/mongosh2.spec al2023 --define "msh_ver 2.14.2"     → 2.14.2-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?msh_ver:%global msh_ver 2.14.3}
%{!?rel:%global rel 1}
%global major      2
%global prefix_dir /opt/mongosh

%ifarch x86_64
%global msh_arch   x64
%endif
%ifarch aarch64
%global msh_arch   arm64
%endif
%global tarname    mongosh-%{msh_ver}-linux-%{msh_arch}-openssl3

# --- 미리 빌드된 바이너리 처리 ---
%global debug_package     %{nil}
%global __os_install_post %{nil}
%global _binary_payload   w3.zstdio
%global _build_id_links   none
# /opt/mongosh 아래 라이브러리(mongosh_crypt_v1.so)를 시스템 전체에 Provides로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$

Name:           mongosh
Epoch:          2
Version:        %{msh_ver}
Release:        %{rel}%{?dist}
Summary:        MongoDB Shell (mongosh)
License:        Apache-2.0
URL:            https://www.mongodb.com/try/download/shell
Source0:        https://downloads.mongodb.com/compass/%{tarname}.tgz
ExclusiveArch:  x86_64 aarch64

%description
MongoDB Shell %{msh_ver}, repackaged from the vendor tarball (%{tarname}).
Installed under %{prefix_dir}, command: /usr/local/bin/mongosh

%prep
%setup -q -n %{tarname}

%build
# 미리 빌드된 바이너리이므로 빌드 단계 없음

%install
install -d %{buildroot}%{prefix_dir}
cp -a bin %{buildroot}%{prefix_dir}/
for f in LICENSE-mongosh LICENSE-crypt-library README THIRD_PARTY_NOTICES; do
  [ -f "$f" ] && install -m 0644 "$f" %{buildroot}%{prefix_dir}/ || :
done

# 명령어 링크: /usr/local/bin/mongosh → /opt/mongosh/bin/mongosh (상대 경로)
install -d %{buildroot}/usr/local/bin
ln -s ../../..%{prefix_dir}/bin/mongosh %{buildroot}/usr/local/bin/mongosh

# 매뉴얼 (man mongosh)
[ -f mongosh.1.gz ] && install -D -m 0644 mongosh.1.gz %{buildroot}%{_mandir}/man1/mongosh.1.gz || :

%files
%{prefix_dir}
/usr/local/bin/mongosh
%{_mandir}/man1/mongosh.1.gz
