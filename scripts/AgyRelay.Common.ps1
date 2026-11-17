function Get-AgyRelayConfig {
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $port = 18080
    if ($env:AGY_RELAY_PORT) {
        $port = [int]$env:AGY_RELAY_PORT
    }
    if ($port -lt 1 -or $port -gt 65535) {
        throw 'AGY_RELAY_PORT must be between 1 and 65535.'
    }

    $agyExe = Join-Path $localData 'agy\bin\agy.exe'
    if ($env:AGY_EXE) { $agyExe = $env:AGY_EXE }
    $relayExe = Join-Path $repoRoot 'bin\agy-socks-watchdog.exe'
    if ($env:AGY_RELAY_EXE) { $relayExe = $env:AGY_RELAY_EXE }
    $upstream = '127.0.0.1:10808'
    if ($env:AGY_UPSTREAM) { $upstream = $env:AGY_UPSTREAM }
    $idleTimeout = '5m'
    if ($env:AGY_IDLE_TIMEOUT) { $idleTimeout = $env:AGY_IDLE_TIMEOUT }
    $logPath = Join-Path $localData 'agy-socks-watchdog\socks-watchdog.log'
    if ($env:AGY_RELAY_LOG) { $logPath = $env:AGY_RELAY_LOG }

    [pscustomobject]@{
        AgyExe = $agyExe
        RelayExe = $relayExe
        Port = $port
        ListenAddress = "127.0.0.1:$port"
        Upstream = $upstream
        IdleTimeout = $idleTimeout
        LogPath = $logPath
        ProxyUrl = "socks5://127.0.0.1:$port"
    }
}

function New-AgyRelayLogDirectory([string]$LogPath) {
    $directory = Split-Path $LogPath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}
