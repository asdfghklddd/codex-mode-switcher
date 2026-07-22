<#
.SYNOPSIS
    切换顶层 Codex provider，不触及会话数据。

.DESCRIPTION
    此工具只修改 config.toml 顶层的 model_provider。
    它不会读取、复制、改写、索引、归档、迁移或删除 sessions、archived_sessions、
    SQLite 数据库、全局状态、认证或备份。所有 Codex 应用必须使用同一个
    CODEX_HOME，才能共享本地会话。
#>

param(
    [ValidateSet("Normal", "Cockpit", "CCSwitch", "Status")]
    [string]$Mode = "Status",

    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),

    [string]$CockpitProvider = "codex_local_access",

    [string]$CCSwitchProvider = "custom",

    [string]$OpenAIProvider = "openai",

    # 保留以兼容既有快捷方式和命令行参数。
    [string]$ProjectlessRoot = (Join-Path (Join-Path $HOME "Documents") "Codex"),

    # 保留为空操作以兼容旧参数；会话改写功能已经移除。
    [switch]$SkipThreadRewrite
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "找不到 CodexHome 目录：$Path"
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
        throw "模式 $ModeName 缺少服务提供方配置块 [model_providers.$Provider]。请先用对应服务提供方的原生工具完成配置。"
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

    $displayValue = if ($null -eq $Value -or $Value -eq "") { "<未设置>" } else { [string]$Value }
    Write-Host ("  {0,-34} {1}" -f $Name, $displayValue)
}

function Get-ModeDisplayName {
    param([string]$Value)

    switch ($Value) {
        "Normal" { return "OpenAI 默认" }
        "Cockpit" { return "Cockpit" }
        "CCSwitch" { return "CCSwitch" }
        "Status" { return "仅查看状态" }
        default { return $Value }
    }
}

$resolvedCodexHome = Resolve-ExistingDirectory -Path $CodexHome
$configPath = Join-Path $resolvedCodexHome "config.toml"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "找不到 config.toml：$configPath"
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
        $targetProvider = "OpenAI 默认"
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
        $targetProvider = "<只读>"
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

Write-Rule "Codex 模式切换结果"
Write-Kv "模式" (Get-ModeDisplayName -Value $Mode)
Write-Kv "目标服务提供方" $targetProvider
Write-Kv "顶层服务提供方" (Get-TopLevelConfigValue -Config $effectiveConfig -Name "model_provider")
Write-Kv "顶层模型" (Get-TopLevelConfigValue -Config $effectiveConfig -Name "model")
Write-Kv "config.toml 是否变更" $configChanged

Write-Rule "会话共享安全说明"
Write-Kv "CODEX_HOME" $resolvedCodexHome
Write-Kv "旧版切换器备份数量" (Get-LegacyBackupCount -CodexHomePath $resolvedCodexHome)
Write-Host "  此工具不会读取或改动 sessions、archived_sessions、SQLite、全局状态、认证或备份。"
Write-Host "  不会执行会话迁移、会话复制、归档或备份清理。"
Write-Host "  要共享历史，请让所有 Codex 应用使用同一个 CODEX_HOME。"

Write-Rule "服务提供方配置状态"
Write-Kv ("{0} 配置块是否存在" -f $cockpitSummary.Provider) $cockpitSummary.Present
Write-Kv ("{0} 名称" -f $cockpitSummary.Provider) $cockpitSummary.Name
Write-Kv ("{0} wire_api" -f $cockpitSummary.Provider) $cockpitSummary.WireApi
Write-Kv ("{0} 配置块是否存在" -f $ccSwitchSummary.Provider) $ccSwitchSummary.Present
Write-Kv ("{0} 名称" -f $ccSwitchSummary.Provider) $ccSwitchSummary.Name
Write-Kv ("{0} wire_api" -f $ccSwitchSummary.Provider) $ccSwitchSummary.WireApi

Write-Rule "下一步"
if ($Mode -eq "Status") {
    Write-Host "  仅查看状态，没有修改文件。"
}
else {
    Write-Host "  请关闭并重新打开所有 Codex 应用，让它们重新加载 config.toml；会话历史保持不变。"
}
