param(
  [Parameter(Mandatory = $true)][string]$AngleDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Match the SDK in the pinned Chromium toolchain, rather than the runner image.
$toolchainSource = Get-Content -Raw (Join-Path $AngleDir 'build/vs_toolchain.py')
$sdkMatch = [regex]::Match($toolchainSource, "(?m)^SDK_VERSION = '([0-9.]+)'\r?$")
if (-not $sdkMatch.Success) {
  throw 'Cannot determine the Windows SDK required by ANGLE'
}
$sdkVersion = $sdkMatch.Groups[1].Value
$sdkRoot = if ($env:WINDOWSSDKDIR) { $env:WINDOWSSDKDIR } else { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10' }
$requiredFiles = @(
  "Include/$sdkVersion/um/Windows.h",
  "Include/$sdkVersion/ucrt/stdio.h",
  "Include/$sdkVersion/shared/sdkddkver.h",
  "Include/$sdkVersion/winrt/windows.foundation.h",
  "Lib/$sdkVersion/um/x86/kernel32.lib",
  "Lib/$sdkVersion/um/x64/kernel32.lib",
  "Lib/$sdkVersion/um/arm64/kernel32.lib",
  "Lib/$sdkVersion/ucrt/x86/ucrt.lib",
  "Lib/$sdkVersion/ucrt/x64/ucrt.lib",
  "Lib/$sdkVersion/ucrt/arm64/ucrt.lib",
  'Debuggers/x64/dbghelp.dll',
  'Debuggers/arm64/dbghelp.dll'
)
function Get-MissingSdkFiles {
  @($requiredFiles | Where-Object { -not (Test-Path (Join-Path $sdkRoot $_) -PathType Leaf) })
}

if (@(Get-MissingSdkFiles).Count -eq 0) {
  Write-Host "Windows SDK $sdkVersion is already installed at $sdkRoot"
  return
}

# Windows SDK 10.0.28000.2270, as used by ANGLE_COMMIT's build dependency.
# https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads
if ($sdkVersion -ne '10.0.28000.0') {
  throw "Windows SDK $sdkVersion is missing; update the pinned SDK installer URL"
}
$installer = Join-Path ([System.IO.Path]::GetTempPath()) 'angle-winsdksetup.exe'
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2370315' -OutFile $installer
Write-Host "Installing Windows SDK $sdkVersion (x86, x64, ARM64) at $sdkRoot"
$process = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
  '/quiet', '/norestart', '/ceip', 'off',
  '/installpath', "`"$sdkRoot`"",
  '/features', 'OptionId.DesktopCPPx86', 'OptionId.DesktopCPPx64', 'OptionId.DesktopCPPARM64',
  'OptionId.UWPCPP', 'OptionId.WindowsDesktopDebuggers'
)
if ($process.ExitCode -notin @(0, 3010)) {
  throw "Windows SDK installer failed with exit code $($process.ExitCode)"
}
$missing = @(Get-MissingSdkFiles)
if ($missing.Count -gt 0) {
  throw "Windows SDK $sdkVersion is incomplete: $($missing -join ', ')"
}
