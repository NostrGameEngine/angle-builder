$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ROOT_DIR = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WORK_DIR = if ($env:WORK_DIR) { $env:WORK_DIR } else { Join-Path $ROOT_DIR 'build' }
if ($env:GITHUB_ACTIONS -eq 'true') {
  $ANGLE_DEFAULT_ROOT = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'angle-builder-build' } else { Join-Path $env:TEMP 'angle-builder-build' }
} else {
  $ANGLE_DEFAULT_ROOT = $WORK_DIR
}
$ANGLE_DIR = if ($env:ANGLE_DIR) { $env:ANGLE_DIR } else { Join-Path $ANGLE_DEFAULT_ROOT 'angle' }
$ARTIFACTS_DIR = if ($env:ARTIFACTS_DIR) { $env:ARTIFACTS_DIR } else { Join-Path $ROOT_DIR 'angle-artifacts' }
$DEPOT_TOOLS_DIR = if ($env:DEPOT_TOOLS_DIR) { $env:DEPOT_TOOLS_DIR } else { Join-Path $ROOT_DIR '.cache\depot_tools' }
$ANGLE_PINNED_COMMIT = if ($env:ANGLE_PINNED_COMMIT) { $env:ANGLE_PINNED_COMMIT } elseif ($env:ANGLE_COMMIT) { $env:ANGLE_COMMIT } else { '84399673e381a301f2d4fd394a3a09450013feae' }
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = if ($env:DEPOT_TOOLS_WIN_TOOLCHAIN) { $env:DEPOT_TOOLS_WIN_TOOLCHAIN } else { '0' }
$DEPOT_TOOLS_CIPD_BIN_DIR = Join-Path $DEPOT_TOOLS_DIR '.cipd_bin'

function Log([string]$Message) {
  Write-Host "[build-windows.ps1] $Message"
}

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Script
  )

  $global:LASTEXITCODE = 0
  & $Script
  if ($LASTEXITCODE -ne 0) {
    throw "Native command failed with exit code ${LASTEXITCODE}: $Script"
  }
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)][int]$Attempts,
    [Parameter(Mandatory = $true)][int]$DelaySeconds,
    [Parameter(Mandatory = $true)][scriptblock]$Script
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      & $Script
      if ($LASTEXITCODE -ne 0) {
        throw "Native command failed with exit code ${LASTEXITCODE}: $Script"
      }
      return
    } catch {
      if ($attempt -ge $Attempts) {
        throw
      }
      Log "Command failed (attempt $attempt/$Attempts): $($_.Exception.Message)"
      Log "Retrying in ${DelaySeconds}s"
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

function Write-BuildOutputInventory {
  param(
    [Parameter(Mandatory = $true)][string]$OutDir
  )

  Log "Relevant files currently under ${OutDir}:"
  $files = Get-ChildItem -Path $OutDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(lib(EGL|GLESv2)|d3dcompiler|dxcompiler|dxil)' } |
    Sort-Object FullName |
    Select-Object -First 200

  if (-not $files) {
    Log '  <none>'
    return
  }

  foreach ($file in $files) {
    Log "  $($file.FullName)"
  }
}

function Copy-BuildOutputs {
  param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$StageDir,
    [Parameter(Mandatory = $true)][string[]]$Patterns,
    [switch]$Optional
  )

  $copied = @{}

  foreach ($pattern in $Patterns) {
    $matches = Get-ChildItem -Path $OutDir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
      Sort-Object FullName -Unique
    $duplicateNames = $matches | Group-Object Name | Where-Object { $_.Count -gt 1 }

    foreach ($duplicate in $duplicateNames) {
      $paths = ($duplicate.Group | ForEach-Object { $_.FullName }) -join ', '
      throw "Multiple build outputs named $($duplicate.Name) found under ${OutDir}: $paths"
    }

    foreach ($match in $matches) {
      if ($copied.ContainsKey($match.FullName)) {
        continue
      }

      Log "Staging $($match.FullName) -> $StageDir"
      Copy-Item -Path $match.FullName -Destination $StageDir -Force
      $copied[$match.FullName] = $true
    }
  }

  if (-not $Optional -and $copied.Count -eq 0) {
    Write-BuildOutputInventory -OutDir $OutDir
    throw "Expected build outputs not found in ${OutDir}: $($Patterns -join ', ')"
  }
}

function Get-GnExecutable {
  $gnExe = Join-Path $ANGLE_DIR 'buildtools\win\gn.exe'
  if (-not (Test-Path $gnExe -PathType Leaf)) {
    throw "GN binary not found after gclient sync: $gnExe"
  }

  return $gnExe
}

if (-not (Test-Path (Join-Path $DEPOT_TOOLS_DIR '.git'))) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DEPOT_TOOLS_DIR) | Out-Null
  Log "Cloning depot_tools into $DEPOT_TOOLS_DIR"
  Invoke-Native { git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $DEPOT_TOOLS_DIR }
}

$env:PATH = "$DEPOT_TOOLS_DIR;$DEPOT_TOOLS_CIPD_BIN_DIR;$env:PATH"

$depotToolsUpdater = Join-Path $DEPOT_TOOLS_DIR 'update_depot_tools.bat'
if (Test-Path $depotToolsUpdater -PathType Leaf) {
  Log 'Bootstrapping depot_tools'
  Invoke-Native { & $depotToolsUpdater }
}

if (Test-Path (Join-Path $ANGLE_DIR '.git')) {
  Log "Using existing ANGLE checkout at $ANGLE_DIR"
} elseif (Test-Path $ANGLE_DIR -PathType Container) {
  throw "ANGLE source tree exists but is not a git checkout: $ANGLE_DIR"
} elseif (Test-Path $ANGLE_DIR) {
  throw "ANGLE path exists but is not a directory: $ANGLE_DIR"
} else {
  New-Item -ItemType Directory -Force -Path $ANGLE_DIR | Out-Null
  if ((Split-Path -Leaf $ANGLE_DIR) -ne 'angle') {
    throw "ANGLE_DIR must be named 'angle' when using depot_tools fetch: $ANGLE_DIR"
  }
  Log 'Fetching ANGLE with depot_tools'
  Push-Location $ANGLE_DIR
  try {
    Invoke-WithRetry -Attempts 3 -DelaySeconds 15 -Script { fetch angle }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path (Join-Path $ANGLE_DIR '.git'))) {
  throw "ANGLE checkout was not created at $ANGLE_DIR"
}

Log "Checking out pinned ANGLE commit: $ANGLE_PINNED_COMMIT"
Invoke-Native { git -C $ANGLE_DIR checkout --force --detach $ANGLE_PINNED_COMMIT }

Push-Location $ANGLE_DIR
try {
  Invoke-WithRetry -Attempts 3 -DelaySeconds 15 -Script { gclient sync }
} finally {
  Pop-Location
}

$GN_EXE = Get-GnExecutable
$env:PATH = "$(Split-Path -Parent $GN_EXE);$env:PATH"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $ARTIFACTS_DIR 'natives-windows')
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $ARTIFACTS_DIR 'natives-windows-arm64')

$targets = @(
  @{ classifier = 'natives-windows'; runtime = 'windows'; arch = 'x86_64'; args = 'release-windows-x64.gn' },
  @{ classifier = 'natives-windows-arm64'; runtime = 'windows'; arch = 'arm64'; args = 'release-windows-arm64.gn' }
)

$selected = $env:BUILD_CLASSIFIER

Push-Location $ANGLE_DIR
try {
  foreach ($target in $targets) {
    if ($selected -and $target.classifier -ne $selected) {
      continue
    }

    $patchesDir = Join-Path $ROOT_DIR 'patches'
    if (Test-Path $patchesDir -PathType Container) {
      $patches = Get-ChildItem -Path $patchesDir -Filter '*.patch' -File | Sort-Object Name
      foreach ($patch in $patches) {
        git apply --reverse --check $patch.FullName *> $null
        if ($LASTEXITCODE -eq 0) {
          Log "Patch already applied: $($patch.Name)"
          continue
        }

        git apply --check $patch.FullName *> $null
        if ($LASTEXITCODE -eq 0) {
          Log "Applying patch: $($patch.Name)"
          Invoke-Native { git apply $patch.FullName }
          continue
        }

        throw "Patch does not apply cleanly: $($patch.FullName)"
      }
    }

    $outName = [System.IO.Path]::GetFileNameWithoutExtension($target.args)
    $outDir = Join-Path 'out' $outName
    $outDirFull = Join-Path $ANGLE_DIR $outDir
    $stageDir = Join-Path $ARTIFACTS_DIR "$($target.classifier)\native\angle\$($target.runtime)\$($target.arch)"

    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Copy-Item -Path (Join-Path $ROOT_DIR $target.args) -Destination (Join-Path $outDir 'args.gn') -Force
    Invoke-Native { & $GN_EXE gen $outDir }
    Log 'GN outputs for //:libEGL'
    Invoke-Native { & $GN_EXE outputs $outDir '//:libEGL' }
    Log 'GN outputs for //:libGLESv2'
    Invoke-Native { & $GN_EXE outputs $outDir '//:libGLESv2' }
    Invoke-Native { autoninja -C $outDir angle }

    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    $angleCommit = (git rev-parse HEAD).Trim()
    $angleBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -match '64') { 'x64' } else { $env:PROCESSOR_ARCHITECTURE.ToLower() }
    $buildInfo = @(
      "ANGLE_COMMIT=$angleCommit",
      "ANGLE_BRANCH=$angleBranch",
      'HOST_OS=windows',
      "HOST_ARCH=$hostArch",
      "BUILT_AT_UTC=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    )
    Set-Content -Path (Join-Path $stageDir 'ANGLE_BUILD_INFO.txt') -Value $buildInfo

    Copy-Item -Path (Join-Path $ANGLE_DIR 'LICENSE') -Destination (Join-Path $stageDir 'LICENSE.ANGLE') -Force -ErrorAction SilentlyContinue
    Copy-BuildOutputs -OutDir $outDirFull -StageDir $stageDir -Patterns @('libEGL.dll')
    Copy-BuildOutputs -OutDir $outDirFull -StageDir $stageDir -Patterns @('libGLESv2.dll')
    Copy-BuildOutputs -OutDir $outDirFull -StageDir $stageDir -Patterns @('d3dcompiler*.dll') -Optional
    Copy-BuildOutputs -OutDir $outDirFull -StageDir $stageDir -Patterns @('dxcompiler*.dll') -Optional
    Copy-BuildOutputs -OutDir $outDirFull -StageDir $stageDir -Patterns @('dxil*.dll') -Optional

    if (-not (Test-Path (Join-Path $stageDir 'libEGL.dll') -PathType Leaf)) {
      throw "Missing staged runtime DLL: $(Join-Path $stageDir 'libEGL.dll')"
    }

    if (-not (Test-Path (Join-Path $stageDir 'libGLESv2.dll') -PathType Leaf)) {
      throw "Missing staged runtime DLL: $(Join-Path $stageDir 'libGLESv2.dll')"
    }

    Remove-Item -Path (Join-Path $stageDir '*.TOC') -Force -ErrorAction SilentlyContinue
  }
} finally {
  Pop-Location
}
