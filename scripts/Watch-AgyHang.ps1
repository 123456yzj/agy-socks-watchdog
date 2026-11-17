param(
    [ValidateRange(1, 1440)]
    [int]$Minutes = 3,

    [ValidateRange(2, 3600)]
    [int]$PollSeconds = 15,

    [switch]$Once
)

$conversationDir = Join-Path $HOME '.gemini\antigravity-cli\conversations'
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
$alertedAt = @{}

function Get-LastDatabaseWriteUtc([System.IO.FileInfo]$database) {
    $lastWrite = $database.LastWriteTimeUtc
    $wal = Get-Item -LiteralPath ($database.FullName + '-wal') -ErrorAction SilentlyContinue
    if ($wal -and $wal.LastWriteTimeUtc -gt $lastWrite) {
        $lastWrite = $wal.LastWriteTimeUtc
    }
    return $lastWrite
}

do {
    $now = [DateTime]::UtcNow
    foreach ($database in Get-ChildItem -LiteralPath $conversationDir -Filter '*.db' -File) {
        $pending = & $sqlite -readonly -noheader $database.FullName "SELECT group_concat(idx || ':' || step_type, ',') FROM steps WHERE status=8;" 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pending)) {
            $alertedAt.Remove($database.FullName)
            continue
        }

        $lastWrite = Get-LastDatabaseWriteUtc $database
        $age = $now - $lastWrite
        if ($age.TotalMinutes -lt $Minutes) {
            $alertedAt.Remove($database.FullName)
            continue
        }

        $activityKey = $lastWrite.Ticks
        if ($alertedAt[$database.FullName] -eq $activityKey) {
            continue
        }
        $alertedAt[$database.FullName] = $activityKey
        [Console]::Beep(1000, 250)
        Write-Warning ("agy may be stuck: {0}, status=8 steps [{1}], no DB/WAL update for {2:N1} minutes. Press Esc in agy, then retry." -f $database.Name, $pending, $age.TotalMinutes)
    }

    if (-not $Once) {
        Start-Sleep -Seconds $PollSeconds
    }
} while (-not $Once)
