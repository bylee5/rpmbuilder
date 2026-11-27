# postgresqltop: PostgreSQL 실시간 모니터 (innotop 스타일 TUI) 소스 → 사내 RPM
#
#   이름     : postgresqltop
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb, postgresql 과 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (postgresqltop0)
#   원본     : https://github.com/bylee5/postgresqltop  (Git 태그 v<버전> 의 소스)
#
# 구성
#   프로그램 : /opt/postgresqltop/lib       (postgresqltop + 함께 담은 psycopg, psycopg-binary, typing_extensions)
#              /opt/postgresqltop/bin/postgresqltop  (시스템 python3 로 실행하는 시작 스크립트)
#   명령어   : /usr/local/bin/postgresqltop  (패키지가 링크를 직접 소유)
#   설정     : /etc/postgresqltop/postgresqltop.ini  (noreplace, 서버 목록. 비밀번호는 넣지 않음)
#              ~/.postgresqltop.ini 가 있으면 그 파일이 우선 (POSTGRESQLTOP_CONFIG, --config 도 우선)
#   데이터   : 없음
#
# 의존성: AL2023/EL9 저장소에 psycopg 3 가 없으므로 PyPI 의 휠(wheel)을 Source 로 받아 함께 담는다.
#   시스템 python3 = 3.9 → psycopg 3.2.x 가 3.9 를 지원하는 마지막 버전 (3.3 부터 3.10 이상).
#   psycopg-binary 휠에 libpq 가 들어 있어 OS 의 libpq/postgresql 패키지가 필요 없다.
#   휠은 아래 sha256 으로 검증한다. 버전을 바꿀 때는 PyPI 의 sha256 도 같이 바꾼다.
#
# 빌드:
#   sh build-rpm.sh packages/postgresql/postgresqltop0/postgresqltop0.spec al2023                               → 0.1.0-1.DBA
#   sh build-rpm.sh packages/postgresql/postgresqltop0/postgresqltop0.spec al2023 --define "ptop_ver 0.1.0"     → 0.1.0-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용(휠 버전 포함)이 바뀌면 1씩 증가

%{!?ptop_ver:%global ptop_ver 0.1.0}
%{!?rel:%global rel 1}
%global major      0
%global prefix_dir /opt/postgresqltop
%global conf_dir   /etc/postgresqltop

%global psycopg_ver  3.2.13
%global psycopg_sha  a481374514f2da627157f767a9336705ebefe93ea7a0522a6cbacba165da179a
%global typext_ver   4.16.0
%global typext_sha   481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8
%ifarch x86_64
%global psybin_whl   psycopg_binary-%{psycopg_ver}-cp39-cp39-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
%global psybin_sha   d3aec6e2f1cf4deb1b9a3ac287c0591479f3bd851d0a911d628f8c2c71c14f4a
%endif
%ifarch aarch64
%global psybin_whl   psycopg_binary-%{psycopg_ver}-cp39-cp39-manylinux2014_aarch64.manylinux_2_17_aarch64.whl
%global psybin_sha   f062d725898bf6fc5cfc6349a0d08ee09f129deb14d7fcd5c30f9f1b349f39dc
%endif

%global debug_package     %{nil}
%global _build_id_links   none
# 함께 담은 psycopg-binary C 확장과 libpq(.so)를 시스템 전체에 Provides 로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$
# /opt 아래는 자동 의존성 대상이 아님 (함께 담은 libpq 등). 시작 스크립트의 /usr/bin/python3 는 아래에 직접 명시
%global __requires_exclude_from ^%{prefix_dir}/lib/.*$
# 함께 담은 휠은 그대로 둔다 (strip, shebang 수정 생략). 바이트코드는 %%install 에서 직접 만든다.
%global __os_install_post %{nil}

Name:           postgresqltop
Epoch:          2
Version:        %{ptop_ver}
Release:        %{rel}%{?dist}
Summary:        innotop-style real-time TUI monitor for PostgreSQL
# postgresqltop: MIT, 함께 담은 psycopg/psycopg-binary: LGPL-3.0-only (libpq: PostgreSQL), typing_extensions: PSF-2.0
License:        MIT AND LGPL-3.0-only AND PostgreSQL AND PSF-2.0
URL:            https://github.com/bylee5/postgresqltop
Source0:        https://github.com/bylee5/postgresqltop/archive/refs/tags/v%{ptop_ver}.tar.gz#/postgresqltop-%{ptop_ver}.tar.gz
Source1:        https://files.pythonhosted.org/packages/py3/p/psycopg/psycopg-%{psycopg_ver}-py3-none-any.whl
Source2:        https://files.pythonhosted.org/packages/cp39/p/psycopg-binary/%{psybin_whl}
Source3:        https://files.pythonhosted.org/packages/py3/t/typing-extensions/typing_extensions-%{typext_ver}-py3-none-any.whl
Source4:        postgresqltop.ini
ExclusiveArch:  x86_64 aarch64

BuildRequires:  python3 python3-pip
# 함께 담은 psycopg-binary C 확장은 cp39 용
Requires:       python(abi) = 3.9
Requires:       /usr/bin/python3

%description
postgresqltop %{ptop_ver}: innotop-style real-time monitoring TUI for PostgreSQL
(active queries, transactions, lock waits, wait events, statistics, replication,
I/O, top statements, databases, vacuum progress, all-servers overview)
with a batch (TSV) mode.
Bundles psycopg %{psycopg_ver} (binary, with libpq) and typing_extensions %{typext_ver}.
Installed under %{prefix_dir}, command: /usr/local/bin/postgresqltop

%prep
%setup -q -n postgresqltop-%{ptop_ver}
# 휠 무결성 확인 (PyPI 에 공개된 sha256)
echo "%{psycopg_sha}  %{SOURCE1}" | sha256sum -c -
echo "%{psybin_sha}  %{SOURCE2}"  | sha256sum -c -
echo "%{typext_sha}  %{SOURCE3}"  | sha256sum -c -
# 태그와 소스의 버전이 같은지 확인
grep -qx '__version__ = "%{ptop_ver}"' postgresqltop/__init__.py \
  || { echo "postgresqltop/__init__.py 의 버전이 %{ptop_ver} 이 아닙니다"; exit 1; }

%build
# 순수 Python, 빌드 단계 없음 (설치 단계에서 휠을 풀어 담는다)

%install
lib=%{buildroot}%{prefix_dir}/lib
install -d "$lib" %{buildroot}%{prefix_dir}/bin
# 내려받은 휠만 사용 (인터넷 접속 없이, 의존성 자동 설치 없이)
python3 -m pip install -q --disable-pip-version-check --no-index --no-deps --no-compile \
  --target "$lib" %{SOURCE1} %{SOURCE2} %{SOURCE3}
cp -a postgresqltop "$lib/"
rm -rf "$lib/bin" "$lib"/*/__pycache__
# pip 의 설치 기록(RECORD 등)은 buildroot 경로를 담고 있어 정리
find "$lib" -name RECORD -path '*.dist-info/*' -delete
find "$lib" -name direct_url.json -delete
# 바이트코드를 미리 만들어 둠 (일반 사용자는 /opt 에 쓸 수 없어 실행할 때마다 컴파일하게 되므로)
python3 -m compileall -q -j0 -d %{prefix_dir}/lib "$lib"

# 시작 스크립트: 시스템 python3 를 격리 모드(-I)로 실행해 사용자 site-packages/PYTHONPATH 영향을 받지 않음
cat > %{buildroot}%{prefix_dir}/bin/postgresqltop <<'EOF'
#!/usr/bin/python3 -I
# postgresqltop 시작 스크립트 (postgresqltop RPM)
import os
import sys

sys.path.insert(0, "%{prefix_dir}/lib")

# 설정 파일: --config > POSTGRESQLTOP_CONFIG > ~/.postgresqltop.ini > %{conf_dir}/postgresqltop.ini
_SYS_CONF = "%{conf_dir}/postgresqltop.ini"
if ("POSTGRESQLTOP_CONFIG" not in os.environ
        and not os.path.exists(os.path.expanduser("~/.postgresqltop.ini"))
        and os.path.exists(_SYS_CONF)):
    os.environ["POSTGRESQLTOP_CONFIG"] = _SYS_CONF

from postgresqltop.cli import main

sys.exit(main())
EOF
chmod 0755 %{buildroot}%{prefix_dir}/bin/postgresqltop

# 명령어 링크: /usr/local/bin/postgresqltop → /opt/postgresqltop/bin/postgresqltop (상대 경로)
install -d %{buildroot}/usr/local/bin
ln -s ../../..%{prefix_dir}/bin/postgresqltop %{buildroot}/usr/local/bin/postgresqltop

install -D -m 0644 %{SOURCE4} %{buildroot}%{conf_dir}/postgresqltop.ini
install -m 0644 README.md LICENSE postgresqltop.ini.example %{buildroot}%{prefix_dir}/

%files
%dir %{prefix_dir}
%{prefix_dir}/bin
%{prefix_dir}/lib
%doc %{prefix_dir}/README.md
%doc %{prefix_dir}/postgresqltop.ini.example
%license %{prefix_dir}/LICENSE
/usr/local/bin/postgresqltop
%dir %{conf_dir}
%config(noreplace) %{conf_dir}/postgresqltop.ini
