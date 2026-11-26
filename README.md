# rpmbuilder: 사내 YUM 저장소용 RPM 빌드·검사

벤더 tarball(또는 소스, 공식 RPM)을 사내 규칙으로 RPM 으로 만들고, 깨끗한 컨테이너에서
설치 → 기동 → 업데이트 → 삭제까지 검사한 뒤 S3 YUM 저장소에 올린다.

사내 패키지 규칙: 제품 이름 그대로(`mysql`, `mongodb` ...), `Epoch: 2`, `Release: N.DBA`,
`/opt/<제품>` 설치 + `/usr/local/bin` 링크, 설정은 `/etc/<제품>/` (noreplace), 데이터는 `/data/<제품>/`.

## 폴더 구조

```
rpmbuilder/
├─ build-rpm.sh            spec 하나 → RPM (대상 OS 컨테이너에서 빌드, 저장소 갱신)
├─ test-rpm.sh             빌드 → 저장소 → 설치/기동/업데이트/삭제 검사
├─ dev.ps1                 Windows(Docker Desktop)에서 위 스크립트 실행
├─ dev/Dockerfile          dev.ps1 이 쓰는 개발 환경 이미지
├─ catalog.yaml            대상 제품 목록과 원본 정보
├─ packages/
│  ├─ <제품>/
│  │  ├─ common/           같은 제품의 공통 파일 (서비스, 설정, 검사 스크립트)
│  │  └─ <저장소 ID>/      <저장소 ID>.spec  (+ 이 버전에만 필요한 파일)
│  ├─ mysql/      common/  mysql84/  mysql97/  mysql2610/
│  ├─ mongodb/    common/  mongodb83/  mongodb90/  mongosh2/  mongodb-tools100/
│  ├─ postgresql/ postgresql19/
│  └─ datadog/    datadog-agent7/  windows/ (Windows MSI 미러/설치 스크립트)
├─ sources/                내려받은 원본 (자동, 커밋하지 않음)
├─ dist/                   결과 = S3 에 올릴 내용
│  ├─ al2023/<저장소 ID>/  RPM + repodata
│  └─ windows/<이름>/      MSI + SHA256SUMS + LATEST
└─ _build/                 작업 공간 (자동, 지워도 됨)
   └─ testrepo/            배포하지 않을 RPM(출시 후보 등) 검사용 저장소
```

- 저장소 ID = spec 이 있는 폴더 이름 = 서버의 `/etc/yum.repos.d/<저장소 ID>.repo`
- 빌드 재료 = spec 폴더의 파일 + `../common` 의 파일 (같은 이름이면 spec 폴더 우선)
- 검사 파일(`test-env.sh`, `test-inner.sh`)도 spec 폴더 → `../common` 순서로 찾음

## 자주 쓰는 명령 (Windows)

```powershell
.\dev.ps1 sh test-rpm.sh mysql84                 # 최신 2개 버전 자동 선택 → 빌드 → 검사
.\dev.ps1 sh test-rpm.sh mongodb90 9.0.7 9.0.8   # 버전 지정
$env:SKIP_BUILD='1'; .\dev.ps1 sh test-rpm.sh mysql84   # 빌드 생략, 저장소의 RPM 으로 검사
.\dev.ps1 sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13.1"
.\packages\datadog\windows\fetch-msi.ps1         # Windows MSI 최신 2개 받기 + 서명 검증
```

리눅스 빌드 서버에서는 `dev.ps1` 없이 `sh test-rpm.sh ...`, `sh build-rpm.sh ...` 로 실행한다.

## 새 버전/제품 추가

- 같은 제품의 새 메이저 (예: mysql 27.4): `packages/mysql/mysql2704/mysql2704.spec` 만 만들고
  `major`, 기본 버전 값을 바꾼다. 서비스/설정/검사는 `common/` 을 그대로 쓴다.
- 새 제품: `packages/<제품>/<저장소 ID>/` 에 spec, `test-env.sh`, `test-inner.sh` 를 만든다.
  (기존 제품 폴더를 참고)
- 같은 버전을 다시 빌드할 때는 Release 를 올린다: `REL=2` / `--define "rel 2"`.
  이미 저장소에 있는 버전-릴리스는 build-rpm.sh 가 덮어쓰지 않는다.
