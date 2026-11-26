# mysql: Oracle MySQL 8.4 generic tarball → 사내 RPM
#
#   이름     : mysql
#   Epoch    : 2      → OS(AppStream)의 mysql 패키지보다 항상 우선
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mysql56, mysql84 ...)
#
# 구성 (서버당 MySQL 하나, 버전 하나)
#   바이너리 : /opt/mysql                  (경로에 버전 없음, 업그레이드 시 제자리 교체)
#   명령어   : /usr/local/bin/mysql 등      (패키지가 링크를 직접 소유)
#   설정     : /etc/mysql/my.cnf            (수정해도 업데이트 시 보존)
#   데이터   : /data/mysql/{data,logs,binlog,tmp}   (최초 설치 시 생성)
#   서비스   : mysqld.service
#
# 설치 후 사용 순서:
#   yum install mysql
#   vi /etc/mysql/my.cnf      (초기화 전에 확정해야 하는 값 확인)
#   systemctl enable --now mysqld          (최초 기동 시 자동 초기화)
#   grep 'temporary password' /data/mysql/logs/mysqld.err
#
# 업그레이드:
#   같은 메이저(8.4.13 → 8.4.13.1): yum update mysql 후 systemctl restart mysqld
#   다른 메이저(8.4 → 9.x 등)   : %pre 에서 차단, 별도 마이그레이션 절차로 진행
#
# 빌드 재료: mysql84.spec, mysqld.service, my.cnf  (spec 폴더 + ../common 폴더)
# 빌드:
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023                                  → 8.4.13.1-1.DBA
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13"      → 8.4.13-1.DBA
#   같은 버전을 다시 빌드할 때(spec/설정 변경)는 Release 를 올린다:
#   sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13" --define "rel 2"
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?mysql_ver:%global mysql_ver 8.4.13.1}
%{!?rel:%global rel 1}
%global major      8.4
%global glibc      2.28
%global prefix_dir /opt/mysql
%global tarname    mysql-%{mysql_ver}-linux-glibc%{glibc}-%{_arch}

# --- 미리 빌드된 바이너리 처리 ---
# debuginfo 패키지 생성 안 함
%global debug_package     %{nil}
# strip, bytecompile 등 후처리 안 함 (벤더 바이너리 그대로 유지)
%global __os_install_post %{nil}
# 빠른 압축 (기본값은 대용량 tarball에서 매우 느림)
%global _binary_payload   w3.zstdio
# /usr/lib/.build-id 링크가 다른 패키지와 충돌하지 않게 함
%global _build_id_links   none
# /opt/mysql 아래 라이브러리를 시스템 전체에 Provides로 노출하지 않음
%global __provides_exclude_from ^/opt/mysql/.*$
# 번들 라이브러리 자체의 의존성은 자동 생성하지 않음
%global __requires_exclude_from ^%{prefix_dir}/lib/private/.*$
# tarball에 번들되어 있어 OS 패키지가 필요 없는 라이브러리
#   libsasl2 의 버전 심볼(SASL2_4.0): 8.4.13 부터 lib/private 에 번들된 libsasl2 에만 있음.
#   AL2023 의 cyrus-sasl-lib 은 제공하지 않아 설치가 막히므로 버전 붙은 요구만 제외한다.
#   libicu*: MySQL 26.10 부터 lib/private 에 번들 (ICU 77), OS 패키지 불필요.
%global __requires_exclude ^(lib(crypto|ssl|protobuf|protobuf-lite|fido2|absl_.*|mysqlclient|com_err|icui18n|icuuc|icudata|icustubdata|icuio)\\.so.*|libsasl2\\.so\\.3\\(SASL2_.*)$

Name:           mysql
Epoch:          2
Version:        %{mysql_ver}
Release:        %{rel}%{?dist}
Summary:        Oracle MySQL server and clients
License:        GPL-2.0-only
URL:            https://dev.mysql.com/downloads/mysql/
Source0:        http://dev.mysql.com/get/%{tarname}.tar.xz
Source1:        mysqld.service
Source2:        my.cnf
ExclusiveArch:  x86_64 aarch64

Requires(pre):  shadow-utils

%description
Oracle MySQL %{mysql_ver}, repackaged from the generic Linux tarball
(%{tarname}). Installed under %{prefix_dir}.
Configuration: /etc/mysql/my.cnf, service: mysqld.service

%prep
%setup -q -n %{tarname}

%build
# 미리 빌드된 바이너리이므로 빌드 단계 없음

%install
# 운영에 불필요한 디버그 서버와 플러그인 제외
rm -f  bin/mysqld-debug
rm -rf lib/plugin/debug

install -d %{buildroot}%{prefix_dir}
cp -a bin lib share %{buildroot}%{prefix_dir}/
[ -d man ] && cp -a man %{buildroot}%{prefix_dir}/ || :
for f in LICENSE README; do
  [ -f "$f" ] && install -m 0644 "$f" %{buildroot}%{prefix_dir}/ || :
done

# 명령어 링크: /usr/local/bin/<명령> → /opt/mysql/bin/<명령>
# MySQL 관련 이름만 연결 (lz4_decompress 같은 일반적인 이름은 제외해 다른 도구와 충돌 방지)
install -d %{buildroot}/usr/local/bin
rm -f bin-links.list
for f in %{buildroot}%{prefix_dir}/bin/*; do
  n="$(basename "$f")"
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$n" in
    my*|ibd2sdi|innochecksum|perror)
      # 상대 경로 링크 (/usr/local/bin → ../../../opt/mysql/bin): rpm 권장 방식
      ln -s ../../..%{prefix_dir}/bin/$n %{buildroot}/usr/local/bin/$n
      echo "/usr/local/bin/$n" >> bin-links.list ;;
  esac
done

install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/mysqld.service
install -D -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/mysql/my.cnf

%pre
if [ $1 -gt 1 ]; then
  # 메이저 간 업그레이드 차단 (예: 5.6 → 8.4)
  # MySQL은 메이저를 건너뛰는 업그레이드를 지원하지 않으므로 여기서 설치를 중단시킨다.
  for cur in $(rpm -q --qf '%%{VERSION}\n' mysql 2>/dev/null); do
    case "$cur" in
      %{major}.*) ;;
      *)
        echo "ERROR: 설치된 mysql $cur 을(를) %{mysql_ver} 로 업그레이드할 수 없습니다." >&2
        echo "       메이저 버전 변경은 패키지 업데이트가 아닌 별도 마이그레이션 절차로 진행하세요." >&2
        exit 1 ;;
    esac
  done

  # 이전 릴리스가 만든 alternatives 링크 정리 (이번 릴리스부터 패키지가 링크를 직접 소유)
  if [ -e /var/lib/alternatives/mysql-client ] && command -v alternatives >/dev/null 2>&1; then
    alternatives --remove-all mysql-client >/dev/null 2>&1 || :
  fi
fi

getent group  mysql >/dev/null || groupadd -r mysql
getent passwd mysql >/dev/null || \
  useradd -r -g mysql -d /var/lib/mysql -M -s /sbin/nologin mysql
exit 0

%post
# 최초 설치 시에만 데이터 디렉터리 생성 (my.cnf 기본값 기준)
# 업그레이드 때는 운영자가 바꾼 권한/경로를 건드리지 않는다.
if [ $1 -eq 1 ]; then
  # 상위 폴더는 755: 일반 사용자의 클라이언트도 소켓(/data/mysql/mysql.sock)에 접근 가능
  [ -d /data/mysql ] || install -d -o mysql -g mysql -m 0755 /data/mysql
  for d in data logs binlog tmp; do
    [ -d /data/mysql/$d ] || install -d -o mysql -g mysql -m 0750 /data/mysql/$d
  done
fi
systemctl daemon-reload >/dev/null 2>&1 || :
# 주의: 실행 중인 서버를 재시작하지 않는다. 업그레이드 후 재시작은 운영 절차로 수행.

%preun
# 패키지 완전 삭제 시: 서버를 정상 종료하고 자동 기동 해제 (업그레이드 시에는 아무것도 하지 않음)
if [ $1 -eq 0 ]; then
  systemctl disable --now mysqld.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files -f bin-links.list
%{prefix_dir}
%{_unitdir}/mysqld.service
%dir %{_sysconfdir}/mysql
%config(noreplace) %{_sysconfdir}/mysql/my.cnf
