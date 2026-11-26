<#
.SYNOPSIS
  Windows(Docker Desktop)에서 build-rpm.sh / test-rpm.sh 를 서버와 같은 Rocky 9 환경으로 실행한다.

.DESCRIPTION
  프로젝트 폴더를 개발용 컨테이너(rpmdev:el9)에 연결하고, 그 안에서 명령을 실행한다.
  컨테이너는 호스트의 Docker Desktop 엔진을 그대로 쓰므로, 스크립트가 띄우는
  빌드/검사 컨테이너도 정상 동작한다.

  프로젝트는 컨테이너 안에서 /run/desktop/mnt/host/<드라이브>/... 경로에 연결된다.
  Docker Desktop 엔진이 이 경로를 Windows 폴더로 알아보기 때문에, 컨테이너 안에서
  다시 docker run -v 로 하위 폴더를 연결해도 같은 폴더가 보인다.

.EXAMPLE
  .\dev.ps1                                   # 개발 환경 셸 (exit 로 종료)
  .\dev.ps1 sh test-rpm.sh                    # mysql84 최신 두 버전으로 설치 → 업데이트 전체 검사
  .\dev.ps1 sh test-rpm.sh mongodb83          # mongodb83 최신 두 버전
  .\dev.ps1 sh test-rpm.sh mongosh2           # mongosh2 최신 두 버전
  .\dev.ps1 sh test-rpm.sh mongodb-tools100   # mongodb-tools100 최신 두 버전
  $env:OUT_DIR='_build/testrepo/al2023/postgresql19'; .\dev.ps1 sh test-rpm.sh postgresql19 19rc2 19.0   # 출시 후보는 테스트 저장소에서만
  .\dev.ps1 sh test-rpm.sh mysql84 8.4.11 8.4.13   # 버전 직접 지정
  .\dev.ps1 sh build-rpm.sh packages/mysql/mysql84/mysql84.spec al2023 --define "mysql_ver 8.4.13"
  .\dev.ps1 sh build-rpm.sh packages/mongodb/mongodb83/mongodb83.spec al2023
  .\dev.ps1 -Rebuild                          # 개발 환경 이미지 다시 만들기
#>
$ErrorActionPreference = 'Stop'
# 인자를 그대로 컨테이너에 넘기기 위해 param() 대신 $args 를 직접 사용
$Rebuild = $false
$Command = @($args)
if ($Command.Count -gt 0 -and $Command[0] -eq '-Rebuild') {
  $Rebuild = $true
  $Command = @($Command | Select-Object -Skip 1)
}

$Root  = $PSScriptRoot
$Image = 'rpmdev:el9'

# ---------- docker 확인 ----------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker 가 없습니다. Docker Desktop 을 설치하세요.' }
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop 이 실행 중이 아닙니다. 실행한 뒤 다시 시도하세요.' }

# ---------- 줄바꿈 / BOM 검사 (리눅스에서 실행되는 파일) ----------
$bad = Get-ChildItem -Path $Root -Recurse -File -Include *.sh, *.spec, *.service, *.cnf, *.repo, *.yaml |
  Where-Object { $_.FullName -notmatch '\\(_build|dist|sources)\\' } |
  Where-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -or ($b -contains 13)
  }
if ($bad) {
  Write-Warning 'CRLF 줄바꿈 또는 BOM 이 있는 파일이 있습니다. 리눅스에서 오류가 날 수 있으니 LF / UTF-8(BOM 없음)으로 저장하세요:'
  $bad | ForEach-Object { Write-Warning ('  ' + $_.FullName.Substring($Root.Length + 1)) }
}

# ---------- 개발 환경 이미지 (Dockerfile 이 바뀌면 자동으로 다시 만듦) ----------
$dockerfile = Join-Path $Root 'dev\Dockerfile'
$hash = (Get-FileHash $dockerfile -Algorithm SHA256).Hash.Substring(0, 16)
$current = docker image inspect -f '{{ index .Config.Labels "rpmdev.hash" }}' $Image 2>$null
if ($Rebuild -or $LASTEXITCODE -ne 0 -or $current -ne $hash) {
  Write-Host "==> 개발 환경 이미지 생성: $Image" -ForegroundColor Cyan
  docker build --pull --label "rpmdev.hash=$hash" -t $Image (Join-Path $Root 'dev')
  if ($LASTEXITCODE -ne 0) { throw '개발 환경 이미지 생성 실패' }
}

# ---------- 실행 ----------
# D:\claude\rpmbuilder → /run/desktop/mnt/host/d/claude/rpmbuilder
$drive = $Root.Substring(0, 1).ToLower()
$inner = "/run/desktop/mnt/host/$drive" + ($Root.Substring(2) -replace '\\', '/')

$runArgs = @('run', '--rm', '--init',
  '-v', "${Root}:${inner}",
  '-v', '/var/run/docker.sock:/var/run/docker.sock',
  '-w', $inner)
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { $runArgs += '-it' }
foreach ($v in 'http_proxy', 'https_proxy', 'no_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY') {
  $val = [Environment]::GetEnvironmentVariable($v)
  if ($val) { $runArgs += @('-e', "$v=$val") }
}
# build-rpm.sh / test-rpm.sh 옵션 환경변수 전달 (예: $env:SKIP_BUILD=1; .\dev.ps1 sh test-rpm.sh)
foreach ($v in 'BUILD_MODE', 'TARGET_OS', 'REL', 'SKIP_BUILD', 'KEEP', 'DIST_TAG', 'OVERWRITE', 'PRUNE_OLD', 'REBUILD_IMAGE', 'BASE_IMAGE', 'TEST_IMAGE', 'MISS_LIMIT', 'OUT_DIR') {
  $val = [Environment]::GetEnvironmentVariable($v)
  if ($val) { $runArgs += @('-e', "$v=$val") }
}
$runArgs += $Image
if ($Command.Count -gt 0) { $runArgs += $Command } else { $runArgs += 'bash' }

docker @runArgs
exit $LASTEXITCODE
