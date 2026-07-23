$today     = Get-Date -Format 'yyyy-MM-dd'
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$logDir    = "$env:TEMP\obsidian-agents"
$null      = New-Item -ItemType Directory -Force $logDir
$logFile   = "$logDir\semantic-reindex-$timestamp.log"
$vault     = $env:OBSIDIAN_VAULT_PATH
$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$pyScript  = Join-Path $env:USERPROFILE '.claude\skills\obsidian-second-brain\scripts\eval\semantic_search.py'

"Started: $(Get-Date)" | Out-File $logFile -Encoding UTF8

# Strip UTF-8 BOM from any vault .md files that have it
$bomFixed = 0
Get-ChildItem $vault -Recurse -Filter '*.md' | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        [System.IO.File]::WriteAllBytes($_.FullName, $bytes[3..($bytes.Length - 1)])
        $bomFixed++
    }
}
if ($bomFixed -gt 0) { "Stripped BOM from $bomFixed file(s)" | Out-File -Append $logFile -Encoding UTF8 }

# Check if Ollama is already running
$alreadyRunning = $false
$checkResult = curl.exe -s -o NUL -w '%{http_code}' --max-time 2 'http://localhost:11434/api/tags' 2>$null
if ($checkResult -eq '200') {
    $alreadyRunning = $true
    'Ollama already running, skipping start' | Out-File -Append $logFile -Encoding UTF8
}

$ollamaProc = $null
if (-not $alreadyRunning) {
    'Starting Ollama...' | Out-File -Append $logFile -Encoding UTF8
    $ollamaProc = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -PassThru -WindowStyle Hidden

    $ready = $false
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 3
        $code = curl.exe -s -o NUL -w '%{http_code}' --max-time 2 'http://localhost:11434/api/tags' 2>$null
        if ($code -eq '200') {
            $ready = $true
            "Ollama ready after $($i * 3)s" | Out-File -Append $logFile -Encoding UTF8
            break
        }
    }

    if (-not $ready) {
        $entry = "## [$today] semantic-reindex | FAILED - Ollama did not start in 30s"
        $entry | Out-File -Append $logFile -Encoding UTF8
        Add-Content -Path "$vault\log.md" -Value $entry -Encoding UTF8
        if ($ollamaProc -and -not $ollamaProc.HasExited) {
            Stop-Process -Id $ollamaProc.Id -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
}

# obsidian-second-brain v0.12.0 changed the default embedding model from
# mxbai-embed-large to multilingual bge-m3 (env override: OBSIDIAN_EMBED_MODEL).
# Pull it once if missing - a no-op on every later run once it's local.
$embedModel = if ($env:OBSIDIAN_EMBED_MODEL) { $env:OBSIDIAN_EMBED_MODEL } else { 'bge-m3' }
$haveModel = (& $ollamaExe list 2>$null) -match [regex]::Escape($embedModel)
if (-not $haveModel) {
    "Pulling embedding model $embedModel (one-time, first run after the v0.12.0 upgrade)..." | Out-File -Append $logFile -Encoding UTF8
    & $ollamaExe pull $embedModel 2>&1 | Out-File -Append $logFile -Encoding UTF8
}

# Run the index build. -u forces unbuffered stdout/stderr so progress lines
# (e.g. "[12/460] embedding ..." and periodic "...N embedded" heartbeats) land
# as they happen, not all at once at the end. Each line is written to the log
# file immediately, parsed for a Write-Progress bar, then passed through so
# $buildOutput still collects everything for the summary parse below.
'Running index build...' | Out-File -Append $logFile -Encoding UTF8
$buildOutput = & python -u $pyScript --path $vault --build 2>&1 | ForEach-Object {
    $line = $_
    $line | Out-File -Append $logFile -Encoding UTF8

    if ($line -match '^\[semantic\] scanning (\d+) notes') {
        Write-Progress -Activity 'Semantic reindex' -Status "Scanning $($Matches[1]) notes..." -PercentComplete 0
    }
    elseif ($line -match '\[(\d+)/(\d+)\]\s+embedding\s+(.+?)\s+\.\.\.') {
        $idx = [int]$Matches[1]; $tot = [int]$Matches[2]
        $pct = [math]::Min(100, [math]::Round(($idx / $tot) * 100))
        Write-Progress -Activity 'Semantic reindex' -Status "Embedding note $idx of $tot" -CurrentOperation $Matches[3] -PercentComplete $pct
    }
    elseif ($line -match '^\s*\.\.\.(\d+) embedded, (\d+) cached, (\d+) failed so far \((\d+)s elapsed, (\d+)/(\d+) scanned\)') {
        $scanned = [int]$Matches[5]; $tot = [int]$Matches[6]
        $pct = [math]::Min(100, [math]::Round(($scanned / $tot) * 100))
        Write-Progress -Activity 'Semantic reindex' -Status "$($Matches[1]) embedded, $($Matches[2]) cached, $($Matches[3]) failed ($($Matches[4])s elapsed)" -PercentComplete $pct
    }

    $line
}
Write-Progress -Activity 'Semantic reindex' -Completed

# Stop Ollama only if we started it
if ($ollamaProc -and -not $ollamaProc.HasExited) {
    Stop-Process -Id $ollamaProc.Id -Force -ErrorAction SilentlyContinue
    'Ollama stopped' | Out-File -Append $logFile -Encoding UTF8
}

# Parse (v0.12.0+ format): "[semantic] indexed 420 notes (5 new, 415 cached, 0 excluded, 0 degraded, 0 dropped) in 12s -> ..."
$m = ($buildOutput | Out-String) | Select-String 'indexed (\d+) notes \((\d+) new, (\d+) cached, \d+ excluded, (\d+) degraded, (\d+) dropped\) in (\d+)s'
if ($m) {
    $g = $m.Matches[0].Groups
    $entry = "## [$today] semantic-reindex | $($g[2].Value) new, $($g[3].Value) cached, $($g[4].Value) degraded, $($g[5].Value) dropped, $($g[6].Value)s. Total: $($g[1].Value). Index updated."
} else {
    $entry = "## [$today] semantic-reindex | FAILED - no index output, check $logFile"
}

$entry | Out-File -Append $logFile -Encoding UTF8
Add-Content -Path "$vault\log.md" -Value $entry -Encoding UTF8
"Finished: $(Get-Date)" | Out-File -Append $logFile -Encoding UTF8
