<#
.SYNOPSIS
    Switches the top-level Codex provider without touching conversation data.

.DESCRIPTION
    This tool changes only the top-level model_provider entry in config.toml.
    It never reads, copies, rewrites, indexes, archives, migrates, or deletes
    sessions, archived sessions, SQLite databases, global state, auth, or backups.
    Every Codex app must use the same CODEX_HOME to share local conversations.
#>

param(
    [ValidateSet("Normal", "Cockpit", "CCSwitch", "Status")]
    [string]$Mode = "Status",

    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),

    [string]$CockpitProvider = "codex_local_access",

    [string]$CCSwitchProvider = "custom",

    [string]$OpenAIProvider = "openai",

    # Kept so existing shortcuts and command lines remain compatible.
    [string]$ProjectlessRoot = (Join-Path (Join-Path $HOME "Documents") "Codex"),

    # Kept as a no-op for backward compatibility. Session rewriting is removed.
    [switch]$SkipThreadRewrite
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "CodexHome not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-ConfigNewline {
    param([string]$Config)

    if ($Config.Contains("`r`n")) {
        return "`r`n"
    }

    return "`n"
}

function Get-ConfigLines {
    param([string]$Config)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Config -split "`r?`n")) {
        $lines.Add($line)
    }

    return ,$lines
}

function Join-ConfigLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Newline
    )

    return (($Lines -join $Newline).TrimEnd("`r", "`n") + $Newline)
}

function Get-TopLevelEndIndex {
    param([System.Collections.Generic.List[string]]$Lines)

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            return $index
        }
    }

    return $Lines.Count
}

function Get-TopLevelConfigValue {
    param(
        [string]$Config,
        [string]$Name
    )

    $lines = Get-ConfigLines -Config $Config
    $endIndex = Get-TopLevelEndIndex -Lines $lines
    for ($index = 0; $index -lt $endIndex; $index++) {
        $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]+)"\s*$'
        $match = [regex]::Match($lines[$index], $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return $null
}

function Remove-TopLevelProvider {
    param(
        [string]$Config,
        [string[]]$ProviderNames
    )

    $newline = Get-ConfigNewline -Config $Config
    $lines = Get-ConfigLines -Config $Config
    $endIndex = Get-TopLevelEndIndex -Lines $lines

    for ($index = $endIndex - 1; $index -ge 0; $index--) {
        $match = [regex]::Match($lines[$index], '^\s*model_provider\s*=\s*"([^"]+)"\s*$')
        if ($match.Success -and $ProviderNames -contains $match.Groups[1].Value) {
            $lines.RemoveAt($index)
        }
    }

    return Join-ConfigLines -Lines $lines -Newline $newline
}

function Set-TopLevelProvider {
    param(
        [string]$Config,
        [string]$Provider
    )

    $newline = Get-ConfigNewline -Config $Config
    $lines = Get-ConfigLines -Config $Config
    $endIndex = Get-TopLevelEndIndex -Lines $lines

    for ($index = $endIndex - 1; $index -ge 0; $index--) {
        if ($lines[$index] -match '^\s*model_provider\s*=') {
            $lines.RemoveAt($index)
        }
    }

    $endIndex = Get-TopLevelEndIndex -Lines $lines
    $insertAt = 0
    for ($index = 0; $index -lt $endIndex; $index++) {
        if ($lines[$index] -match '^\s*model\s*=') {
            $insertAt = $index + 1
            break
        }
    }

    $lines.Insert($insertAt, ('model_provider = "{0}"' -f $Provider))
    return Join-ConfigLines -Lines $lines -Newline $newline
}

function Get-ProviderBlock {
    param(
        [string]$Config,
        [string]$Provider
    )

    $header = [regex]::Escape("[model_providers.$Provider]")
    $match = [regex]::Match($Config, ("(?ms)^" + $header + "\s*\r?\n.*?(?=^\[|\z)"))
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

function Get-ProviderField {
    param(
        [string]$Block,
        [string]$Name
    )

    if (-not $Block) {
        return $null
    }

    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*"?([^"\r\n]+)"?\s*$'
    $match = [regex]::Match($Block, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}

function Assert-ProviderBlock {
    param(
        [string]$Config,
        [string]$Provider,
        [string]$ModeName
    )

    if (-not (Get-ProviderBlock -Config $Config -Provider $Provider)) {
        throw "Provider block [model_providers.$Provider] is missing for $ModeName. Configure it with the native provider tool first."
    }
}

function Get-ProviderSummary {
    param(
        [string]$Config,
        [string]$Provider
    )

    $block = Get-ProviderBlock -Config $Config -Provider $Provider
    return [pscustomobject]@{
        Provider = $Provider
        Present = [bool]$block
        Name = Get-ProviderField -Block $block -Name "name"
        WireApi = Get-ProviderField -Block $block -Name "wire_api"
    }
}

function Get-LegacyBackupCount {
    param([string]$CodexHomePath)

    return @(Get-ChildItem -LiteralPath $CodexHomePath -Directory -Force |
        Where-Object { $_.Name -like "backup-*-codex-mode-switch" }).Count
}

function Write-Rule {
    param([string]$Text)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host ("  " + $Text)
    Write-Host "============================================================"
}

function Write-Kv {
    param(
        [string]$Name,
        $Value
    )

    $displayValue = if ($null -eq $Value -or $Value -eq "") { "<none>" } else { [string]$Value }
    Write-Host ("  {0,-34} {1}" -f $Name, $displayValue)
}

$resolvedCodexHome = Resolve-ExistingDirectory -Path $CodexHome
$configPath = Join-Path $resolvedCodexHome "config.toml"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "config.toml not found: $configPath"
}

$originalConfig = [System.IO.File]::ReadAllText($configPath)
$updatedConfig = $originalConfig
$targetProvider = $null

switch ($Mode) {
    "Normal" {
        $updatedConfig = Remove-TopLevelProvider -Config $originalConfig -ProviderNames @(
            $CockpitProvider,
            $CCSwitchProvider,
            $OpenAIProvider,
            "Codex API Service"
        )
        $targetProvider = "OpenAI default"
    }
    "Cockpit" {
        Assert-ProviderBlock -Config $originalConfig -Provider $CockpitProvider -ModeName $Mode
        $updatedConfig = Set-TopLevelProvider -Config $originalConfig -Provider $CockpitProvider
        $targetProvider = $CockpitProvider
    }
    "CCSwitch" {
        Assert-ProviderBlock -Config $originalConfig -Provider $CCSwitchProvider -ModeName $Mode
        $updatedConfig = Set-TopLevelProvider -Config $originalConfig -Provider $CCSwitchProvider
        $targetProvider = $CCSwitchProvider
    }
    "Status" {
        $targetProvider = "<read-only>"
    }
}

$configChanged = $false
if ($Mode -ne "Status" -and -not [string]::Equals($originalConfig, $updatedConfig, [System.StringComparison]::Ordinal)) {
    [System.IO.File]::WriteAllText($configPath, $updatedConfig, [System.Text.UTF8Encoding]::new($false))
    $configChanged = $true
}

$effectiveConfig = if ($configChanged) { $updatedConfig } else { $originalConfig }
$cockpitSummary = Get-ProviderSummary -Config $effectiveConfig -Provider $CockpitProvider
$ccSwitchSummary = Get-ProviderSummary -Config $effectiveConfig -Provider $CCSwitchProvider

Write-Rule "Codex Mode Switch Result"
Write-Kv "Mode" $Mode
Write-Kv "Target provider" $targetProvider
Write-Kv "Top-level provider" (Get-TopLevelConfigValue -Config $effectiveConfig -Name "model_provider")
Write-Kv "Top-level model" (Get-TopLevelConfigValue -Config $effectiveConfig -Name "model")
Write-Kv "config.toml changed" $configChanged

Write-Rule "Shared Session Safety"
Write-Kv "CODEX_HOME" $resolvedCodexHome
Write-Kv "Legacy switcher backups" (Get-LegacyBackupCount -CodexHomePath $resolvedCodexHome)
Write-Host "  This tool never reads or changes sessions, archived_sessions, SQLite, global state, auth, or backups."
Write-Host "  No session migration, session copy, archive, or backup cleanup is performed."
Write-Host "  To share history, launch every Codex app with this same CODEX_HOME."

Write-Rule "Provider Status"
Write-Kv ("{0} block exists" -f $cockpitSummary.Provider) $cockpitSummary.Present
Write-Kv ("{0} name" -f $cockpitSummary.Provider) $cockpitSummary.Name
Write-Kv ("{0} wire_api" -f $cockpitSummary.Provider) $cockpitSummary.WireApi
Write-Kv ("{0} block exists" -f $ccSwitchSummary.Provider) $ccSwitchSummary.Present
Write-Kv ("{0} name" -f $ccSwitchSummary.Provider) $ccSwitchSummary.Name
Write-Kv ("{0} wire_api" -f $ccSwitchSummary.Provider) $ccSwitchSummary.WireApi

Write-Rule "Next Step"
if ($Mode -eq "Status") {
    Write-Host "  Status only. No file was changed."
}
else {
    Write-Host "  Close and reopen every Codex app so it reloads config.toml. Session history remains in place."
}
