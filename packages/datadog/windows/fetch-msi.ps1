<#
.SYNOPSIS
  Datadog Agent 7 Windows 공식 MSI 를 받아 서명을 검증하고 사내 저장소 디렉터리에 넣는다.

.DESCRIPTION
  - 버전을 지정하지 않으면 공식 목록(installers_v2.json)에서 최신 2개를 받는다.
  - 받은 MSI 는 Datadog 의 코드 서명(Authenticode)과 MSI 의 제품 정보(이름/버전)를 확인한 뒤에만 넣는다.
  - MSI 파일은 바꾸지 않는다 (서명 유지). 파일 이름만 사내 규칙으로 정리:
      ddagent-cli-7.86.0.msi → datadog-agent-7.86.0-x86_64.msi
  - SHA256SUMS 를 다시 만든다 (설치 스크립트가 이 값으로 검증).
  - 이미 있는 같은 이름의 파일이 내용이 다르면 덮어쓰지 않고 중단한다.

  결과 (S3 에 그대로 올림):
    dist/windows/datadog-agent7/datadog-agent-<버전>-x86_64.msi
    dist/windows/datadog-agent7/SHA256SUMS
    dist/windows/datadog-agent7/LATEST         (가장 높은 버전)

.EXAMPLE
  .\packages\datadog\windows\fetch-msi.ps1                     # 최신 2개
  .\packages\datadog\windows\fetch-msi.ps1 7.85.5 7.86.0       # 버전 지정
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Major    = '7'
$Index    = 'https://s3.amazonaws.com/ddagent-windows-stable/installers_v2.json'
$Root     = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$OutDir   = Join-Path $Root 'dist\windows\datadog-agent7'
$SignerRe = '(^|, )O="?Datadog, Inc\.?"?(,|$)'   # 코드 서명 인증서의 회사 이름 (O=)
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }

# ---------- 받을 버전과 주소 ----------
Write-Step "공식 목록 확인: $Index"
$json = Invoke-RestMethod -Uri $Index -UseBasicParsing
$avail = @{}
foreach ($p in $json.'datadog-agent'.PSObject.Properties) {
  $v = $p.Name -replace '-1$', ''
  $url = $p.Value.x86_64.url
  if ($v -match "^$Major\.\d+\.\d+$" -and $url) { $avail[$v] = $url }
}
$versions = @($args)
if ($versions.Count -eq 0) {
  $versions = @($avail.Keys | Sort-Object { [version]$_ } | Select-Object -Last 2)
  Write-Ok "최신 2개 자동 선택: $($versions -join ', ')"
}

# ---------- 다운로드 + 검증 ----------
$installer = New-Object -ComObject WindowsInstaller.Installer
function Get-MsiProperty($path, $name) {
  $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($path, 0))
  $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$name'"))
  $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
  $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
  $val = if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) } else { '' }
  $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
  [Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
  [Runtime.InteropServices.Marshal]::ReleaseComObject($db) | Out-Null
  return $val
}

foreach ($v in $versions) {
  if (-not $avail.ContainsKey($v)) { throw "공식 목록에 없는 버전입니다: $v" }
  $url  = $avail[$v]
  $name = "datadog-agent-$v-x86_64.msi"
  $dest = Join-Path $OutDir $name
  $tmp  = "$dest.part"

  Write-Step "$name"
  Write-Host "    다운로드: $url"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

  # 1) 코드 서명: 유효하고 Datadog 이 서명했는지
  $sig = Get-AuthenticodeSignature -FilePath $tmp
  if ($sig.Status -ne 'Valid') { Remove-Item $tmp; throw "서명이 유효하지 않습니다 ($($sig.Status)): $url" }
  if ($sig.SignerCertificate.Subject -notmatch $SignerRe) {
    Remove-Item $tmp; throw "서명자가 Datadog 이 아닙니다: $($sig.SignerCertificate.Subject)"
  }
  Write-Ok "서명 유효: $($sig.SignerCertificate.GetNameInfo('SimpleName', $false)) (만료 $($sig.SignerCertificate.NotAfter.ToString('yyyy-MM-dd')))"

  # 2) MSI 제품 정보: 이름과 버전이 맞는지
  $prod = Get-MsiProperty $tmp 'ProductName'
  $pver = Get-MsiProperty $tmp 'ProductVersion'
  if ($prod -notmatch 'Datadog Agent') { Remove-Item $tmp; throw "MSI 제품 이름이 다릅니다: $prod" }
  if ($pver -notlike "$v*")            { Remove-Item $tmp; throw "MSI 버전이 다릅니다: $pver (기대: $v)" }
  Write-Ok "MSI 제품: $prod $pver"

  # 3) 이미 있으면 같은 파일인지 확인 (배포된 파일을 다른 내용으로 덮어쓰지 않음)
  $hash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
  if (Test-Path $dest) {
    $old = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    Remove-Item $tmp
    if ($old -ne $hash) { throw "같은 이름의 다른 파일이 이미 있습니다: $dest (확인 후 직접 지우고 다시 실행)" }
    Write-Ok "이미 있음 (같은 파일)"
  } else {
    Move-Item $tmp $dest
    Write-Ok "저장: $dest ($([math]::Round((Get-Item $dest).Length / 1MB)) MB)"
  }
}
[Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null

# ---------- SHA256SUMS / LATEST ----------
$files = Get-ChildItem $OutDir -Filter 'datadog-agent-*-x86_64.msi' |
  Sort-Object { [version]($_.Name -replace '^datadog-agent-|-x86_64\.msi$', '') }
$lines = $files | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), (($lines -join "`n") + "`n"))
$latest = ($files | Select-Object -Last 1).Name -replace '^datadog-agent-|-x86_64\.msi$', ''
[IO.File]::WriteAllText((Join-Path $OutDir 'LATEST'), "$latest`n")
Write-Step "SHA256SUMS ($($files.Count) 개), LATEST = $latest"
$lines | ForEach-Object { Write-Host "    $_" }
