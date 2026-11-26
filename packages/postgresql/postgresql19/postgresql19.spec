# postgresql: PostgreSQL 19 소스 → 사내 RPM (대상 OS 컨테이너에서 빌드)
#
#   이름     : postgresql
#   Epoch    : 2      → 사내 패키지 규칙. OS 의 postgresql 패키지보다 항상 우선
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (postgresql19 ...)
#
# 구성 (서버당 PostgreSQL 하나, 버전 하나)
#   바이너리 : /opt/postgresql             (경로에 버전 없음, 업그레이드 시 제자리 교체)
#   명령어   : /usr/local/bin/psql 등       (패키지가 링크를 직접 소유)
#   확장     : contrib 포함 (pg_stat_statements, uuid-ossp, pgcrypto ...)
#   설정     : /etc/postgresql/postgresql.conf, pg_hba.conf, pg_ident.conf, pg_hosts.conf, conf.d/
#              (데이터 디렉터리 밖에 두어 수정해도 업데이트 시 보존)
#   데이터   : /data/postgresql/{data,logs}  (최초 설치 시 생성)
#   서비스   : postgresql.service           (datadir 이 비어 있으면 첫 기동 시 initdb 자동 실행)
#
# 설치 후 사용 순서:
#   yum install postgresql
#   vi /etc/postgresql/postgresql.conf        (listen_addresses, shared_buffers 등)
#   systemctl edit postgresql                 (initdb 옵션을 바꿀 때만: 인코딩/로캘은 초기화 후 변경 불가)
#   systemctl enable --now postgresql         (최초 기동 시 자동 initdb)
#   sudo -u postgres psql                     (로컬은 peer 인증: 비밀번호 없이 OS 계정으로 접속)
#
# 업그레이드:
#   같은 메이저(19.0 → 19.1) : yum update postgresql 후 systemctl restart postgresql
#   다른 메이저(18 → 19 등)  : %pre 에서 차단, pg_upgrade 등 별도 절차로 진행
#
# 빌드 재료: postgresql19.spec, postgresql.service, postgresql.conf, pg_hba.conf, pg_ident.conf, pg_hosts.conf  (spec 폴더 + ../common 폴더)
# 빌드:
#   sh build-rpm.sh packages/postgresql/postgresql19/postgresql19.spec al2023                             → 19.0-1.DBA
#   sh build-rpm.sh packages/postgresql/postgresql19/postgresql19.spec al2023 --define "pg_ver 19.1"      → 19.1-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?pg_ver:%global pg_ver 19.0}
%{!?rel:%global rel 1}
%global major      19
%global prefix_dir /opt/postgresql

# 소스 빌드이므로 debuginfo 패키지는 만들지 않음 (바이너리 strip 은 수행)
%global debug_package     %{nil}
%global _binary_payload   w3.zstdio
%global _build_id_links   none
# /opt/postgresql 아래 라이브러리(libpq 등)를 시스템 전체에 Provides로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$
# 위에서 노출하지 않은 자체 라이브러리는 RPATH 로 찾으므로 Requires 에서도 제외
%global __requires_exclude ^lib(pq|ecpg|ecpg_compat|pgtypes)\\.so.*$

Name:           postgresql
Epoch:          2
Version:        %{pg_ver}
Release:        %{rel}%{?dist}
Summary:        PostgreSQL server, clients and contrib extensions
License:        PostgreSQL
URL:            https://www.postgresql.org/
Source0:        https://ftp.postgresql.org/pub/source/v%{pg_ver}/postgresql-%{pg_ver}.tar.bz2
Source1:        postgresql.service
Source2:        postgresql.conf
Source3:        pg_hba.conf
Source4:        pg_ident.conf
Source5:        pg_hosts.conf

BuildRequires:  gcc make perl bzip2 bison flex
BuildRequires:  readline-devel zlib-devel openssl-devel libicu-devel systemd-devel
BuildRequires:  lz4-devel libzstd-devel libuuid-devel
Requires(pre):  shadow-utils

%description
PostgreSQL %{pg_ver} built from source with contrib extensions.
Installed under %{prefix_dir}.
Configuration: /etc/postgresql/postgresql.conf, service: postgresql.service

%prep
%setup -q -n postgresql-%{pg_ver}

%build
./configure \
  --prefix=%{prefix_dir} \
  --with-openssl --with-icu --with-systemd --with-lz4 --with-zstd \
  --with-uuid=e2fs --with-readline
# 서버 + contrib (문서 제외)
make %{?_smp_mflags} world-bin

%install
make install-world-bin DESTDIR=%{buildroot}

# 명령어 링크: /usr/local/bin/<명령> → /opt/postgresql/bin/<명령> (상대 경로)
install -d %{buildroot}/usr/local/bin
rm -f bin-links.list
for f in %{buildroot}%{prefix_dir}/bin/*; do
  n="$(basename "$f")"
  [ -f "$f" ] && [ -x "$f" ] || continue
  ln -s ../../..%{prefix_dir}/bin/$n %{buildroot}/usr/local/bin/$n
  echo "/usr/local/bin/$n" >> bin-links.list
done

install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/postgresql.service
install -D -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/postgresql/postgresql.conf
install -D -m 0640 %{SOURCE3} %{buildroot}%{_sysconfdir}/postgresql/pg_hba.conf
install -D -m 0640 %{SOURCE4} %{buildroot}%{_sysconfdir}/postgresql/pg_ident.conf
install -D -m 0640 %{SOURCE5} %{buildroot}%{_sysconfdir}/postgresql/pg_hosts.conf
install -d -m 0755 %{buildroot}%{_sysconfdir}/postgresql/conf.d

%pre
if [ $1 -gt 1 ]; then
  # 메이저 간 업그레이드 차단 (예: 18 → 19): 데이터 형식이 달라 pg_upgrade 가 필요
  for cur in $(rpm -q --qf '%%{VERSION}\n' postgresql 2>/dev/null); do
    case "$cur" in
      %{major}.*|%{major}rc*|%{major}beta*) ;;
      *)
        echo "ERROR: 설치된 postgresql $cur 을(를) %{pg_ver} 로 업그레이드할 수 없습니다." >&2
        echo "       메이저 버전 변경은 패키지 업데이트가 아닌 pg_upgrade 등 별도 절차로 진행하세요." >&2
        exit 1 ;;
    esac
  done
fi

getent group  postgres >/dev/null || groupadd -r postgres
getent passwd postgres >/dev/null || \
  useradd -r -g postgres -d /var/lib/pgsql -M -s /bin/bash -c "PostgreSQL Server" postgres
exit 0

%post
# 최초 설치 시에만 데이터 디렉터리 생성 (postgresql.conf 기본값 기준)
if [ $1 -eq 1 ]; then
  [ -d /data/postgresql ] || install -d -o postgres -g postgres -m 0755 /data/postgresql
  # PostgreSQL 은 데이터 디렉터리 권한이 0700(또는 0750)이 아니면 기동하지 않음
  [ -d /data/postgresql/data ] || install -d -o postgres -g postgres -m 0700 /data/postgresql/data
  [ -d /data/postgresql/logs ] || install -d -o postgres -g postgres -m 0750 /data/postgresql/logs
fi
systemctl daemon-reload >/dev/null 2>&1 || :
# 주의: 실행 중인 서버를 재시작하지 않는다. 업그레이드 후 재시작은 운영 절차로 수행.

%preun
if [ $1 -eq 0 ]; then
  systemctl disable --now postgresql.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files -f bin-links.list
%{prefix_dir}
%{_unitdir}/postgresql.service
%dir %{_sysconfdir}/postgresql
%dir %{_sysconfdir}/postgresql/conf.d
%config(noreplace) %{_sysconfdir}/postgresql/postgresql.conf
%config(noreplace) %attr(0640,postgres,postgres) %{_sysconfdir}/postgresql/pg_hba.conf
%config(noreplace) %attr(0640,postgres,postgres) %{_sysconfdir}/postgresql/pg_ident.conf
%config(noreplace) %attr(0640,postgres,postgres) %{_sysconfdir}/postgresql/pg_hosts.conf
