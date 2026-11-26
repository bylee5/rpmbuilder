# mssqltop: SQL Server 실시간 모니터 (innotop 스타일 TUI) 소스 → 사내 RPM
#
#   이름     : mssqltop
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb 와 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mssqltop0)
#   원본     : https://github.com/bylee5/mssqltop  (Git 태그 v<버전> 의 소스)
#
# 구성
#   프로그램 : /opt/mssqltop/lib       (mssqltop + 함께 담은 pyodbc)
#              /opt/mssqltop/bin/mssqltop  (시스템 python3 로 실행하는 시작 스크립트)
#   명령어   : /usr/local/bin/mssqltop  (패키지가 링크를 직접 소유)
#   설정     : /etc/mssqltop/mssqltop.ini  (noreplace, 서버 목록. 비밀번호는 넣지 않음)
#              ~/.mssqltop.ini 가 있으면 그 파일이 우선 (MSSQLTOP_CONFIG, --config 도 우선)
#   데이터   : 없음
#
# 의존성
#   - pyodbc: AL2023/EL9 저장소에 없으므로 PyPI 의 휠(wheel)을 Source 로 받아 함께 담는다.
#     시스템 python3 = 3.9 → pyodbc 5.3.x 가 3.9 용 휠이 있는 마지막 버전.
#     휠은 아래 sha256 으로 검증한다. 버전을 바꿀 때는 PyPI 의 sha256 도 같이 바꾼다.
#   - unixODBC (OS 저장소): pyodbc 가 쓰는 ODBC 드라이버 관리자
#   - msodbcsql18 (Microsoft 저장소, EULA 동의 필요): 서버에 따로 설치한다.
#       curl -o /etc/yum.repos.d/mssql-release.repo https://packages.microsoft.com/config/rhel/9/prod.repo
#       ACCEPT_EULA=Y dnf install -y msodbcsql18
#     Microsoft 저장소가 설정돼 있으면 함께 설치되도록 Recommends 로만 둔다.
#
# 빌드:
#   sh build-rpm.sh packages/mssql/mssqltop0/mssqltop0.spec al2023                               → 0.1.0-1.DBA
#   sh build-rpm.sh packages/mssql/mssqltop0/mssqltop0.spec al2023 --define "mstop_ver 0.1.0"    → 0.1.0-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용(휠 버전 포함)이 바뀌면 1씩 증가

%{!?mstop_ver:%global mstop_ver 0.1.0}
%{!?rel:%global rel 1}
%global major      0
%global prefix_dir /opt/mssqltop
%global conf_dir   /etc/mssqltop

%global pyodbc_ver 5.3.0
%ifarch x86_64
%global pyodbc_whl pyodbc-%{pyodbc_ver}-cp39-cp39-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl
%global pyodbc_sha e981db84fee4cebec67f41bd266e1e7926665f1b99c3f8f4ea73cd7f7666e381
%endif
%ifarch aarch64
%global pyodbc_whl pyodbc-%{pyodbc_ver}-cp39-cp39-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl
%global pyodbc_sha b35b9983ad300e5aea82b8d1661fc9d3afe5868de527ee6bd252dd550e61ecd6
%endif

%global debug_package     %{nil}
%global _build_id_links   none
# 함께 담은 pyodbc C 확장(.so)을 시스템 전체에 Provides 로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$
# /opt 아래는 자동 의존성 대상이 아님. 필요한 것(python3, unixODBC)은 아래에 직접 명시
%global __requires_exclude_from ^%{prefix_dir}/lib/.*$
# 함께 담은 휠은 그대로 둔다 (strip, shebang 수정 생략). 바이트코드는 %%install 에서 직접 만든다.
%global __os_install_post %{nil}

Name:           mssqltop
Epoch:          2
Version:        %{mstop_ver}
Release:        %{rel}%{?dist}
Summary:        innotop-style real-time TUI monitor for Microsoft SQL Server
# mssqltop: MIT, 함께 담은 pyodbc: MIT
License:        MIT
URL:            https://github.com/bylee5/mssqltop
Source0:        https://github.com/bylee5/mssqltop/archive/refs/tags/v%{mstop_ver}.tar.gz#/mssqltop-%{mstop_ver}.tar.gz
Source1:        https://files.pythonhosted.org/packages/cp39/p/pyodbc/%{pyodbc_whl}
Source2:        mssqltop.ini
ExclusiveArch:  x86_64 aarch64

BuildRequires:  python3 python3-pip
# 함께 담은 pyodbc C 확장은 cp39 용
Requires:       python(abi) = 3.9
Requires:       /usr/bin/python3
# pyodbc → libodbc.so.2 (ODBC 드라이버 관리자)
Requires:       unixODBC
# SQL Server ODBC 드라이버 (Microsoft 저장소). 저장소가 없으면 건너뛰고 설치된다.
Recommends:     msodbcsql18

%description
mssqltop %{mstop_ver}: innotop-style real-time monitoring TUI for Microsoft SQL Server
(running requests, open transactions, blocking chains, wait statistics, memory,
Always On replicas, file I/O, top queries, databases, all-servers overview)
with a batch (TSV) mode. Bundles pyodbc %{pyodbc_ver}.
Needs the Microsoft ODBC Driver 17 or 18 for SQL Server (msodbcsql18).
Installed under %{prefix_dir}, command: /usr/local/bin/mssqltop

%prep
%setup -q -n mssqltop-%{mstop_ver}
# 휠 무결성 확인 (PyPI 에 공개된 sha256)
echo "%{pyodbc_sha}  %{SOURCE1}" | sha256sum -c -
# 태그와 소스의 버전이 같은지 확인
grep -qx '__version__ = "%{mstop_ver}"' mssqltop/__init__.py \
  || { echo "mssqltop/__init__.py 의 버전이 %{mstop_ver} 이 아닙니다"; exit 1; }

%build
# 순수 Python, 빌드 단계 없음 (설치 단계에서 휠을 풀어 담는다)

%install
lib=%{buildroot}%{prefix_dir}/lib
install -d "$lib" %{buildroot}%{prefix_dir}/bin
# 내려받은 휠만 사용 (인터넷 접속 없이, 의존성 자동 설치 없이)
python3 -m pip install -q --disable-pip-version-check --no-index --no-deps --no-compile \
  --target "$lib" %{SOURCE1}
cp -a mssqltop "$lib/"
rm -rf "$lib/bin" "$lib"/*/__pycache__
# pip 의 설치 기록(RECORD 등)은 buildroot 경로를 담고 있어 정리
find "$lib" -name RECORD -path '*.dist-info/*' -delete
find "$lib" -name direct_url.json -delete
# 바이트코드를 미리 만들어 둠 (일반 사용자는 /opt 에 쓸 수 없어 실행할 때마다 컴파일하게 되므로)
python3 -m compileall -q -j0 -d %{prefix_dir}/lib "$lib"

# 시작 스크립트: 시스템 python3 를 격리 모드(-I)로 실행해 사용자 site-packages/PYTHONPATH 영향을 받지 않음
cat > %{buildroot}%{prefix_dir}/bin/mssqltop <<'EOF'
#!/usr/bin/python3 -I
# mssqltop 시작 스크립트 (mssqltop RPM)
import os
import sys

sys.path.insert(0, "%{prefix_dir}/lib")

# 설정 파일: --config > MSSQLTOP_CONFIG > ~/.mssqltop.ini > %{conf_dir}/mssqltop.ini
_SYS_CONF = "%{conf_dir}/mssqltop.ini"
if ("MSSQLTOP_CONFIG" not in os.environ
        and not os.path.exists(os.path.expanduser("~/.mssqltop.ini"))
        and os.path.exists(_SYS_CONF)):
    os.environ["MSSQLTOP_CONFIG"] = _SYS_CONF

from mssqltop.cli import main

sys.exit(main())
EOF
chmod 0755 %{buildroot}%{prefix_dir}/bin/mssqltop

# 명령어 링크: /usr/local/bin/mssqltop → /opt/mssqltop/bin/mssqltop (상대 경로)
install -d %{buildroot}/usr/local/bin
ln -s ../../..%{prefix_dir}/bin/mssqltop %{buildroot}/usr/local/bin/mssqltop

install -D -m 0644 %{SOURCE2} %{buildroot}%{conf_dir}/mssqltop.ini
install -m 0644 README.md LICENSE mssqltop.ini.example %{buildroot}%{prefix_dir}/

%files
%dir %{prefix_dir}
%{prefix_dir}/bin
%{prefix_dir}/lib
%doc %{prefix_dir}/README.md
%doc %{prefix_dir}/mssqltop.ini.example
%license %{prefix_dir}/LICENSE
/usr/local/bin/mssqltop
%dir %{conf_dir}
%config(noreplace) %{conf_dir}/mssqltop.ini
