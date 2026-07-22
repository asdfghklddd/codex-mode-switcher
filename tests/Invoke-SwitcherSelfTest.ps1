$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$switcher = Join-Path $repoRoot "Switch-CodexMode.ps1"
$powershell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powershell) {
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue
}
if (-not $powershell) {
    throw "pwsh/powershell was not found on PATH."
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-HashMap {
    param([string[]]$Paths)

    $hashes = @{}
    foreach ($path in $Paths) {
        $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return $hashes
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-mode-switcher-test-$([Guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot ".codex"
$sessionsPath = Join-Path $codexHome "sessions"
$archivedSessionsPath = Join-Path $codexHome "archived_sessions"
$protectedPaths = @(
    (Join-Path $sessionsPath "sentinel.jsonl"),
    (Join-Path $archivedSessionsPath "sentinel.jsonl"),
    (Join-Path $codexHome "state_5.sqlite"),
    (Join-Path $codexHome ".codex-global-state.json")
)

try {
    New-Item -ItemType Directory -Path $sessionsPath -Force | Out-Null
    New-Item -ItemType Directory -Path $archivedSessionsPath -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value @'
model = "gpt-test"
model_provider = "custom"

[model_providers.codex_local_access]
name = "Cockpit Test"
wire_api = "responses"

[model_providers.custom]
name = "CC Switch Test"
wire_api = "responses"
'@
    Set-Content -LiteralPath $protectedPaths[0] -Encoding UTF8 -Value '{"type":"session_meta","payload":{"model_provider":"custom"}}'
    Set-Content -LiteralPath $protectedPaths[1] -Encoding UTF8 -Value '{"type":"session_meta","payload":{"model_provider":"custom"}}'
    Set-Content -LiteralPath $protectedPaths[2] -Encoding UTF8 -Value 'sentinel state bytes must not change'
    Set-Content -LiteralPath $protectedPaths[3] -Encoding UTF8 -Value '{"sentinel":"must not change"}'

    $before = Get-HashMap -Paths $protectedPaths

    foreach ($mode in @("Status", "Normal", "Cockpit", "CCSwitch")) {
        & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $switcher -Mode $mode -CodexHome $codexHome | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Switcher failed in $mode mode."
        }
    }

    $config = Get-Content -Raw -LiteralPath (Join-Path $codexHome "config.toml")
    Assert-True ($config -match '(?m)^model_provider\s*=\s*"custom"\s*$') "Expected CCSwitch to be the final top-level provider."

    $after = Get-HashMap -Paths $protectedPaths
    foreach ($path in $protectedPaths) {
        Assert-True ($before[$path] -eq $after[$path]) "Switcher changed protected session storage: $path"
    }

    $backupCount = @(Get-ChildItem -LiteralPath $codexHome -Directory -Force |
        Where-Object Name -Like "backup-*-codex-mode-switch").Count
    Assert-True ($backupCount -eq 0) "Switcher unexpectedly created a backup directory."

    Write-Host "Self-test passed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
