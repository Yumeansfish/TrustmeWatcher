param(
    [string]$AppDirectory = "$env:USERPROFILE\Desktop\TrustmeWatcher\build\bin\app\trust-me"
)

$ErrorActionPreference = "Stop"
$AppDirectory = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\')

$executable = Join-Path $AppDirectory "aw-qt.exe"
if (-not (Test-Path $executable)) {
    throw "TrustmeWatcher executable not found: $executable"
}

# aw-qt and its child watchers must run in the signed-in desktop session. A
# process launched directly over SSH stays in session 0 and cannot observe the
# user's foreground window or display the questionnaire popup.
$taskName = "TrustmeWatcher-Interactive-Launch"
$userId = (whoami).Trim()
$desktop = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
    Where-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        "$($owner.Domain)\$($owner.User)" -ieq $userId
    })
if ($desktop.Count -ne 1) {
    throw "Expected one signed-in desktop for $userId; found $($desktop.Count). Unlock the intended Windows desktop first."
}
$interactiveSession = $desktop[0].SessionId

function Get-AppProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -like "aw-*" -and $_.Path -and
            $_.Path.StartsWith("$AppDirectory\", [StringComparison]::OrdinalIgnoreCase)
        }
}

# Do not stop unrelated ActivityWatch installations or another user's session.
Get-AppProcesses | Stop-Process -Force -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $executable -WorkingDirectory $AppDirectory
$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)

try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(30)
    $required = @("aw-qt", "aw-server", "aw-watcher-afk", "aw-watcher-window", "aw-watcher-input")
    do {
        Start-Sleep -Milliseconds 500
        $processes = @(Get-AppProcesses)
        $missing = @($required | Where-Object { $_ -notin $processes.ProcessName })
        $healthy = $false
        if ($missing.Count -eq 0) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5600/api/0/info" -TimeoutSec 2
                $healthy = $response.StatusCode -eq 200
            } catch { }
        }
    } while (-not $healthy -and (Get-Date) -lt $deadline)
    if (-not $healthy) {
        throw "TrustmeWatcher did not become ready. Missing processes: $($missing -join ', '). Check the aw-server and watcher logs."
    }
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

$processes = Get-AppProcesses |
    Sort-Object ProcessName |
    Select-Object ProcessName, Id, SessionId

if (-not $processes) {
    throw "TrustmeWatcher did not start."
}

$wrongSession = $processes | Where-Object { $_.SessionId -ne $interactiveSession }
if ($wrongSession) {
    throw "TrustmeWatcher started outside desktop session $interactiveSession."
}

$processes | Format-Table -AutoSize
