# mongodbtop: MongoDB 실시간 모니터 (innotop 스타일 TUI) 소스 → 사내 RPM
#
#   이름     : mongodbtop
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb 와 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mongodbtop0)
#   원본     : https://github.com/bylee5/mongodbtop  (Git 태그 v<버전> 의 소스)
#
# 구성
#   프로그램 : /opt/mongodbtop/lib       (mongodbtop + 함께 담은 pymongo, dnspython)
#              /opt/mongodbtop/bin/mongodbtop  (시스템 python3 로 실행하는 시작 스크립트)
#   명령어   : /usr/local/bin/mongodbtop  (패키지가 링크를 직접 소유)
#   설정     : /etc/mongodbtop/mongodbtop.ini  (noreplace, 서버 목록. 비밀번호는 넣지 않음)
#              ~/.mongodbtop.ini 가 있으면 그 파일이 우선 (MONGODBTOP_CONFIG, --config 도 우선)
#   데이터   : 없음
#
# 의존성: AL2023/EL9 저장소에 pymongo 가 없으므로 PyPI 의 휠(wheel)을 Source 로 받아 함께 담는다.
#   시스템 python3 = 3.9 → pymongo 4.18.x 가 3.9 를 지원하는 마지막 버전.
#   휠은 아래 sha256 으로 검증한다. 버전을 바꿀 때는 PyPI 의 sha256 도 같이 바꾼다.
#
# 빌드:
#   sh build-rpm.sh packages/mongodb/mongodbtop0/mongodbtop0.spec al2023                               → 0.1.0-1.DBA
#   sh build-rpm.sh packages/mongodb/mongodbtop0/mongodbtop0.spec al2023 --define "mtop_ver 0.1.0"     → 0.1.0-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용(휠 버전 포함)이 바뀌면 1씩 증가

%{!?mtop_ver:%global mtop_ver 0.1.0}
%{!?rel:%global rel 1}
%global major      0
%global prefix_dir /opt/mongodbtop
%global conf_dir   /etc/mongodbtop

%global pymongo_ver   4.18.3
%global dnspython_ver 2.7.0
%global dnspython_sha b4c34b7d10b51bcc3a5071e7b8dee77939f1e878477eeecc965e9835f63c6c86
%ifarch x86_64
%global pymongo_whl   pymongo-%{pymongo_ver}-cp39-cp39-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl
%global pymongo_sha   0fc7689d0fc579ecce87f770fa42535af3845115cb61706f1a2ab0abe930160d
%endif
%ifarch aarch64
%global pymongo_whl   pymongo-%{pymongo_ver}-cp39-cp39-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl
%global pymongo_sha   9964f06431b7f936df5b63c3309a64b6f0751e5eb1bb47101a14c1ec51b6b884
%endif

%global debug_package     %{nil}
%global _build_id_links   none
# 함께 담은 pymongo C 확장(.so)을 시스템 전체에 Provides 로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$
# /opt 아래는 python 패키지 자동 의존성 대상이 아님. 시작 스크립트의 /usr/bin/python3 는 아래에 직접 명시
%global __requires_exclude_from ^%{prefix_dir}/lib/.*$
# 함께 담은 휠은 그대로 둔다 (strip, shebang 수정 생략). 바이트코드는 %%install 에서 직접 만든다.
%global __os_install_post %{nil}

Name:           mongodbtop
Epoch:          2
Version:        %{mtop_ver}
Release:        %{rel}%{?dist}
Summary:        innotop-style real-time TUI monitor for MongoDB
# mongodbtop: MIT, 함께 담은 pymongo: Apache-2.0, dnspython: ISC
License:        MIT AND Apache-2.0 AND ISC
URL:            https://github.com/bylee5/mongodbtop
Source0:        https://github.com/bylee5/mongodbtop/archive/refs/tags/v%{mtop_ver}.tar.gz#/mongodbtop-%{mtop_ver}.tar.gz
Source1:        https://files.pythonhosted.org/packages/cp39/p/pymongo/%{pymongo_whl}
Source2:        https://files.pythonhosted.org/packages/py3/d/dnspython/dnspython-%{dnspython_ver}-py3-none-any.whl
Source3:        mongodbtop.ini
ExclusiveArch:  x86_64 aarch64

BuildRequires:  python3 python3-pip
# 함께 담은 pymongo C 확장은 cp39 용
Requires:       python(abi) = 3.9
Requires:       /usr/bin/python3

%description
mongodbtop %{mtop_ver}: innotop-style real-time monitoring TUI for MongoDB
(running operations, transactions, lock waits, command rates, WiredTiger cache,
replication, collection activity, all-servers overview) with a batch (TSV) mode.
Bundles pymongo %{pymongo_ver} and dnspython %{dnspython_ver}.
Installed under %{prefix_dir}, command: /usr/local/bin/mongodbtop
Unrelated to mongotop in MongoDB Database Tools; both can be installed.

%prep
%setup -q -n mongodbtop-%{mtop_ver}
# 휠 무결성 확인 (PyPI 에 공개된 sha256)
echo "%{pymongo_sha}  %{SOURCE1}"   | sha256sum -c -
echo "%{dnspython_sha}  %{SOURCE2}" | sha256sum -c -
# 태그와 소스의 버전이 같은지 확인
grep -qx '__version__ = "%{mtop_ver}"' mongodbtop/__init__.py \
  || { echo "mongodbtop/__init__.py 의 버전이 %{mtop_ver} 이 아닙니다"; exit 1; }

%build
# 순수 Python, 빌드 단계 없음 (설치 단계에서 휠을 풀어 담는다)

%install
lib=%{buildroot}%{prefix_dir}/lib
install -d "$lib" %{buildroot}%{prefix_dir}/bin
# 내려받은 휠만 사용 (인터넷 접속 없이, 의존성 자동 설치 없이)
python3 -m pip install -q --disable-pip-version-check --no-index --no-deps --no-compile \
  --target "$lib" %{SOURCE1} %{SOURCE2}
cp -a mongodbtop "$lib/"
rm -rf "$lib/bin" "$lib"/*/__pycache__
# pip 의 설치 기록(RECORD 등)은 buildroot 경로를 담고 있어 정리
find "$lib" -name RECORD -path '*.dist-info/*' -delete
find "$lib" -name direct_url.json -delete
# 바이트코드를 미리 만들어 둠 (일반 사용자는 /opt 에 쓸 수 없어 실행할 때마다 컴파일하게 되므로)
python3 -m compileall -q -j0 -d %{prefix_dir}/lib "$lib"

# 시작 스크립트: 시스템 python3 를 격리 모드(-I)로 실행해 사용자 site-packages/PYTHONPATH 영향을 받지 않음
cat > %{buildroot}%{prefix_dir}/bin/mongodbtop <<'EOF'
#!/usr/bin/python3 -I
# mongodbtop 시작 스크립트 (mongodbtop RPM)
import os
import sys

sys.path.insert(0, "%{prefix_dir}/lib")

# 설정 파일: --config > MONGODBTOP_CONFIG > ~/.mongodbtop.ini > %{conf_dir}/mongodbtop.ini
_SYS_CONF = "%{conf_dir}/mongodbtop.ini"
if ("MONGODBTOP_CONFIG" not in os.environ
        and not os.path.exists(os.path.expanduser("~/.mongodbtop.ini"))
        and os.path.exists(_SYS_CONF)):
    os.environ["MONGODBTOP_CONFIG"] = _SYS_CONF

from mongodbtop.cli import main

sys.exit(main())
EOF
chmod 0755 %{buildroot}%{prefix_dir}/bin/mongodbtop

# 명령어 링크: /usr/local/bin/mongodbtop → /opt/mongodbtop/bin/mongodbtop (상대 경로)
install -d %{buildroot}/usr/local/bin
ln -s ../../..%{prefix_dir}/bin/mongodbtop %{buildroot}/usr/local/bin/mongodbtop

install -D -m 0644 %{SOURCE3} %{buildroot}%{conf_dir}/mongodbtop.ini
install -m 0644 README.md LICENSE mongodbtop.ini.example %{buildroot}%{prefix_dir}/

%files
%dir %{prefix_dir}
%{prefix_dir}/bin
%{prefix_dir}/lib
%doc %{prefix_dir}/README.md
%doc %{prefix_dir}/mongodbtop.ini.example
%license %{prefix_dir}/LICENSE
/usr/local/bin/mongodbtop
%dir %{conf_dir}
%config(noreplace) %{conf_dir}/mongodbtop.ini
