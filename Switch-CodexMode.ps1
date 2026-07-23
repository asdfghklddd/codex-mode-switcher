<#
.SYNOPSIS
    切换 Codex provider，并同步本地会话的 provider 元数据。

.DESCRIPTION
    此工具修改 config.toml 顶层的 model_provider，并同步 state_5.sqlite 与
    sessions、archived_sessions 中的 model_provider，使同一 CODEX_HOME 下的
    历史会话在切换后保持可见。每次同步前都会创建可恢复备份。
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

function New-ModeBackup {
    param([string]$CodexHomePath)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $backupDir = Join-Path $CodexHomePath "backup-$stamp-codex-mode-switch"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $configPath = Join-Path $CodexHomePath "config.toml"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDir "config.toml") -Force
    }

    return $backupDir
}

function Invoke-SessionProviderSync {
    param(
        [string]$CodexHomePath,
        [string]$BackupDir,
        [string]$TargetProvider,
        [string[]]$SourceProviders
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        throw "PATH 中找不到 python/python3，无法安全同步会话 provider。"
    }

    $pythonCode = @'
import json
import os
import pathlib
import shutil
import sqlite3
import sys
import uuid


codex_home = pathlib.Path(sys.argv[1])
backup_dir = pathlib.Path(sys.argv[2])
target_provider = sys.argv[3]
source_providers = set(sys.argv[4:])

result = {
    "sqlite_rows_changed": 0,
    "jsonl_files_scanned": 0,
    "jsonl_files_changed": 0,
    "jsonl_records_changed": 0,
    "errors": [],
}

db_path = codex_home / "state_5.sqlite"
if db_path.exists():
    try:
        backup_db = backup_dir / "state_5.sqlite"
        with sqlite3.connect(db_path, timeout=15) as source:
            with sqlite3.connect(backup_db) as destination:
                source.backup(destination)

        with sqlite3.connect(db_path, timeout=15) as connection:
            tables = {row[0] for row in connection.execute(
                "select name from sqlite_master where type = 'table'"
            )}
            if "threads" in tables:
                columns = {row[1] for row in connection.execute("pragma table_info(threads)")}
                if "model_provider" in columns and source_providers:
                    placeholders = ",".join("?" for _ in source_providers)
                    cursor = connection.execute(
                        f"update threads set model_provider = ? where model_provider in ({placeholders})",
                        [target_provider, *sorted(source_providers)],
                    )
                    result["sqlite_rows_changed"] = cursor.rowcount
    except Exception as exc:
        raise RuntimeError(f"SQLite 同步失败: {exc}") from exc

for root_name in ("sessions", "archived_sessions"):
    root = codex_home / root_name
    if not root.exists():
        continue

    for path in root.rglob("*.jsonl"):
        result["jsonl_files_scanned"] += 1
        try:
            raw = path.read_bytes()
            text = raw.decode("utf-8-sig")
            newline = "\r\n" if "\r\n" in text else "\n"
            had_final_newline = text.endswith(("\r", "\n"))
            lines = text.splitlines()
            changed = 0

            for index, line in enumerate(lines):
                if '"session_meta"' not in line and "'session_meta'" not in line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue

                payload = item.get("payload") if isinstance(item, dict) else None
                if item.get("type") != "session_meta" or not isinstance(payload, dict):
                    continue
                if payload.get("model_provider") not in source_providers:
                    continue

                payload["model_provider"] = target_provider
                lines[index] = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
                changed += 1

            if not changed:
                continue

            relative = path.relative_to(codex_home)
            backup_path = backup_dir / "rollouts" / relative
            backup_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup_path)

            updated = newline.join(lines)
            if had_final_newline:
                updated += newline
            temp_path = path.with_name(path.name + f".switch-{uuid.uuid4().hex}.tmp")
            try:
                temp_path.write_text(updated, encoding="utf-8", newline="")
                os.replace(temp_path, path)
            finally:
                if temp_path.exists():
                    temp_path.unlink()

            result["jsonl_files_changed"] += 1
            result["jsonl_records_changed"] += changed
        except Exception as exc:
            result["errors"].append(f"{path}: {exc}")

print(json.dumps(result, ensure_ascii=False))
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "switch_codex_sessions_$([Guid]::NewGuid().ToString('N')).py"
    Set-Content -LiteralPath $tempScript -Value $pythonCode -Encoding UTF8
    try {
        $arguments = @($tempScript, $CodexHomePath, $BackupDir, $TargetProvider) + $SourceProviders
        $output = & $python.Source @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "会话 provider 同步失败：$($output -join [Environment]::NewLine)"
        }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
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

$configChanged = $false
$backupDir = $null
$sessionSync = $null
if ($Mode -ne "Status" -and -not $SkipThreadRewrite) {
    $knownProviders = @($OpenAIProvider, $CockpitProvider, $CCSwitchProvider, "Codex API Service") |
        Where-Object { $_ -and $_ -ne $sessionTargetProvider } |
        Select-Object -Unique
    $backupDir = New-ModeBackup -CodexHomePath $resolvedCodexHome
    $sessionSync = Invoke-SessionProviderSync `
        -CodexHomePath $resolvedCodexHome `
        -BackupDir $backupDir `
        -TargetProvider $sessionTargetProvider `
        -SourceProviders $knownProviders
}

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

Write-Rule "会话同步结果"
Write-Kv "CODEX_HOME" $resolvedCodexHome
Write-Kv "本次备份" $backupDir
if ($sessionSync) {
    Write-Kv "SQLite 会话行已同步" $sessionSync.sqlite_rows_changed
    Write-Kv "JSONL 文件已同步" ("{0} / {1}" -f $sessionSync.jsonl_files_changed, $sessionSync.jsonl_files_scanned)
    Write-Kv "JSONL 元数据已同步" $sessionSync.jsonl_records_changed
    if ($sessionSync.errors.Count -gt 0) {
        Write-Warning ("有 {0} 个 JSONL 文件同步失败，原文件未被覆盖。" -f $sessionSync.errors.Count)
        foreach ($syncError in $sessionSync.errors | Select-Object -First 5) {
            Write-Warning $syncError
        }
    }
}
elseif ($Mode -eq "Status") {
    Write-Host "  仅查看状态，未读取或改动会话元数据。"
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
