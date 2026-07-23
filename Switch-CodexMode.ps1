<#
.SYNOPSIS
    切换 Codex provider，并同步本地会话的 provider 元数据。

.DESCRIPTION
    此工具修改 config.toml 顶层的 model_provider，并同步 state_5.sqlite 与
    sessions、archived_sessions 中的 model_provider，使同一 CODEX_HOME 下的
    历史会话在切换后保持可见。工具低频维护一个已验证的全量基线，并为每次
    实际修改创建轻量回滚日志。
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

    # 兼容旧参数；指定后只切换配置，不同步会话 provider。
    [switch]$SkipThreadRewrite,

    [ValidateRange(1, 3650)]
    [int]$FullBackupMaxAgeDays = 7,

    [ValidateRange(1, 1000)]
    [int]$RollbackRetentionCount = 20,

    [switch]$ForceFullBackup
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "找不到 CodexHome 目录：$Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-SessionProviderSync {
    param(
        [string]$CodexHomePath,
        [string]$BackupRoot,
        [string]$TargetProvider,
        [string[]]$SourceProviders,
        [string]$UpdatedConfig,
        [bool]$ConfigChanged,
        [int]$FullBackupMaxAgeDays,
        [int]$RollbackRetentionCount,
        [bool]$ForceFullBackup
    )

    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        throw "PATH 中找不到 python/python3，无法安全同步会话 provider。"
    }

    $helperPath = Join-Path (Split-Path -Parent $PSCommandPath) "session_provider_sync.py"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "找不到会话同步模块：$helperPath"
    }

    $tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) "switch_codex_config_$([Guid]::NewGuid().ToString('N')).toml"
    [System.IO.File]::WriteAllText($tempConfig, $UpdatedConfig, [System.Text.UTF8Encoding]::new($false))
    try {
        $arguments = @(
            $helperPath,
            "--codex-home", $CodexHomePath,
            "--backup-root", $BackupRoot,
            "--target-provider", $TargetProvider,
            "--updated-config", $tempConfig,
            "--config-changed", $(if ($ConfigChanged) { "1" } else { "0" }),
            "--full-backup-max-age-days", [string]$FullBackupMaxAgeDays,
            "--rollback-retention-count", [string]$RollbackRetentionCount,
            "--force-full-backup", $(if ($ForceFullBackup) { "1" } else { "0" })
        )
        foreach ($provider in $SourceProviders) {
            $arguments += @("--source-provider", $provider)
        }
        $output = & $python.Source @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "会话 provider 同步失败：$($output -join [Environment]::NewLine)"
        }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempConfig) {
            Remove-Item -LiteralPath $tempConfig -Force
        }
    }
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

    $displayValue = if ($null -eq $Value -or ($Value -is [string] -and $Value -eq "")) { "<未设置>" } else { [string]$Value }
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

function Get-BackupDecisionDisplayName {
    param([string]$Value)

    switch ($Value) {
        "missing" { return "首次创建" }
        "reused" { return "复用现有基线" }
        "not_required" { return "本次无需全量备份" }
        "forced" { return "手动强制刷新" }
        "expired" { return "基线已过期，完成刷新" }
        "format_changed" { return "备份格式变化，完成刷新" }
        "sqlite_schema_changed" { return "数据库结构变化，完成刷新" }
        "invalid_created_at" { return "基线时间无效，完成刷新" }
        "reused_after_refresh_failure" { return "刷新失败，保留原有基线" }
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
$sessionTargetProvider = $null

switch ($Mode) {
    "Normal" {
        $updatedConfig = Remove-TopLevelProvider -Config $originalConfig -ProviderNames @(
            $CockpitProvider,
            $CCSwitchProvider,
            $OpenAIProvider,
            "Codex API Service"
        )
        $targetProvider = "OpenAI 默认"
        $sessionTargetProvider = $OpenAIProvider
    }
    "Cockpit" {
        Assert-ProviderBlock -Config $originalConfig -Provider $CockpitProvider -ModeName $Mode
        $updatedConfig = Set-TopLevelProvider -Config $originalConfig -Provider $CockpitProvider
        $targetProvider = $CockpitProvider
        $sessionTargetProvider = $CockpitProvider
    }
    "CCSwitch" {
        Assert-ProviderBlock -Config $originalConfig -Provider $CCSwitchProvider -ModeName $Mode
        $updatedConfig = Set-TopLevelProvider -Config $originalConfig -Provider $CCSwitchProvider
        $targetProvider = $CCSwitchProvider
        $sessionTargetProvider = $CCSwitchProvider
    }
    "Status" {
        $targetProvider = "<只读>"
    }
}

$configWillChange = $Mode -ne "Status" -and -not [string]::Equals(
    $originalConfig,
    $updatedConfig,
    [System.StringComparison]::Ordinal
)
$configChanged = $false
$backupRoot = Join-Path $resolvedCodexHome "codex-mode-switch-backups"
$sessionSync = $null
if ($Mode -ne "Status" -and -not $SkipThreadRewrite) {
    $knownProviders = @($OpenAIProvider, $CockpitProvider, $CCSwitchProvider, "Codex API Service") |
        Where-Object { $_ -and $_ -ne $sessionTargetProvider } |
        Select-Object -Unique
    $sessionSync = Invoke-SessionProviderSync `
        -CodexHomePath $resolvedCodexHome `
        -BackupRoot $backupRoot `
        -TargetProvider $sessionTargetProvider `
        -SourceProviders $knownProviders `
        -UpdatedConfig $updatedConfig `
        -ConfigChanged $configWillChange `
        -FullBackupMaxAgeDays $FullBackupMaxAgeDays `
        -RollbackRetentionCount $RollbackRetentionCount `
        -ForceFullBackup $ForceFullBackup
    $configChanged = [bool]$sessionSync.config_changed
}
elseif ($configWillChange) {
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

Write-Rule "会话同步结果"
Write-Kv "CODEX_HOME" $resolvedCodexHome
if ($sessionSync) {
    Write-Kv "全量备份基线" $sessionSync.full_backup_path
    Write-Kv "本次是否新建全量备份" $sessionSync.full_backup_created
    Write-Kv "全量备份决策" (Get-BackupDecisionDisplayName -Value $sessionSync.full_backup_reason)
    Write-Kv "本次轻量回滚日志" $sessionSync.transaction_path
    Write-Kv "SQLite 会话行已同步" $sessionSync.sqlite_rows_changed
    Write-Kv "JSONL 文件已同步" ("{0} / {1}" -f $sessionSync.jsonl_files_changed, $sessionSync.jsonl_files_scanned)
    Write-Kv "JSONL 元数据已同步" $sessionSync.jsonl_records_changed
    if ($sessionSync.full_backup_warning) {
        Write-Warning ("全量备份刷新失败，继续使用既有已验证基线：{0}" -f $sessionSync.full_backup_warning)
    }
}
elseif ($Mode -eq "Status") {
    Write-Host "  仅查看状态，未读取或改动会话元数据。"
    $statusFullBackup = Join-Path $backupRoot "full-latest.zip"
    Write-Kv "全量备份基线" $(if (Test-Path -LiteralPath $statusFullBackup -PathType Leaf) { $statusFullBackup } else { $null })
}
else {
    Write-Host "  已按 -SkipThreadRewrite 跳过会话 provider 同步。"
}

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
    Write-Host "  请关闭并重新打开所有 Codex 应用，让它们重新加载配置与会话索引。"
}
