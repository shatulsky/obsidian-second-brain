$today     = Get-Date -Format 'yyyy-MM-dd'
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$logDir    = "$env:TEMP\obsidian-agents"
$null      = New-Item -ItemType Directory -Force $logDir
$logFile   = "$logDir\health-$timestamp.log"
$cmdFile   = Join-Path $env:USERPROFILE '.claude\commands\obsidian-health.md'
$vault     = $env:OBSIDIAN_VAULT_PATH
$claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$prompt    = "Read $cmdFile and carry out its instructions exactly. Vault: $vault. Today: $today. Run headlessly, no questions, save and stop."
"Started: $(Get-Date)" | Out-File $logFile -Encoding UTF8
Set-Location $vault
& $claudeExe --dangerously-skip-permissions -p $prompt 2>&1 | Out-File -Append $logFile -Encoding UTF8
"Finished: $(Get-Date)" | Out-File -Append $logFile -Encoding UTF8