# Builds the real form, then exercises it with only the in-memory programmer.
# Fixture settings, backups and logs are isolated from the operator's files.
param([string]$Lazarus = 'C:\lazarus32')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('nvramancer-desktop-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixture 'units'), (Join-Path $fixture 'lang'), (Join-Path $fixture 'backups') | Out-Null
Write-Host "Desktop fixture: $fixture"
& "$Lazarus\lazbuild.exe" --build-mode=Release "$root\software\NVRAMancer.lpi" *> (Join-Path $fixture 'build.log')
if ($LASTEXITCODE -ne 0) { throw "Desktop build failed: $fixture\build.log" }

# Reuse the package search paths resolved by Lazarus, without shell evaluation.
[xml]$compiled = Get-Content -LiteralPath "$root\software\lib\i386-win32\NVRAMancer.compiled" -Raw
$search = @("-Fu$root\software\lib\i386-win32")
foreach ($token in [regex]::Matches($compiled.CONFIG.Params.Value, '(?:[^\s"]|"[^"]*")+')) {
  $arg = $token.Value.Replace('"', '')
  if (($arg -cmatch '^-F[ui]') -or ($arg -cmatch '^-d')) { $search += $arg }
}
Copy-Item -LiteralPath "$root\tests\desktop_smoke.lpr" -Destination $fixture
Copy-Item -Path "$root\chiplist*.xml", "$root\software\*.dll" -Destination $fixture
[IO.File]::WriteAllBytes((Join-Path $fixture 'sample.bin'), [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
$backupDir = [Security.SecurityElement]::Escape((Join-Path $fixture 'backups'))
$settings = "<settings><options hw=`"buzzpirat`" auto_detect_hw=`"0`" auto_detect_chip=`"0`" connection_doctor_seen=`"0`" workspace=`"0`" background_ops=`"1`" backup_directory=`"$backupDir`" /></settings>"
[IO.File]::WriteAllText((Join-Path $fixture 'settings.xml'), $settings, (New-Object Text.UTF8Encoding $false))
# There is deliberately no locale setting or en.po in the fixture.
$catalog = @'
# Test language
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\n"

#: tmainform.menuoptions.caption
msgid "Options"
msgstr "Test options"
'@
[IO.File]::WriteAllText((Join-Path $fixture 'lang\test.po'), $catalog, (New-Object Text.UTF8Encoding $false))
& "$Lazarus\fpc\3.2.2\bin\i386-win32\fpc.exe" -Twin32 -Mobjfpc -Sh -WG @search "-FU$fixture\units" "-FE$fixture" "$fixture\desktop_smoke.lpr" *> (Join-Path $fixture 'compile.log')
if ($LASTEXITCODE -ne 0) { throw "Desktop smoke compile failed: $fixture\compile.log" }
$process = Start-Process -FilePath (Join-Path $fixture 'desktop_smoke.exe') -WorkingDirectory $fixture -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(45000)) {
  Stop-Process -Id $process.Id
  throw "Desktop smoke timed out: $fixture\desktop-smoke.log"
}
Get-Content -LiteralPath (Join-Path $fixture 'desktop-smoke.log')
if ($process.ExitCode -ne 0) { throw "Desktop smoke failed: $fixture\desktop-smoke.log" }
