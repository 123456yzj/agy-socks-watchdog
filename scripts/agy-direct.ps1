$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\AgyRelay.Common.ps1"
$config = Get-AgyRelayConfig
if (-not (Test-Path -LiteralPath $config.AgyExe -PathType Leaf)) {
    throw 'AGY executable not found. Install Antigravity CLI or set AGY_EXE.'
}

$oldProxy = $env:HTTPS_PROXY
try {
    $env:HTTPS_PROXY = "socks5://$($config.Upstream)"
    & $config.AgyExe @args
    $exitCode = $LASTEXITCODE
}
finally {
    $env:HTTPS_PROXY = $oldProxy
}
exit $exitCode
