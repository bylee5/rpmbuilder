# mysqltop: MySQL / MariaDB 실시간 모니터 (innotop 스타일 TUI) 소스 → 사내 RPM
#
#   이름     : mysqltop
#   Epoch    : 2      → 사내 패키지 규칙 (mysql, mongodb, postgresql 과 동일)
#   Release  : N.DBA  → build-rpm.sh 가 --define "dist .DBA" 로 지정
#   저장소   : 메이저 버전별 저장소 ID (mysqltop0)
#   원본     : https://github.com/bylee5/mysqltop  (Git 태그 v<버전> 의 소스)
#
# 구성
#   프로그램 : /opt/mysqltop/lib       (mysqltop + 함께 담은 PyMySQL)
#              /opt/mysqltop/bin/mysqltop  (시스템 python3 로 실행하는 시작 스크립트)
#   명령어   : /usr/local/bin/mysqltop  (패키지가 링크를 직접 소유)
#   설정     : /etc/mysqltop/mysqltop.ini  (noreplace, 서버 목록. 비밀번호는 넣지 않음)
#              ~/.mysqltop.ini 가 있으면 그 파일이 우선 (MYSQLTOP_CONFIG, --config 도 우선)
#   데이터   : 없음
#
# 의존성
#   - PyMySQL: AL2023 저장소에 없으므로 PyPI 의 휠(wheel)을 Source 로 받아 함께 담는다 (순수 Python).
#     휠은 아래 sha256 으로 검증한다. 버전을 바꿀 때는 PyPI 의 sha256 도 같이 바꾼다.
#   - python3-cryptography (OS 저장소, Recommends): TLS 없이(--ssl-mode DISABLED) caching_sha2_password
#     계정으로 접속할 때 필요. 기본(PREFERRED, TLS)과 유닉스 소켓 접속은 없어도 동작한다.
#
# 빌드:
#   sh build-rpm.sh packages/mysql/mysqltop0/mysqltop0.spec al2023                               → 0.1.0-1.DBA
#   sh build-rpm.sh packages/mysql/mysqltop0/mysqltop0.spec al2023 --define "mytop_ver 0.1.0"    → 0.1.0-1.DBA
#
# Release 규칙: 새 버전은 1부터, 같은 버전에서 패키지 내용(휠 버전 포함)이 바뀌면 1씩 증가

%{!?mytop_ver:%global mytop_ver 0.1.0}
%{!?rel:%global rel 1}
%global major      0
%global prefix_dir /opt/mysqltop
%global conf_dir   /etc/mysqltop

%global pymysql_ver 1.2.4
%global pymysql_sha e169bed906168fffd0088925f45b3df024c2775c6fd128da0df773d47c458840

%global debug_package     %{nil}
%global _build_id_links   none
# /opt 아래 파일을 시스템 전체에 Provides 로 노출하지 않음
%global __provides_exclude_from ^%{prefix_dir}/.*$
# /opt 아래는 자동 의존성 대상이 아님. 시작 스크립트의 /usr/bin/python3 는 아래에 직접 명시
%global __requires_exclude_from ^%{prefix_dir}/lib/.*$
# 함께 담은 휠은 그대로 둔다 (shebang 수정 생략). 바이트코드는 %%install 에서 직접 만든다.
%global __os_install_post %{nil}

Name:           mysqltop
Epoch:          2
Version:        %{mytop_ver}
Release:        %{rel}%{?dist}
Summary:        innotop-style real-time TUI monitor for MySQL and MariaDB
# mysqltop: MIT, 함께 담은 PyMySQL: MIT
License:        MIT
URL:            https://github.com/bylee5/mysqltop
Source0:        https://github.com/bylee5/mysqltop/archive/refs/tags/v%{mytop_ver}.tar.gz#/mysqltop-%{mytop_ver}.tar.gz
Source1:        https://files.pythonhosted.org/packages/py3/p/pymysql/pymysql-%{pymysql_ver}-py3-none-any.whl
Source2:        mysqltop.ini
# 다른 *top 패키지와 같이 아키텍처별로 만든다 (저장소 버전 확인이 아키텍처 기준)
ExclusiveArch:  x86_64 aarch64

BuildRequires:  python3 python3-pip
# 바이트코드(.pyc)를 python 3.9 로 만들어 담는다
Requires:       python(abi) = 3.9
Requires:       /usr/bin/python3
# TLS 없이 caching_sha2_password 계정으로 접속할 때 (RSA 키 교환)
Recommends:     python3-cryptography

%description
mysqltop %{mytop_ver}: innotop-style real-time monitoring TUI for MySQL and MariaDB
(processlist, transactions, lock waits, InnoDB, replication, Group Replication,
statement digests, all-servers overview) with a batch (TSV) mode.
Bundles PyMySQL %{pymysql_ver}.
Installed under %{prefix_dir}, command: /usr/local/bin/mysqltop

%prep
%setup -q -n mysqltop-%{mytop_ver}
# 휠 무결성 확인 (PyPI 에 공개된 sha256)
echo "%{pymysql_sha}  %{SOURCE1}" | sha256sum -c -
# 태그와 소스의 버전이 같은지 확인
grep -qx '__version__ = "%{mytop_ver}"' mysqltop/__init__.py \
  || { echo "mysqltop/__init__.py 의 버전이 %{mytop_ver} 이 아닙니다"; exit 1; }

%build
# 순수 Python, 빌드 단계 없음 (설치 단계에서 휠을 풀어 담는다)

%install
lib=%{buildroot}%{prefix_dir}/lib
install -d "$lib" %{buildroot}%{prefix_dir}/bin
# 내려받은 휠만 사용 (인터넷 접속 없이, 의존성 자동 설치 없이)
python3 -m pip install -q --disable-pip-version-check --no-index --no-deps --no-compile \
  --target "$lib" %{SOURCE1}
cp -a mysqltop "$lib/"
rm -rf "$lib/bin" "$lib"/*/__pycache__
# pip 의 설치 기록(RECORD 등)은 buildroot 경로를 담고 있어 정리
find "$lib" -name RECORD -path '*.dist-info/*' -delete
find "$lib" -name direct_url.json -delete
# 바이트코드를 미리 만들어 둠 (일반 사용자는 /opt 에 쓸 수 없어 실행할 때마다 컴파일하게 되므로)
python3 -m compileall -q -j0 -d %{prefix_dir}/lib "$lib"

# 시작 스크립트: 시스템 python3 를 격리 모드(-I)로 실행해 사용자 site-packages/PYTHONPATH 영향을 받지 않음
cat > %{buildroot}%{prefix_dir}/bin/mysqltop <<'EOF'
#!/usr/bin/python3 -I
# mysqltop 시작 스크립트 (mysqltop RPM)
import os
import sys

sys.path.insert(0, "%{prefix_dir}/lib")

# 설정 파일: --config > MYSQLTOP_CONFIG > ~/.mysqltop.ini > %{conf_dir}/mysqltop.ini
_SYS_CONF = "%{conf_dir}/mysqltop.ini"
if ("MYSQLTOP_CONFIG" not in os.environ
        and not os.path.exists(os.path.expanduser("~/.mysqltop.ini"))
        and os.path.exists(_SYS_CONF)):
    os.environ["MYSQLTOP_CONFIG"] = _SYS_CONF

from mysqltop.cli import main

sys.exit(main())
EOF
chmod 0755 %{buildroot}%{prefix_dir}/bin/mysqltop

# 명령어 링크: /usr/local/bin/mysqltop → /opt/mysqltop/bin/mysqltop (상대 경로)
install -d %{buildroot}/usr/local/bin
ln -s ../../..%{prefix_dir}/bin/mysqltop %{buildroot}/usr/local/bin/mysqltop

install -D -m 0644 %{SOURCE2} %{buildroot}%{conf_dir}/mysqltop.ini
install -m 0644 README.md LICENSE mysqltop.ini.example %{buildroot}%{prefix_dir}/

%files
%dir %{prefix_dir}
%{prefix_dir}/bin
%{prefix_dir}/lib
%doc %{prefix_dir}/README.md
%doc %{prefix_dir}/mysqltop.ini.example
%license %{prefix_dir}/LICENSE
/usr/local/bin/mysqltop
%dir %{conf_dir}
%config(noreplace) %{conf_dir}/mysqltop.ini
