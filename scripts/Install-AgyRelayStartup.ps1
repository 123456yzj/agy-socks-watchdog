param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$taskName = 'Agy SOCKS Watchdog'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    return
}

. "$PSScriptRoot\AgyRelay.Common.ps1"
$config = Get-AgyRelayConfig
if (-not (Test-Path -LiteralPath $config.RelayExe -PathType Leaf)) {
    throw 'Relay executable not found. Build it into bin/ or set AGY_RELAY_EXE.'
}

New-AgyRelayLogDirectory $config.LogPath
$arguments = '-listen {0} -upstream {1} -idle-timeout {2} -log "{3}"' -f `
    $config.ListenAddress, $config.Upstream, $config.IdleTimeout, $config.LogPath
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $config.RelayExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'SOCKS5 idle-timeout relay for agy SSE connections' -Force
