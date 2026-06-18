#requires -Version 5.1
<#
.SYNOPSIS
  Clone, configure, and build PathOfBuilding-SimpleGraphic, producing a fresh
  SimpleGraphic.dll (with the MCP bridge keep-awake patch applied) and installing
  it into a PoB runtime folder.

.DESCRIPTION
  Run scripts\install-simplegraphic-buildtools.ps1 first (Git + VS 2022 C++ + CMake).

  Steps performed:
    1. git clone --recursive  (vcpkg + imgui + glm + luautf8 + Lua-cURLv3 submodules)
    2. (you apply the bridge patch - see scripts\simplegraphic-bridge-fix.md)
    3. cmake configure  (Visual Studio 17 2022, x64, vcpkg submodule toolchain)
    4. cmake --build --target INSTALL --config Release
    5. the built DLL + deps land in -InstallPrefix

  NOTE: the FIRST build is long (vcpkg compiles ANGLE, curl, abseil, ... - often
  30-90 minutes) and downloads a lot. Subsequent builds are fast. Use a path
  WITHOUT spaces (vcpkg ports can fail otherwise).

.PARAMETER WorkDir
  Where to clone/build. Default: C:\dev\PoB-SimpleGraphic-build (no spaces).

.PARAMETER InstallPrefix
  Where the INSTALL target deploys the DLL + deps. Point this at a copy of your
  PoB runtime, then copy SimpleGraphic.dll into your PoB folder.

.PARAMETER Configure
  Re-run CMake configure even if the build dir exists.
#>
[CmdletBinding()]
param(
  [string]$WorkDir       = 'C:\dev\PoB-SimpleGraphic-build',
  [string]$InstallPrefix = 'C:\dev\PoB-SimpleGraphic-build\install',
  [switch]$Configure
)

$ErrorActionPreference = 'Stop'
$repo  = 'https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic'
$src   = Join-Path $WorkDir 'PoB-SimpleGraphic'
$build = Join-Path $WorkDir 'build-SimpleGraphic'

if ($WorkDir -match '\s') { throw "WorkDir must not contain spaces (vcpkg ports break): '$WorkDir'" }

# Resolve a tool from PATH, else from its standard install locations, and put its
# directory on PATH for this session. winget's silent MSI installs often skip the
# "add to PATH" option (notably CMake), so a fresh terminal still can't find them.
function Ensure-Tool([string]$Name, [string[]]$Candidates) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($c in $Candidates) {
    if ($c -and (Test-Path $c)) {
      $env:PATH = (Split-Path $c) + ';' + $env:PATH
      Write-Host "Found $Name at $c (added its folder to PATH for this session)." -ForegroundColor DarkGray
      return $c
    }
  }
  throw "$Name not found. Run scripts\install-simplegraphic-buildtools.ps1, open a new terminal, or install $Name manually."
}

# Discover the VS-bundled cmake too, as a fallback to the standalone Kitware one.
$vsCMake = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $vsRoot = & $vswhere -latest -products * -property installationPath 2>$null
  if ($vsRoot) { $vsCMake = Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' }
}
Ensure-Tool 'git'   @("$env:ProgramFiles\Git\cmd\git.exe") | Out-Null
Ensure-Tool 'cmake' @("$env:ProgramFiles\CMake\bin\cmake.exe", $vsCMake) | Out-Null

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# 1. clone (recursive) or update submodules
if (-not (Test-Path $src)) {
  Write-Host "=== Cloning SimpleGraphic (recursive) ===" -ForegroundColor Cyan
  git clone --recursive $repo $src
} else {
  Write-Host "=== Repo present; syncing submodules ===" -ForegroundColor Cyan
  git -C $src submodule update --init --recursive
}

Write-Host "`n*** Apply the bridge keep-awake patch now if you haven't:" -ForegroundColor Yellow
Write-Host "    see scripts\simplegraphic-bridge-fix.md  (edits ui_main.h, ui_main.cpp, ui_api.cpp)" -ForegroundColor Yellow
Write-Host "    Without it, the rebuilt DLL still stalls the bridge when PoB is unfocused.`n" -ForegroundColor Yellow

# 2. configure
$toolchain = Join-Path $src 'vcpkg\scripts\buildsystems\vcpkg.cmake'
if ($Configure -or -not (Test-Path (Join-Path $build 'SimpleGraphic.sln'))) {
  Write-Host "=== CMake configure (this bootstraps vcpkg) ===" -ForegroundColor Cyan
  cmake -B $build -S $src -A x64 -G "Visual Studio 17 2022" `
    --toolchain $toolchain -DCMAKE_INSTALL_PREFIX=$InstallPrefix
}

# 3. build + install (Release)
Write-Host "=== Building INSTALL (Release) - first run is LONG ===" -ForegroundColor Cyan
cmake --build $build --config Release --target INSTALL

Write-Host "`n=== Done ===" -ForegroundColor Green
$dll = Get-ChildItem -Path $InstallPrefix -Recurse -Filter 'SimpleGraphic.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dll) {
  Write-Host "Built DLL: $($dll.FullName)" -ForegroundColor Green
  Write-Host "Copy it over your PoB runtime's SimpleGraphic.dll (back up the original first)."
} else {
  Write-Host "Build finished but SimpleGraphic.dll not found under $InstallPrefix - check the build output." -ForegroundColor Yellow
}
