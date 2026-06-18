#requires -Version 5.1
<#
.SYNOPSIS
  Installs the Windows toolchain needed to build PathOfBuilding-SimpleGraphic
  (the SimpleGraphic.dll that PoB2 uses) from source.

.DESCRIPTION
  SimpleGraphic is a C++ project built with Visual Studio 2022 + CMake, with all
  third-party libraries vendored as git submodules / built through its bundled
  vcpkg. So the only things you must install yourself are:
    - Git                       (clone the repo + submodules)
    - Visual Studio 2022 Build Tools with the C++ workload (MSVC + Windows SDK)
    - CMake                     (VS ships one, but a standalone is convenient)

  Everything else (GLFW, ANGLE, curl, fmt, abseil, re2, Dear ImGui, LuaJIT, ...)
  is pulled and built by SimpleGraphic's own CMake/vcpkg during the build.

  Run this from an elevated (Administrator) PowerShell. It uses winget.

.NOTES
  After this completes, build with scripts/build-simplegraphic.ps1.
#>
[CmdletBinding()]
param(
  # Skip the (large) Visual Studio Build Tools install, e.g. if you already have
  # Visual Studio 2022 with the "Desktop development with C++" workload.
  [switch]$SkipVisualStudio
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Admin)) {
  Write-Warning "Not running as Administrator. Installing Visual Studio Build Tools usually requires elevation."
  Write-Warning "Re-run this script from an elevated PowerShell (Right-click > Run as administrator)."
  $resp = Read-Host "Continue anyway? (y/N)"
  if ($resp -ne 'y') { exit 1 }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

function Install-WinGet([string]$Id, [string]$Name, [string[]]$ExtraArgs = @()) {
  Write-Host "`n=== Installing $Name ($Id) ===" -ForegroundColor Cyan
  $args = @('install','--id',$Id,'-e','--accept-source-agreements','--accept-package-agreements') + $ExtraArgs
  & winget @args
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    # -1978335189 = "no applicable update found" / already installed; treat as ok
    Write-Warning "$Name install returned exit code $LASTEXITCODE (it may already be installed)."
  }
}

# 1. Git
Install-WinGet -Id 'Git.Git' -Name 'Git'

# 2. CMake (standalone; handy on PATH even though VS includes one)
Install-WinGet -Id 'Kitware.CMake' -Name 'CMake'

# 3. Visual Studio 2022 Build Tools + C++ workload + Windows SDK
if ($SkipVisualStudio) {
  Write-Host "`nSkipping Visual Studio Build Tools (per -SkipVisualStudio)." -ForegroundColor Yellow
} else {
  # The --override string is passed to the VS installer: add the C++ build-tools
  # workload plus the explicit MSVC, Windows 11 SDK, and CMake components.
  $vsOverride = @(
    '--quiet','--wait','--norestart',
    '--add','Microsoft.VisualStudio.Workload.VCTools',
    '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621',
    '--add','Microsoft.VisualStudio.Component.VC.CMake.Project',
    '--includeRecommended'
  ) -join ' '
  Install-WinGet -Id 'Microsoft.VisualStudio.2022.BuildTools' -Name 'VS 2022 Build Tools (C++)' `
    -ExtraArgs @('--override', $vsOverride)
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Toolchain installed. Open a NEW terminal so PATH updates take effect, then build with:" -ForegroundColor Green
Write-Host "    powershell -ExecutionPolicy Bypass -File scripts\build-simplegraphic.ps1" -ForegroundColor Green
Write-Host "(Apply the bridge keep-awake patch first - see scripts\simplegraphic-bridge-fix.md.)"
