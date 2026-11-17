$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\AgyRelay.Common.ps1"
$config = Get-AgyRelayConfig

if (-not (Test-Path -LiteralPath $config.AgyExe -PathType Leaf)) {
    throw 'AGY executable not found. Install Antigravity CLI or set AGY_EXE.'
}
if (-not (Test-Path -LiteralPath $config.RelayExe -PathType Leaf)) {
    throw 'Relay executable not found. Build it into bin/ or set AGY_RELAY_EXE.'
}

function Test-RelayPort {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $config.Port)
        if (-not $task.Wait(500)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

if (-not (Test-RelayPort)) {
    New-AgyRelayLogDirectory $config.LogPath
    Start-Process -FilePath $config.RelayExe -WindowStyle Hidden -ArgumentList @(
        '-listen', $config.ListenAddress,
        '-upstream', $config.Upstream,
        '-idle-timeout', $config.IdleTimeout,
        '-log', ('"{0}"' -f $config.LogPath)
    ) | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (Test-RelayPort) {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw "Relay did not start; check $($config.LogPath)"
    }
}

$oldProxy = $env:HTTPS_PROXY
try {
    $env:HTTPS_PROXY = $config.ProxyUrl
    & $config.AgyExe @args
    $exitCode = $LASTEXITCODE
}
finally {
    $env:HTTPS_PROXY = $oldProxy
}
exit $exitCode
