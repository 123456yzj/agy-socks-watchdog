$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent

foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors) { throw "$($file.Name): $parseErrors" }
}

$names = @('AGY_EXE', 'AGY_RELAY_EXE', 'AGY_RELAY_PORT', 'AGY_UPSTREAM',
    'AGY_IDLE_TIMEOUT', 'AGY_RELAY_LOG', 'AGY_TEST_CAPTURE', 'HTTPS_PROXY')
$saved = @{}
foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('agy-relay-test-' + [guid]::NewGuid())
$relayProcess = $null
$autoStartedPort = $null

function Get-TestAutoRelay {
    if (-not $autoStartedPort) { return }
    $pattern = [regex]::Escape("-listen 127.0.0.1:$autoStartedPort") + '(\s|$)'
    Get-CimInstance Win32_Process -Filter "Name = 'agy-socks-watchdog.exe'" |
        Where-Object { $_.ExecutablePath -eq $env:AGY_RELAY_EXE -and $_.CommandLine -match $pattern }
}

try {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null) }
    . (Join-Path $root 'scripts\AgyRelay.Common.ps1')
    $config = Get-AgyRelayConfig
    if ($config.Port -ne 18080 -or $config.IdleTimeout -ne '5m') {
        throw 'Unexpected wrapper defaults.'
    }
    $env:AGY_RELAY_PORT = '0'
    $rejected = $false
    try { Get-AgyRelayConfig | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid port was accepted.' }

    New-Item -ItemType Directory -Path $temp | Out-Null
    $env:AGY_EXE = Join-Path $temp 'fake-agy.cmd'
    $env:AGY_TEST_CAPTURE = Join-Path $temp 'capture.txt'
    @'
@echo off
> "%AGY_TEST_CAPTURE%" echo proxy=%HTTPS_PROXY%
>> "%AGY_TEST_CAPTURE%" echo arg1=%~1
>> "%AGY_TEST_CAPTURE%" echo arg2=%~2
exit /b 7
'@ | Set-Content -LiteralPath $env:AGY_EXE -Encoding ASCII
    $env:HTTPS_PROXY = 'http://127.0.0.1:19099'
    $env:AGY_UPSTREAM = '127.0.0.1:19098'
    $env:AGY_RELAY_PORT = '18080'

    & (Join-Path $root 'scripts\agy-direct.ps1') --print 'hello world'
    if ($LASTEXITCODE -ne 7) { throw 'Direct wrapper did not preserve exit code.' }
    $capture = Get-Content -LiteralPath $env:AGY_TEST_CAPTURE
    if ($capture[0] -ne 'proxy=socks5://127.0.0.1:19098' -or
        $capture[1] -ne 'arg1=--print' -or $capture[2] -ne 'arg2=hello world') {
        throw 'Direct wrapper did not preserve proxy configuration or arguments.'
    }
    if ($env:HTTPS_PROXY -ne 'http://127.0.0.1:19099') {
        throw 'Direct wrapper did not restore HTTPS_PROXY.'
    }

    # Use a separate port/process; never start, stop, or reconfigure the installed relay.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $env:AGY_RELAY_PORT = [string]$listener.LocalEndpoint.Port
    $listener.Stop()
    $env:AGY_RELAY_EXE = Join-Path $root 'bin\agy-socks-watchdog.exe'
    $env:AGY_RELAY_LOG = Join-Path $temp 'relay.log'
    $relayProcess = Start-Process -FilePath $env:AGY_RELAY_EXE -PassThru -WindowStyle Hidden `
        -ArgumentList @('-listen', "127.0.0.1:$env:AGY_RELAY_PORT", '-idle-timeout', '2s')
    $ready = $false
    for ($i = 0; $i -lt 50; $i++) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('127.0.0.1', [int]$env:AGY_RELAY_PORT)
            $ready = $true
            break
        }
        catch { Start-Sleep -Milliseconds 50 }
        finally { $client.Dispose() }
    }
    if (-not $ready) { throw 'Test relay did not start.' }
    & (Join-Path $root 'scripts\agy.ps1') --print 'hello world'
    if ($LASTEXITCODE -ne 7) { throw 'Safe wrapper did not preserve exit code.' }
    $capture = Get-Content -LiteralPath $env:AGY_TEST_CAPTURE
    if ($capture[0] -ne "proxy=socks5://127.0.0.1:$env:AGY_RELAY_PORT" -or
        $capture[1] -ne 'arg1=--print' -or $capture[2] -ne 'arg2=hello world') {
        throw 'Safe wrapper did not preserve proxy configuration or arguments.'
    }
    if ($env:HTTPS_PROXY -ne 'http://127.0.0.1:19099') {
        throw 'Safe wrapper did not restore HTTPS_PROXY.'
    }
    $relayProcess.Kill()
    $relayProcess.WaitForExit()
    $relayProcess = $null
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $env:AGY_RELAY_PORT = [string]$listener.LocalEndpoint.Port
    $listener.Stop()
    $autoStartedPort = $env:AGY_RELAY_PORT
    $env:AGY_IDLE_TIMEOUT = '7s'
    $env:AGY_RELAY_LOG = Join-Path $temp 'logs with spaces\relay.log'
    & (Join-Path $root 'scripts\agy-safe.ps1') --print 'hello world'
    if ($LASTEXITCODE -ne 7) { throw 'On-demand wrapper did not preserve exit code.' }
    if (-not (Get-TestAutoRelay)) { throw 'On-demand relay process was not found.' }
    if (-not (Select-String -LiteralPath $env:AGY_RELAY_LOG -Pattern 'idle timeout 7s')) {
        throw 'On-demand relay did not use the configured timeout or spaced log path.'
    }
    if ($env:HTTPS_PROXY -ne 'http://127.0.0.1:19099') {
        throw 'On-demand wrapper did not restore HTTPS_PROXY.'
    }
    Write-Output 'PASS: script syntax, configuration, arguments, exit codes, proxy restoration and on-demand startup with spaced log path.'
}
finally {
    if ($relayProcess -and -not $relayProcess.HasExited) { $relayProcess.Kill(); $relayProcess.WaitForExit() }
    foreach ($process in Get-TestAutoRelay) {
        Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
