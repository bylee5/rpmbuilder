# mongodb: MongoDB Community 9.0 OS별 tarball → 사내 RPM
#
#   이름     : mongodb
#   Epoch    : 2      → 사내 패키지 규칙 (mysql 과 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mongodb83, mongodb90 ...)
#
# 구성 (서버당 MongoDB 하나, 버전 하나)
#   바이너리 : /opt/mongodb                (경로에 버전 없음, 업그레이드 시 제자리 교체)
#   명령어   : /usr/local/bin/mongod, mongos  (패키지가 링크를 직접 소유)
#   설정     : /etc/mongodb/mongod.conf     (수정해도 업데이트 시 보존)
#   데이터   : /data/mongodb/{data,logs}    (최초 설치 시 생성)
#   서비스   : mongod.service
#   셸       : 포함하지 않음 (mongosh 는 별도 패키지)
#
# 설치 후 사용 순서:
#   yum install mongodb
#   vi /etc/mongodb/mongod.conf     (bindIp, replSetName 등 확인)
#   systemctl enable --now mongod   (데이터 파일은 첫 기동 시 자동 생성)
#   mongosh                          (같은 서버에서 접속 → 첫 관리자 계정 생성)
#     use admin
#     db.createUser({user: "admin", pwd: passwordPrompt(), roles: ["root"]})
#   인증이 켜져 있으므로(security.authorization) 계정을 만들기 전에는
#   서버 안에서(localhost) 접속한 경우에만 첫 계정을 만들 수 있다 (localhost exception).
#
# 업그레이드:
#   같은 메이저(9.0.7 → 9.0.8)   : yum update mongodb 후 systemctl restart mongod
#   다른 메이저(8.3 ↔ 9.0 등)    : %pre 에서 차단, featureCompatibilityVersion 절차로 별도 진행
#
# 빌드 재료: mongodb90.spec, mongod.service, mongod.conf  (spec 폴더 + ../common 폴더)
# 빌드 (MongoDB 는 generic 빌드가 없어 대상 OS 에 맞는 tarball 을 자동 선택):
#   sh build-rpm.sh packages/mongodb/mongodb90/mongodb90.spec al2023                               → 9.0.8-1.DBA
#   sh build-rpm.sh packages/mongodb/mongodb90/mongodb90.spec al2023 --define "mongo_ver 9.0.7"    → 9.0.7-1.DBA
#   sh build-rpm.sh packages/mongodb/mongodb90/mongodb90.spec al2023 --define "rel 2"              (같은 버전 재빌드)
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용이 바뀌면 1씩 증가

%{!?mongo_ver:%global mongo_ver 9.0.8}
%{!?rel:%global rel 1}
%global major      9.0
%global prefix_dir /opt/mongodb

# 대상 OS 별 tarball 이름 (빌드하는 OS 의 매크로로 판단)
%if 0%{?amzn} == 2023
%global mongo_os   amazon2023
%else
%if 0%{?rhel} == 9
%global mongo_os   rhel93
%endif
%endif
%{!?mongo_os:%{error:지원하지 않는 대상 OS 입니다 (al2023, el9 만 지원)}}
%global tarname    mongodb-linux-%{_arch}-%{mongo_os}-%{mongo_ver}

# --- 미리 빌드된 바이너리 처리 ---
# debuginfo 패키지 생성 안 함
%global debug_package     %{nil}
# strip 등 후처리 안 함 (벤더 바이너리 그대로 유지)
%global __os_install_post %{nil}
# 빠른 압축
%global _binary_payload   w3.zstdio
# /usr/lib/.build-id 링크가 다른 패키지와 충돌하지 않게 함
%global _build_id_links   none
# /opt/mongodb 아래 라이브러리를 시스템 전체에 Provides로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$

Name:           mongodb
Epoch:          2
Version:        %{mongo_ver}
Release:        %{rel}%{?dist}
Summary:        MongoDB Community Server (mongod, mongos)
License:        SSPL-1.0
URL:            https://www.mongodb.com/try/download/community
Source0:        https://fastdl.mongodb.org/linux/%{tarname}.tgz
Source1:        mongod.service
Source2:        mongod.conf
ExclusiveArch:  x86_64 aarch64

Requires(pre):  shadow-utils

%description
MongoDB Community Server %{mongo_ver}, repackaged from the vendor tarball
(%{tarname}). Installed under %{prefix_dir}.
Configuration: /etc/mongodb/mongod.conf, service: mongod.service
The MongoDB shell (mongosh) is not included.

%prep
%setup -q -n %{tarname}

%build
# 미리 빌드된 바이너리이므로 빌드 단계 없음

%install
# 데스크톱용 Compass 설치 스크립트는 서버에 불필요
rm -f bin/install_compass

install -d %{buildroot}%{prefix_dir}
cp -a bin %{buildroot}%{prefix_dir}/
[ -d lib ] && cp -a lib %{buildroot}%{prefix_dir}/ || :
for f in LICENSE-Community.txt MPL-2 README THIRD-PARTY-NOTICES; do
  [ -f "$f" ] && install -m 0644 "$f" %{buildroot}%{prefix_dir}/ || :
done

# 명령어 링크: /usr/local/bin/<명령> → /opt/mongodb/bin/<명령> (상대 경로)
install -d %{buildroot}/usr/local/bin
rm -f bin-links.list
for f in %{buildroot}%{prefix_dir}/bin/*; do
  n="$(basename "$f")"
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$n" in
    mongo*)
      ln -s ../../..%{prefix_dir}/bin/$n %{buildroot}/usr/local/bin/$n
      echo "/usr/local/bin/$n" >> bin-links.list ;;
  esac
done

install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/mongod.service
install -D -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/mongodb/mongod.conf

%pre
if [ $1 -gt 1 ]; then
  # 메이저 간 업그레이드 차단 (예: 8.3 → 9.0)
  # MongoDB 는 featureCompatibilityVersion 을 단계별로 올려야 하므로 패키지 업데이트로 진행하지 않는다.
  for cur in $(rpm -q --qf '%%{VERSION}\n' mongodb 2>/dev/null); do
    case "$cur" in
      %{major}.*) ;;
      *)
        echo "ERROR: 설치된 mongodb $cur 을(를) %{mongo_ver} 로 업그레이드할 수 없습니다." >&2
        echo "       메이저 버전 변경은 패키지 업데이트가 아닌 별도 마이그레이션 절차로 진행하세요." >&2
        exit 1 ;;
    esac
  done
fi

getent group  mongodb >/dev/null || groupadd -r mongodb
getent passwd mongodb >/dev/null || \
  useradd -r -g mongodb -d /var/lib/mongodb -M -s /sbin/nologin mongodb
exit 0

%post
# 최초 설치 시에만 데이터 디렉터리 생성 (mongod.conf 기본값 기준)
# 업그레이드 때는 운영자가 바꾼 권한/경로를 건드리지 않는다.
if [ $1 -eq 1 ]; then
  # 상위 폴더는 755: 일반 사용자도 소켓(/data/mongodb/mongodb-27017.sock)에 접근 가능
  [ -d /data/mongodb ] || install -d -o mongodb -g mongodb -m 0755 /data/mongodb
  for d in data logs; do
    [ -d /data/mongodb/$d ] || install -d -o mongodb -g mongodb -m 0750 /data/mongodb/$d
  done
fi
systemctl daemon-reload >/dev/null 2>&1 || :
# 주의: 실행 중인 서버를 재시작하지 않는다. 업그레이드 후 재시작은 운영 절차로 수행.

%preun
# 패키지 완전 삭제 시: 서버를 정상 종료하고 자동 기동 해제 (업그레이드 시에는 아무것도 하지 않음)
if [ $1 -eq 0 ]; then
  systemctl disable --now mongod.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files -f bin-links.list
%{prefix_dir}
%{_unitdir}/mongod.service
%dir %{_sysconfdir}/mongodb
%config(noreplace) %{_sysconfdir}/mongodb/mongod.conf
