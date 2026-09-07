[CmdletBinding()]
param(
    [ValidateSet("server", "app")]
    [string]$Target = "app"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "build_windows.ps1 must run on Windows"
}

# Python and Poetry otherwise inherit the active Windows code page. On systems
# using a non-UTF-8 locale, Poetry's normal progress output can fail the build.
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$RootDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BuildRoot = if ($env:BUILD_ROOT) {
    [System.IO.Path]::GetFullPath($env:BUILD_ROOT)
} else {
    Join-Path $RootDir "build"
}
$ComposedDir = if ($env:COMPOSED_DIR) {
    [System.IO.Path]::GetFullPath($env:COMPOSED_DIR)
} else {
    Join-Path $BuildRoot "composed\activitywatch"
}
$XaiDir = if ($env:XAI_DIR) {
    [System.IO.Path]::GetFullPath($env:XAI_DIR)
} else {
    Join-Path $RootDir "trustme-xai"
}
$AppName = if ($env:APP_NAME) { $env:APP_NAME } else { "trust-me" }
$ReleaseVersion = if ($env:RELEASE_VERSION) {
    $env:RELEASE_VERSION.TrimStart("v")
} else {
    "0.0.0"
}

$PoetryVersion = "1.4.2"
$ToolsVenv = Join-Path $BuildRoot ".build-tools"
$BuildVenv = Join-Path $BuildRoot ".build-venv"
$WheelDir = Join-Path $BuildRoot ".vendored-wheels"

function Get-RequiredCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command not found: $Name"
    }
    return $command.Source
}

function Find-MakeCommand {
    $command = Get-Command "make.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "GnuWin32\bin\make.exe"
    }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles "GnuWin32\bin\make.exe"
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw "GNU Make not found; install it or add make.exe to PATH"
}

function Find-MakeShell {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles "Git\usr\bin\sh.exe"
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "Git\usr\bin\sh.exe"
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command "sh.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "POSIX shell not found; install Git for Windows or add sh.exe to PATH"
}

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Assert-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory not found: $Path"
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath exited with code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-PythonSnippet {
    param(
        [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$Code,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $SnippetPath = Join-Path $BuildRoot (
        ".build-snippet-{0}.py" -f [guid]::NewGuid().ToString("N")
    )
    [System.IO.File]::WriteAllText(
        $SnippetPath,
        $Code,
        (New-Object System.Text.UTF8Encoding $false)
    )
    try {
        Invoke-Native $Python (@($SnippetPath) + $Arguments) $WorkingDirectory
    } finally {
        Remove-Item -LiteralPath $SnippetPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-Directory $Source
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
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

$PythonExe = if ($env:BUILD_PYTHON) {
    [System.IO.Path]::GetFullPath($env:BUILD_PYTHON)
} else {
    Get-RequiredCommand "python.exe"
}
$MakeExe = Find-MakeCommand
$MakeShell = Find-MakeShell
$env:PATH = "$(Split-Path -Parent $MakeShell);$env:PATH"

Assert-Directory $ComposedDir
Assert-Directory $XaiDir
Assert-File (Join-Path $ComposedDir "pyproject.toml")
Assert-File (Join-Path $ComposedDir "poetry.lock")
Assert-File (Join-Path $ComposedDir "aw-server\aw_server\static\index.html")
Assert-File (Join-Path $XaiDir "pyproject.toml")

$PythonVersion = & $PythonExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
if ($LASTEXITCODE -ne 0 -or $PythonVersion.Trim() -ne "3.11") {
    throw "Windows binary builds require Python 3.11; found $PythonVersion at $PythonExe"
}

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null

$ToolsPython = Join-Path $ToolsVenv "Scripts\python.exe"
$PoetryExe = Join-Path $ToolsVenv "Scripts\poetry.exe"
$RebuildTools = -not (Test-Path -LiteralPath $PoetryExe -PathType Leaf)
if (-not $RebuildTools) {
    $InstalledPoetry = & $PoetryExe --version 2>$null
    $RebuildTools = $LASTEXITCODE -ne 0 -or $InstalledPoetry -ne "Poetry (version $PoetryVersion)"
}
if ($RebuildTools) {
    Write-Host "==> Creating isolated Poetry environment"
    Remove-Item -LiteralPath $ToolsVenv -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-Native $PythonExe @("-m", "venv", $ToolsVenv) $RootDir
    Invoke-Native $ToolsPython @(
        "-m", "pip", "install", "--disable-pip-version-check", "poetry==$PoetryVersion"
    ) $RootDir
}

Write-Host "==> Creating isolated Windows binary environment"
Remove-Item -LiteralPath $BuildVenv -Recurse -Force -ErrorAction SilentlyContinue
Invoke-Native $PythonExe @("-m", "venv", $BuildVenv) $RootDir

$BuildScripts = Join-Path $BuildVenv "Scripts"
$ToolsScripts = Join-Path $ToolsVenv "Scripts"
$BuildPython = Join-Path $BuildScripts "python.exe"
$env:VIRTUAL_ENV = $BuildVenv
$env:PATH = "$BuildScripts;$ToolsScripts;$env:PATH"
$env:POETRY_VIRTUALENVS_CREATE = "false"
$env:POETRY_NO_INTERACTION = "1"
$env:POETRY_KEYRING_ENABLED = "false"
$env:PYTHON_KEYRING_BACKEND = "keyring.backends.null.Keyring"
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
$env:PIP_NO_INPUT = "1"
$env:PIP_REQUIRE_VIRTUALENV = "true"
$env:POETRY_CONFIG_DIR = Join-Path $BuildRoot ".poetry\config"
$env:POETRY_CACHE_DIR = Join-Path $BuildRoot ".poetry\cache"
$env:POETRY_DATA_DIR = Join-Path $BuildRoot ".poetry\data"
$env:PIP_CACHE_DIR = Join-Path $BuildRoot ".pip-cache"
$env:PYINSTALLER_CONFIG_DIR = Join-Path $BuildRoot ".pyinstaller"
$env:GIT_CEILING_DIRECTORIES = $BuildRoot

@(
    $env:POETRY_CONFIG_DIR,
    $env:POETRY_CACHE_DIR,
    $env:POETRY_DATA_DIR,
    $env:PIP_CACHE_DIR,
    $env:PYINSTALLER_CONFIG_DIR
) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

Write-Host "==> Installing upstream-locked build tools"
Invoke-Native $PoetryExe @("install", "--no-interaction", "--no-root") $ComposedDir

$Modules = @("aw-core", "aw-client", "aw-server")
if ($Target -eq "app") {
    $Modules += @("aw-qt", "aw-watcher-afk", "aw-watcher-window", "aw-watcher-input")
}

foreach ($Module in $Modules) {
    $ModuleDir = Join-Path $ComposedDir $Module
    Assert-Directory $ModuleDir
    Assert-File (Join-Path $ModuleDir "pyproject.toml")
    Write-Host "==> Building upstream module $Module"
    Invoke-Native $MakeExe @(
        "-C", $ModuleDir, "build", "SKIP_WEBUI=true", "SHELL=sh.exe"
    ) $ComposedDir
}

Invoke-Native $PoetryExe @("install", "--no-interaction", "--no-root") $ComposedDir

Write-Host "==> Restoring packages from the composed source"
Remove-Item -LiteralPath $WheelDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $WheelDir -Force | Out-Null
$VendoredModules = @("aw-core", "aw-client")
if ($Target -eq "app") {
    $VendoredModules += "aw-watcher-afk"
}
$Wheels = @()
foreach ($Module in $VendoredModules) {
    $ModuleDir = Join-Path $ComposedDir $Module
    $ModuleDist = Join-Path $ModuleDir "dist"
    Remove-Item -LiteralPath $ModuleDist -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-Native $PoetryExe @("build", "--format", "wheel") $ModuleDir
    $BuiltWheels = @(Get-ChildItem -LiteralPath $ModuleDist -Filter "*.whl")
    if ($BuiltWheels.Count -ne 1) {
        throw "Expected one wheel for $Module in $ModuleDist; found $($BuiltWheels.Count)"
    }
    $CopiedWheel = Join-Path $WheelDir $BuiltWheels[0].Name
    Copy-Item -LiteralPath $BuiltWheels[0].FullName -Destination $CopiedWheel -Force
    $Wheels += $CopiedWheel
}
Invoke-Native $BuildPython (@("-m", "pip", "install", "--no-deps", "--force-reinstall") + $Wheels) $RootDir

Write-Host "==> Installing Trustme XAI runtime"
Invoke-Native $BuildPython @("-m", "pip", "install", "--no-compile", $XaiDir, "-r", (Join-Path $RootDir "backend\requirements.txt")) $RootDir

$LockVerification = @'
from importlib.metadata import version
from pathlib import Path
import re
import sys

lock_text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r'\[\[package\]\]\s+name = "pyinstaller"\s+version = "([^"]+)"',
    lock_text,
)
if match is None:
    raise SystemExit("unable to find PyInstaller in the upstream poetry.lock")
installed = version("pyinstaller")
if installed != match.group(1):
    raise SystemExit(f"PyInstaller does not match upstream lock: {installed} != {match.group(1)}")
print(f"==> Verified upstream-locked PyInstaller {installed}")
'@
Invoke-PythonSnippet $BuildPython $LockVerification @(
    (Join-Path $ComposedDir "poetry.lock")
) $RootDir

$ServerDir = Join-Path $ComposedDir "aw-server"
Invoke-Native $PoetryExe @("version", $ReleaseVersion) $ServerDir
$VersionUpdate = @'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")
updated, replacements = re.subn(
    r'^__version__ = "[^"]+"$',
    f'__version__ = "v{version}"',
    text,
    flags=re.MULTILINE,
)
if replacements != 1:
    raise SystemExit(f"expected one aw-server version in {path}; found {replacements}")
path.write_text(updated, encoding="utf-8")
'@
Invoke-PythonSnippet $BuildPython $VersionUpdate @(
    (Join-Path $ServerDir "aw_server\__about__.py"),
    $ReleaseVersion
) $RootDir

$ModelVerification = @'
from pathlib import Path
import sys

server_dir = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(server_dir))

from trustme_xai.contracts import MODEL_TARGETS
from trustme_xai.inference.action_classifier import load_action_classifier_runtime
from trustme_xai.inference.action_classifier_contract import ACTION_CLASSIFIER_MODEL_VERSION
from trustme_xai.inference.compact_contract import COMPACT_MODEL_VERSION
from trustme_xai.inference.model_runtime import load_model_bundle

bundle = load_model_bundle(server_dir / "trustme_xai" / "current.joblib")
if (
    bundle.feature_set != COMPACT_MODEL_VERSION
    or bundle.targets != MODEL_TARGETS
):
    raise SystemExit("bundled model does not expose the expected compact runtime contract")
classifier = load_action_classifier_runtime(
    server_dir / "trustme_xai" / "action_classifier.joblib"
)
if classifier.model_version != ACTION_CLASSIFIER_MODEL_VERSION:
    raise SystemExit("bundled action classifier does not expose the expected contract")
print("==> Verified bundled model-output artifact")
'@
Invoke-PythonSnippet $BuildPython $ModelVerification @($ServerDir) $RootDir

$PackageModules = if ($Target -eq "server") {
    @("aw-server")
} else {
    @("aw-server", "aw-qt", "aw-watcher-afk", "aw-watcher-window", "aw-watcher-input")
}
$PyInstallerExe = Join-Path $BuildScripts "pyinstaller.exe"
foreach ($Module in $PackageModules) {
    $ModuleDir = Join-Path $ComposedDir $Module
    Write-Host "==> Packaging upstream module $Module"
    Invoke-Native $PyInstallerExe @(
        "$Module.spec", "--clean", "--noconfirm"
    ) $ModuleDir
    if ($Module -eq "aw-watcher-input") {
        $VisualizationDir = Join-Path $ModuleDir "visualization\dist"
        if (Test-Path -LiteralPath $VisualizationDir -PathType Container) {
            Copy-DirectoryContents $VisualizationDir (
                Join-Path $ModuleDir "dist\visualization"
            )
        }
    }
}

$RequiredResources = @(
    "aw_server\settings\aw-category-export.json",
    "aw_server\static\index.html",
    "trustme_xai\action_classifier.joblib",
    "trustme_xai\current.joblib",
    "trustme_xai\feature_pipeline\category_rules.json",
    "trustme_xai\feature_pipeline\behavior_state_model.json",
    "trustme_xai\inference\compact_aw_v2.json"
)

if ($Target -eq "server") {
    $ServerSource = Join-Path $ServerDir "dist\aw-server"
    $ServerOutput = Join-Path $BuildRoot "bin\server\aw-server"
    Remove-Item -LiteralPath $ServerOutput -Recurse -Force -ErrorAction SilentlyContinue
    Copy-DirectoryContents $ServerSource $ServerOutput
    Assert-File (Join-Path $ServerOutput "aw-server.exe")
    foreach ($Resource in $RequiredResources) {
        Assert-File (Join-Path $ServerOutput $Resource)
    }
    if (Test-Path -LiteralPath (Join-Path $ServerOutput "aw_server\deployment.toml")) {
        throw "Server payload must not contain deployment.toml"
    }
    Invoke-Native (Join-Path $ServerOutput "aw-server.exe") @("--version") $RootDir
    Write-Host "==> Windows server binary ready: $ServerOutput"
    exit 0
}

$AppOutput = Join-Path $BuildRoot "bin\app\$AppName"
Remove-Item -LiteralPath $AppOutput -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $AppOutput -Force | Out-Null
Copy-DirectoryContents (Join-Path $ComposedDir "aw-qt\dist\aw-qt") $AppOutput
foreach ($Module in @("aw-server", "aw-watcher-afk", "aw-watcher-window", "aw-watcher-input")) {
    Copy-DirectoryContents (
        Join-Path $ComposedDir "$Module\dist\$Module"
    ) (Join-Path $AppOutput $Module)
}

Assert-File (Join-Path $AppOutput "aw-qt.exe")
foreach ($Module in @("aw-server", "aw-watcher-afk", "aw-watcher-window", "aw-watcher-input")) {
    Assert-File (Join-Path $AppOutput "$Module\$Module.exe")
}
foreach ($Resource in $RequiredResources) {
    Assert-File (Join-Path $AppOutput "aw-server\$Resource")
}
if (Test-Path -LiteralPath (Join-Path $AppOutput "aw-server\aw_server\deployment.toml")) {
    throw "Application payload must not contain deployment.toml"
}
Invoke-Native (Join-Path $AppOutput "aw-server\aw-server.exe") @("--version") $RootDir
Write-Host "==> Windows application ready: $AppOutput"
