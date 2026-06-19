#requires -Version 5.1
<#
.SYNOPSIS
  Clone, configure, and build PathOfBuilding-SimpleGraphic, producing a fresh
  SimpleGraphic.dll (with the MCP bridge keep-awake patch applied) and installing
  it into a PoB runtime folder.

.DESCRIPTION
  Run scripts\install-simplegraphic-buildtools.ps1 first (Git + VS 2022 C++ + CMake).

  Builds from the FORK branch that already carries the SetForceFrames patch
  (default bct8925/PathOfBuilding-SimpleGraphic @ feature/force-frames), so there
  is no manual patching step. See FORK.md in that repo for the patch + how to
  rebase it onto new upstream releases.

  Steps performed:
    1. git clone --recursive the fork branch (or sync an existing clone to it)
    2. cmake configure  (Visual Studio 17 2022, x64, vcpkg submodule toolchain)
    3. cmake --build --target INSTALL --config Release
    4. the built DLL + deps land in -InstallPrefix

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
  # The fork + branch that carries the SetForceFrames patch. Override to build a
  # different fork/branch (e.g. upstream master to compare).
  [string]$Repo          = 'https://github.com/bct8925/PathOfBuilding-SimpleGraphic',
  [string]$Branch        = 'feature/force-frames',
  [switch]$Configure
)

$ErrorActionPreference = 'Stop'
$repo  = $Repo
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

# 1. clone the fork branch, or sync an existing clone to it (picks up rebases /
#    force-pushes; re-points origin if an older clone tracked a different remote)
if (-not (Test-Path $src)) {
  Write-Host "=== Cloning $repo ($Branch, recursive) ===" -ForegroundColor Cyan
  git clone --recursive --branch $Branch $repo $src
} else {
  Write-Host "=== Repo present; syncing to $Branch ===" -ForegroundColor Cyan
  git -C $src remote set-url origin $repo
  git -C $src fetch origin
  git -C $src checkout $Branch
  git -C $src reset --hard "origin/$Branch"   # discards local edits; the patch is committed on the branch
  git -C $src submodule update --init --recursive
}

# Sanity: confirm the SetForceFrames patch is actually in the source we're about
# to build (guards against accidentally pointing at an unpatched repo/branch).
if (-not (Select-String -Path (Join-Path $src 'ui_api.cpp') -SimpleMatch 'SetForceFrames' -Quiet)) {
  throw "Source at $src does not contain the SetForceFrames patch - wrong -Repo/-Branch? (expected $Repo @ $Branch)"
}
Write-Host "SetForceFrames patch present in source." -ForegroundColor DarkGray

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
