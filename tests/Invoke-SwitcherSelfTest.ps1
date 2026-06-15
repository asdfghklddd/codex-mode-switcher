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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-mode-switcher-test-$([Guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot ".codex"
$posixProjectlessRoot = "/Users/demo/Documents/Codex"

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
        throw "python/python3 was not found on PATH."
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "codex_mode_selftest_$([Guid]::NewGuid().ToString('N')).py"
    Set-Content -LiteralPath $temp -Value $Code -Encoding UTF8
    try {
        & $python.Source $temp @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Python helper failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force
        }
    }
}

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "archived_sessions") -Force | Out-Null

Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value @'
model = "gpt-5.1"

[model_providers]

[model_providers.codex_local_access]
name = "stale"
base_url = "https://wrong.example/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
'@

Set-Content -LiteralPath (Join-Path $codexHome ".codex-global-state.json") -Encoding UTF8 -Value @"
{
  "electron-saved-workspace-roots": [
    "$posixProjectlessRoot"
  ],
  "project-order": [
    "$posixProjectlessRoot"
  ],
  "thread-workspace-root-hints": {},
  "projectless-thread-ids": []
}
"@

Invoke-Python -Code @'
import json
import pathlib
import sqlite3
import sys

codex_home = pathlib.Path(sys.argv[1])
db_path = codex_home / "state_5.sqlite"
con = sqlite3.connect(db_path)
cur = con.cursor()
cur.execute("""
create table threads (
    id text,
    cwd text,
    updated_at integer,
    archived integer,
    has_user_event integer,
    thread_source text,
    first_user_message text,
    title text,
    model_provider text
)
""")
rows = [
    ("t-openai", "/Users/demo/Documents/Codex/a", 3, 0, 1, "user", "hello", "OpenAI", "openai"),
    ("t-cockpit", "/Users/demo/Documents/Codex/b", 2, 0, 1, "user", "hello", "Cockpit", "codex_local_access"),
    ("t-custom", "/Users/demo/Projects/x", 1, 1, 1, "user", "hello", "Custom", "custom"),
]
cur.executemany("insert into threads values (?,?,?,?,?,?,?,?,?)", rows)
con.commit()
con.close()

for name, provider in [
    ("sessions/openai.jsonl", "openai"),
    ("sessions/cockpit.jsonl", "codex_local_access"),
    ("archived_sessions/custom.jsonl", "custom"),
]:
    path = codex_home / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"type": "session_meta", "payload": {"model_provider": provider}}, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
'@ -Arguments @($codexHome)

foreach ($mode in @("CCSwitch", "Normal", "Cockpit")) {
    & $powershell.Source -NoProfile -ExecutionPolicy Bypass -File $switcher -Mode $mode -CodexHome $codexHome -ProjectlessRoot $posixProjectlessRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Switcher failed in $mode mode."
    }
}

$config = Get-Content -Raw -LiteralPath (Join-Path $codexHome "config.toml")
Assert-True ($config -match 'model_provider\s*=\s*"codex_local_access"') "Expected Cockpit to be the final top-level provider."
Assert-True ($config -match 'base_url\s*=\s*"http://localhost:55939/v1"') "Expected Cockpit local base URL."
Assert-True ($config -match 'base_url\s*=\s*"https://anyrouter.top/v1"') "Expected CCSwitch base URL."

$state = Get-Content -Raw -LiteralPath (Join-Path $codexHome ".codex-global-state.json") | ConvertFrom-Json
Assert-True ($state."thread-workspace-root-hints"."t-openai" -eq $posixProjectlessRoot) "Expected POSIX projectless root to remain slash-style."
Assert-True ($state."projectless-thread-ids" -contains "t-openai") "Expected user thread to be indexed as projectless."

Invoke-Python -Code @'
import json
import pathlib
import sqlite3
import sys

codex_home = pathlib.Path(sys.argv[1])
con = sqlite3.connect(codex_home / "state_5.sqlite")
providers = {row[0] for row in con.execute("select distinct model_provider from threads")}
con.close()
if providers != {"codex_local_access"}:
    raise SystemExit(f"unexpected db providers: {providers}")

jsonl_providers = set()
for path in list((codex_home / "sessions").rglob("*.jsonl")) + list((codex_home / "archived_sessions").rglob("*.jsonl")):
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        obj = json.loads(line)
        if obj.get("type") == "session_meta":
            jsonl_providers.add(obj.get("payload", {}).get("model_provider"))
            break
if jsonl_providers != {"codex_local_access"}:
    raise SystemExit(f"unexpected jsonl providers: {jsonl_providers}")
'@ -Arguments @($codexHome)

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Write-Host "Self-test passed."
