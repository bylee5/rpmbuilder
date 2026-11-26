<#
.SYNOPSIS
  사내 저장소(S3)에서 Datadog Agent 7 MSI 를 받아 설치/업그레이드한다. (Windows 서버에서 관리자 권한으로 실행)

.DESCRIPTION
  1) <RepoUrl>/SHA256SUMS 와 MSI 를 받는다 (버전 미지정 시 <RepoUrl>/LATEST)
  2) SHA256 과 Datadog 코드 서명(Authenticode)을 확인한다. 하나라도 다르면 설치하지 않는다.
  3) msiexec 로 조용히 설치한다. 이미 설치되어 있으면 같은 명령으로 업그레이드된다.
     (낮은 버전으로 내리는 것은 MSI 가 막는다)

  API 키는 패키지/저장소에 두지 않는다. -ApiKey 인자 또는 환경변수 DD_API_KEY 로 전달한다.
  업그레이드 시에는 기존 설정(C:\ProgramData\Datadog\datadog.yaml)이 유지되므로 API 키를 생략할 수 있다.

.EXAMPLE
  $env:DD_API_KEY = '<API 키>'
  .\install-datadog-agent.ps1 -RepoUrl https://<사내 저장소>/windows/datadog-agent7
.EXAMPLE
  .\install-datadog-agent.ps1 -RepoUrl https://<사내 저장소>/windows/datadog-agent7 -Version 7.86.0 -Tags 'env:prod,team:dba'
#>
param(
  [Parameter(Mandatory = $true)][string]$RepoUrl,
  [string]$Version,
  [string]$ApiKey = $env:DD_API_KEY,
  [string]$Site = 'datadoghq.com',
  [string]$Tags,
  [string]$LogDir = $env:TEMP
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$SignerRe = '(^|, )O="?Datadog, Inc\.?"?(,|$)'   # 코드 서명 인증서의 회사 이름 (O=)
$Agent  = 'C:\Program Files\Datadog\Datadog Agent\bin\agent.exe'
$RepoUrl = $RepoUrl.TrimEnd('/')

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw '관리자 권한으로 실행하세요.' }

# ---------- 설치할 버전 ----------
if (-not $Version) { $Version = (Invoke-RestMethod "$RepoUrl/LATEST" -UseBasicParsing).Trim() }
$name = "datadog-agent-$Version-x86_64.msi"
$installed = if (Test-Path $Agent) { ((& $Agent version 2>$null) -replace '^Agent (\S+).*$', '$1') } else { '' }
Write-Step "설치 대상: $Version (현재: $(if ($installed) { $installed } else { '없음' }))"
if ($installed -eq $Version) { Write-Host '    이미 같은 버전이 설치되어 있습니다.'; exit 0 }
if (-not $installed -and -not $ApiKey) { throw '최초 설치에는 API 키가 필요합니다: -ApiKey 또는 $env:DD_API_KEY' }

# ---------- 다운로드 + 검증 ----------
$work = Join-Path $env:TEMP "dd-install-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$msi = Join-Path $work $name
try {
  Write-Step "다운로드: $RepoUrl/$name"
  $sums = (Invoke-WebRequest "$RepoUrl/SHA256SUMS" -UseBasicParsing).Content
  $expect = ($sums -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($name))\s*$" } | ForEach-Object { ($_ -split '\s+')[0] }) | Select-Object -First 1
  if (-not $expect) { throw "SHA256SUMS 에 $name 이 없습니다." }
  Invoke-WebRequest "$RepoUrl/$name" -OutFile $msi -UseBasicParsing

  $hash = (Get-FileHash $msi -Algorithm SHA256).Hash.ToLower()
  if ($hash -ne $expect.ToLower()) { throw "SHA256 이 다릅니다. 기대 $expect, 실제 $hash" }
  Write-Host '    [OK] SHA256 일치'
  $sig = Get-AuthenticodeSignature -FilePath $msi
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerRe) {
    throw "Datadog 코드 서명이 확인되지 않습니다: $($sig.Status) $($sig.SignerCertificate.Subject)"
  }
  Write-Host '    [OK] Datadog 코드 서명 유효'

  # ---------- 설치 / 업그레이드 ----------
  $log = Join-Path $LogDir "datadog-agent-$Version-install.log"
  $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"", "SITE=$Site")
  if ($ApiKey) { $msiArgs += "APIKEY=$ApiKey" }
  if ($Tags)   { $msiArgs += "TAGS=`"$Tags`"" }
  Write-Step "msiexec 실행 (로그: $log)"
  $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
  # 0: 성공, 3010: 성공(재부팅 필요)
  if ($p.ExitCode -notin 0, 3010) { throw "설치 실패 (msiexec 종료 코드 $($p.ExitCode)). 로그 확인: $log" }

  $now = ((& $Agent version 2>$null) -replace '^Agent (\S+).*$', '$1')
  if ($now -ne $Version) { throw "설치 후 버전이 다릅니다: $now (기대: $Version)" }
  Write-Step "완료: Datadog Agent $now$(if ($p.ExitCode -eq 3010) { ' (재부팅 필요)' })"
  Get-Service datadogagent -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, Status, StartType
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
