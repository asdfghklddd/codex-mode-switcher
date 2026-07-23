$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$switcher = Join-Path $repoRoot "Switch-CodexMode.ps1"
$powershell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powershell) {
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue
}
if (-not $powershell) {
    throw "PATH 中找不到 pwsh/powershell。"
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

function Invoke-Python {
    param(
        [string]$Code,
        [string[]]$Arguments = @()
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        throw "PATH 中找不到 python/python3。"
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "codex_mode_selftest_$([Guid]::NewGuid().ToString('N')).py"
    Set-Content -LiteralPath $temp -Value $Code -Encoding UTF8
    try {
        $output = & $python.Source $temp @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Python 测试助手失败：$($output -join [Environment]::NewLine)"
        }
        return $output
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force
        }
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-mode-switcher-test-$([Guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot ".codex"
$globalStatePath = Join-Path $codexHome ".codex-global-state.json"

try {
    New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $codexHome "archived_sessions") -Force | Out-Null

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
    Set-Content -LiteralPath $globalStatePath -Encoding UTF8 -Value '{"sentinel":"不得改变"}'
    $globalStateHash = (Get-FileHash -LiteralPath $globalStatePath -Algorithm SHA256).Hash

    Invoke-Python -Code @'
import json
import pathlib
import sqlite3
import sys

codex_home = pathlib.Path(sys.argv[1])
con = sqlite3.connect(codex_home / "state_5.sqlite")
con.execute("create table threads (id text primary key, model_provider text, archived integer, has_user_event integer)")
con.executemany("insert into threads values (?, ?, 0, 1)", [
    ("openai", "openai"),
    ("cockpit", "codex_local_access"),
    ("custom", "custom"),
    ("unknown", "loomex"),
])
con.commit()
con.close()

for relative, provider in [
    ("sessions/openai.jsonl", "openai"),
    ("sessions/cockpit.jsonl", "codex_local_access"),
    ("archived_sessions/custom.jsonl", "custom"),
    ("sessions/unknown.jsonl", "loomex"),
]:
    path = codex_home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"type": "session_meta", "payload": {"model_provider": provider}}, separators=(",", ":"))
        + "\n"
        + json.dumps({"type": "response_item", "payload": {"text": "sentinel"}}, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
'@ -Arguments @($codexHome) | Out-Null

    $statusHashes = @{}
    foreach ($path in @(
        (Join-Path $codexHome "state_5.sqlite"),
        (Join-Path $codexHome "sessions\openai.jsonl"),
        $globalStatePath
    )) {
        $statusHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $switcher -Mode Status -CodexHome $codexHome | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Status 模式执行失败。"
    foreach ($path in $statusHashes.Keys) {
        Assert-True ($statusHashes[$path] -eq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) "Status 模式修改了文件：$path"
    }

    foreach ($mode in @("CCSwitch", "Normal", "Cockpit")) {
        & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $switcher -Mode $mode -CodexHome $codexHome | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "切换器在 $mode 模式下执行失败。"
    }

    $config = Get-Content -Raw -LiteralPath (Join-Path $codexHome "config.toml")
    Assert-True ($config -match '(?m)^model_provider\s*=\s*"codex_local_access"\s*$') "最终顶层 provider 应为 Cockpit。"
    Assert-True ($config -match '\[model_providers\.custom\]') "切换时不应删除 custom 配置块。"

    Invoke-Python -Code @'
import json
import pathlib
import sqlite3
import sys

codex_home = pathlib.Path(sys.argv[1])
con = sqlite3.connect(codex_home / "state_5.sqlite")
providers = dict(con.execute("select id, model_provider from threads"))
con.close()
expected = {
    "openai": "codex_local_access",
    "cockpit": "codex_local_access",
    "custom": "codex_local_access",
    "unknown": "loomex",
}
if providers != expected:
    raise SystemExit(f"unexpected SQLite providers: {providers}")

for path in list((codex_home / "sessions").rglob("*.jsonl")) + list((codex_home / "archived_sessions").rglob("*.jsonl")):
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    meta = json.loads(lines[0])
    provider = meta["payload"]["model_provider"]
    expected_provider = "loomex" if path.name == "unknown.jsonl" else "codex_local_access"
    if provider != expected_provider:
        raise SystemExit(f"unexpected JSONL provider in {path}: {provider}")
    if json.loads(lines[1])["payload"]["text"] != "sentinel":
        raise SystemExit(f"session body changed in {path}")
'@ -Arguments @($codexHome) | Out-Null

    $backupDirs = @(Get-ChildItem -LiteralPath $codexHome -Directory -Filter "backup-*-codex-mode-switch")
    Assert-True ($backupDirs.Count -eq 3) "每次会话同步都应创建一个备份。"
    foreach ($backupDir in $backupDirs) {
        Assert-True (Test-Path -LiteralPath (Join-Path $backupDir.FullName "config.toml")) "备份缺少 config.toml。"
        Assert-True (Test-Path -LiteralPath (Join-Path $backupDir.FullName "state_5.sqlite")) "备份缺少 SQLite 快照。"
    }

    $dbHashBeforeSkip = (Get-FileHash -LiteralPath (Join-Path $codexHome "state_5.sqlite") -Algorithm SHA256).Hash
    & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $switcher -Mode CCSwitch -CodexHome $codexHome -SkipThreadRewrite | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "SkipThreadRewrite 模式执行失败。"
    Assert-True ($dbHashBeforeSkip -eq (Get-FileHash -LiteralPath (Join-Path $codexHome "state_5.sqlite") -Algorithm SHA256).Hash) "SkipThreadRewrite 修改了 SQLite。"
    Assert-True ($backupDirs.Count -eq @(Get-ChildItem -LiteralPath $codexHome -Directory -Filter "backup-*-codex-mode-switch").Count) "SkipThreadRewrite 不应创建备份。"
    Assert-True ($globalStateHash -eq (Get-FileHash -LiteralPath $globalStatePath -Algorithm SHA256).Hash) "切换器修改了全局状态。"

    Write-Host "核心自测通过。"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
