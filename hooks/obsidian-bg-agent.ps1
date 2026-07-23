# obsidian-bg-agent.ps1 - PostCompact vault propagation hook (Windows/PowerShell)
#
# Fires after Claude compacts the conversation context. Reads the session
# summary from stdin (JSON), then runs a headless Claude agent to propagate
# everything worth preserving to the vault.
#
# Requires both env vars in ~/.claude/settings.json:
#   OBSIDIAN_VAULT_PATH          - vault directory
#   OBSIDIAN_BG_AGENT_ENABLED=1  - explicit opt-in
#
# Logs: $env:TEMP\obsidian-bg-agent.log

param()

$vault = $env:OBSIDIAN_VAULT_PATH
if ([string]::IsNullOrEmpty($vault)) { exit 0 }
if ($env:OBSIDIAN_BG_AGENT_ENABLED -ne "1") { exit 0 }

$claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
$logFile   = Join-Path $env:TEMP "obsidian-bg-agent.log"

function Write-Log { param([string]$msg)
    Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

try {
    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }

    $data = $rawInput | ConvertFrom-Json -ErrorAction Stop
    $transcriptPath = $data.transcript_path
    if ([string]::IsNullOrEmpty($transcriptPath) -or !(Test-Path $transcriptPath)) { exit 0 }

    $summary = ""
    foreach ($line in (Get-Content -Path $transcriptPath -Encoding UTF8 -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            if ($entry.isCompactSummary -eq $true) {
                $content = $entry.message.content
                if (![string]::IsNullOrEmpty($content)) { $summary = $content }
            }
        } catch {}
    }
    if ([string]::IsNullOrEmpty($summary)) { exit 0 }

    $today  = Get-Date -Format "yyyy-MM-dd"
    $prompt = "Vault propagation agent. Transcript: $transcriptPath. Vault: $vault. Today: $today. STEPS: 1) Read _CLAUDE.md at vault root. 2) Read transcript JSONL file, find entry where isCompactSummary=true, extract its message.content as the session summary. 3) Identify vault-worthy items: decisions, tasks, people, projects, dev-work, ideas, shoutouts. 4) Before creating any note, search first - no duplicates. 5) Update or create notes: people, projects, dev-logs, kanban tasks, ideas, decisions. 6) Update daily note at Daily/$today.md, create from template if missing, link all touched notes. CONSTRAINTS: Filesystem tools only. Completely silent. Never archive, delete, or merge - only add or update."

    $promptFile = [System.IO.Path]::GetTempFileName() + ".txt"
    [System.IO.File]::WriteAllText($promptFile, $prompt, [System.Text.Encoding]::UTF8)

    $vaultEsc  = $vault.Replace("'", "''")
    $exeEsc    = $claudeExe.Replace("'", "''")
    $logEsc    = $logFile.Replace("'", "''")
    $pfEsc     = $promptFile.Replace("'", "''")

    $launcher = "Set-Location '$vaultEsc'; `$p=[System.IO.File]::ReadAllText('$pfEsc',[System.Text.Encoding]::UTF8); [string[]]`$a=@('--dangerously-skip-permissions','-p',`$p); & '$exeEsc' @a 2>&1 | Out-File -Append '$logEsc' -Encoding UTF8; Remove-Item '$pfEsc' -ErrorAction SilentlyContinue"

    $launcherFile = [System.IO.Path]::GetTempFileName() + ".ps1"
    [System.IO.File]::WriteAllText($launcherFile, $launcher, [System.Text.Encoding]::UTF8)

    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NonInteractive", "-WindowStyle", "Hidden", "-File", $launcherFile) `
        -WindowStyle Hidden

    Write-Log "Background agent launched"

} catch {
    Write-Log "Error: $_"
}

exit 0
