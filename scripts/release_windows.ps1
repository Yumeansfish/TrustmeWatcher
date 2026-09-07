[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "release_windows.ps1 must run on Windows"
}

$RootDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BuildRoot = if ($env:BUILD_ROOT) {
    [System.IO.Path]::GetFullPath($env:BUILD_ROOT)
} else {
    Join-Path $RootDir "build"
}
$AppName = if ($env:APP_NAME) { $env:APP_NAME } else { "trust-me" }
$ReleaseVersion = if ($env:RELEASE_VERSION) {
    $env:RELEASE_VERSION.TrimStart("v")
} else {
    "0.0.0"
}
$AppDir = if ($env:WINDOWS_APP_DIR) {
    [System.IO.Path]::GetFullPath($env:WINDOWS_APP_DIR)
} else {
    Join-Path $BuildRoot "bin\app\$AppName"
}
$OutputDir = if ($env:WINDOWS_OUTPUT_DIR) {
    [System.IO.Path]::GetFullPath($env:WINDOWS_OUTPUT_DIR)
} else {
    Join-Path $BuildRoot "dist"
}
$InstallerScript = Join-Path $PSScriptRoot "windows_installer.iss"
$ExpectedInstaller = Join-Path $OutputDir "$AppName-windows-x86_64-setup.exe"

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Find-InnoSetupCompiler {
    if ($env:INNO_SETUP_COMPILER) {
        return [System.IO.Path]::GetFullPath($env:INNO_SETUP_COMPILER)
    }

    $command = Get-Command "iscc.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
    }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw "Inno Setup 6 compiler not found; install it or set INNO_SETUP_COMPILER"
}

if (
    [string]::IsNullOrWhiteSpace($AppName) -or
    $AppName.Contains("\") -or
    $AppName.Contains("/")
) {
    throw "APP_NAME must be a non-empty filename component"
}
if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) {
    throw "RELEASE_VERSION must not be empty"
}

Assert-File $InstallerScript
Assert-File (Join-Path $AppDir "aw-qt.exe")
Assert-File (Join-Path $AppDir "aw-server\aw-server.exe")
Assert-File (Join-Path $AppDir "aw-watcher-afk\aw-watcher-afk.exe")
Assert-File (Join-Path $AppDir "aw-watcher-window\aw-watcher-window.exe")
Assert-File (Join-Path $AppDir "aw-watcher-input\aw-watcher-input.exe")
Assert-File (Join-Path $AppDir "aw-server\aw_server\static\index.html")
Assert-File (Join-Path $AppDir "aw-server\trustme_xai\current.joblib")

$InnoSetupCompiler = Find-InnoSetupCompiler
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Remove-Item -LiteralPath $ExpectedInstaller -Force -ErrorAction SilentlyContinue

$env:APP_NAME = $AppName
$env:RELEASE_VERSION = $ReleaseVersion
$env:WINDOWS_APP_DIR = $AppDir
$env:WINDOWS_OUTPUT_DIR = $OutputDir

Write-Host "==> Packaging Windows installer"
& $InnoSetupCompiler $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup exited with code $LASTEXITCODE"
}
Assert-File $ExpectedInstaller

$Checksum = (Get-FileHash -LiteralPath $ExpectedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$ExpectedInstaller.sha256" -Value "$Checksum  $([System.IO.Path]::GetFileName($ExpectedInstaller))" -Encoding ascii

Write-Host "==> Windows installer ready: $ExpectedInstaller"
Write-Host "==> SHA256: $Checksum"
