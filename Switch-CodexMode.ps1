param(
    [ValidateSet("Normal", "Cockpit", "CCSwitch", "Status")]
    [string]$Mode = "Status",

    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),

    [string]$CockpitProvider = "codex_local_access",

    [string]$CCSwitchProvider = "custom",

    [string]$OpenAIProvider = "openai",

    [string]$CockpitBaseUrl = "http://localhost:55939/v1",

    [string]$CCSwitchBaseUrl = "https://anyrouter.top/v1",

    [string]$ProjectlessRoot = (Join-Path (Join-Path $HOME "Documents") "Codex"),

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

function New-ModeBackup {
    param([string]$CodexHomePath)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $backupDir = Join-Path $CodexHomePath "backup-$stamp-codex-mode-switch"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $names = @(
        "config.toml",
        ".codex-global-state.json",
        "state_5.sqlite",
        "state_5.sqlite-wal",
        "state_5.sqlite-shm"
    )

    foreach ($name in $names) {
        $source = Join-Path $CodexHomePath $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $backupDir $name) -Force
        }
    }

    return $backupDir
}

function Invoke-SwitchPython {
    param(
        [string]$PythonCode,
        [string[]]$Arguments
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        throw "python was not found on PATH. This switcher needs Python's built-in sqlite3 module."
    }

    $temp = Join-Path $env:TEMP "switch_codex_mode_$([Guid]::NewGuid().ToString('N')).py"
    Set-Content -LiteralPath $temp -Value $PythonCode -Encoding UTF8
    try {
        $output = & $python.Source $temp @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Python switch helper failed with exit code $LASTEXITCODE. Output: $output"
        }
        return ($output -join [Environment]::NewLine)
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force
        }
    }
}

$ResolvedCodexHome = Resolve-ExistingDirectory -Path $CodexHome
$BackupDir = $null
if ($Mode -ne "Status") {
    $BackupDir = New-ModeBackup -CodexHomePath $ResolvedCodexHome
}

$PythonCode = @'
import argparse
import json
import pathlib
import re
import shutil
import sqlite3
import sys


def read_text(path):
    return path.read_text(encoding="utf-8-sig")


def write_text(path, text):
    path.write_text(text, encoding="utf-8", newline="\n")


def strip_long_prefix(path):
    if not path:
        return ""
    path = str(path)
    if path.startswith("\\\\?\\"):
        path = path[4:]
    return str(pathlib.PureWindowsPath(path))


def norm_key(path):
    return strip_long_prefix(path).rstrip("\\").lower()


def under(child, parent):
    child_key = norm_key(child)
    parent_key = norm_key(parent)
    return child_key == parent_key or child_key.startswith(parent_key + "\\")


def get_top_provider(config):
    match = re.search(r'(?m)^model_provider\s*=\s*"([^"]+)"\s*$', config)
    return match.group(1) if match else None


def remove_top_provider(config, blocked_values):
    lines = config.splitlines()
    kept = []
    for line in lines:
        match = re.match(r'\s*model_provider\s*=\s*"([^"]+)"\s*$', line)
        if match and match.group(1) in blocked_values:
            continue
        kept.append(line)
    return "\n".join(kept).rstrip() + "\n"


def set_top_provider(config, provider):
    config = re.sub(r'(?m)^model_provider\s*=\s*"[^"]*"\s*\n?', "", config)
    lines = config.splitlines()
    insert_at = 0
    for index, line in enumerate(lines):
        if re.match(r'\s*model\s*=', line):
            insert_at = index + 1
            break
    lines.insert(insert_at, f'model_provider = "{provider}"')
    return "\n".join(lines).rstrip() + "\n"


def provider_header(provider):
    return f"[model_providers.{provider}]"


def extract_provider_block(text, provider):
    header = re.escape(provider_header(provider))
    pattern = rf'(?ms)^{header}\s*\n.*?(?=^\[|\Z)'
    match = re.search(pattern, text)
    return match.group(0).strip() if match else None


def find_provider_block(codex_home, config, provider):
    block = extract_provider_block(config, provider)
    if block:
        return block

    candidates = sorted(
        codex_home.glob("config.toml*"),
        key=lambda p: p.stat().st_mtime if p.exists() else 0,
        reverse=True,
    )
    for path in candidates:
        try:
            text = read_text(path)
        except UnicodeDecodeError:
            continue
        block = extract_provider_block(text, provider)
        if block:
            return block
    return None


def build_provider_block(provider, base_url, provider_name):
    return "\n".join([
        provider_header(provider),
        f'name = "{provider_name}"',
        f'base_url = "{base_url}"',
        'wire_api = "responses"',
        'requires_openai_auth = true',
        'supports_websockets = false',
    ])


def ensure_provider_block(config, provider, base_url, provider_name):
    block = build_provider_block(provider, base_url, provider_name)
    header = re.escape(provider_header(provider))
    pattern = rf'(?ms)^{header}\s*\n.*?(?=^\[|\Z)'
    if re.search(pattern, config):
        return re.sub(pattern, block.strip() + "\n", config).rstrip() + "\n"
    if "[model_providers]" not in config:
        config = config.rstrip() + "\n\n[model_providers]\n"
    return config.rstrip() + "\n\n" + block.strip() + "\n"


def provider_status(config, provider, cc_switch_provider=None):
    block = extract_provider_block(config, provider)
    base_url = None
    if block:
        match = re.search(r'(?m)^base_url\s*=\s*"([^"]+)"\s*$', block)
        base_url = match.group(1) if match else None
    result = {
        "top_level_model_provider": get_top_provider(config),
        "cockpit_provider_block_present": bool(block),
        "cockpit_base_url": base_url,
    }
    if cc_switch_provider:
        cc_block = extract_provider_block(config, cc_switch_provider)
        cc_base_url = None
        if cc_block:
            match = re.search(r'(?m)^base_url\s*=\s*"([^"]+)"\s*$', cc_block)
            cc_base_url = match.group(1) if match else None
        result.update({
            "cc_switch_provider_block_present": bool(cc_block),
            "cc_switch_base_url": cc_base_url,
        })
    return result


def table_columns(cur, table):
    return {row[1] for row in cur.execute(f"pragma table_info({table})")}


def sqlite_counts(cur):
    rows = []
    for row in cur.execute("""
        select model_provider, archived, has_user_event, count(*) as n
        from threads
        group by model_provider, archived, has_user_event
        order by n desc, model_provider
    """):
        rows.append({
            "model_provider": row[0],
            "archived": row[1],
            "has_user_event": row[2],
            "count": row[3],
        })
    return rows


def rollout_roots(codex_home):
    roots = [codex_home / "sessions", codex_home / "archived_sessions"]
    return [root for root in roots if root.exists()]


def iter_rollout_paths(codex_home):
    for root in rollout_roots(codex_home):
        yield from root.rglob("*.jsonl")


def relative_rollout_path(codex_home, path):
    try:
        return path.relative_to(codex_home)
    except ValueError:
        return pathlib.Path(path.name)


def backup_rollout(codex_home, backup_dir, path):
    if not backup_dir:
        return
    backup_root = pathlib.Path(backup_dir) / "rollouts"
    destination = backup_root / relative_rollout_path(codex_home, path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        shutil.copy2(path, destination)


def rewrite_rollout_session_meta_providers(codex_home, from_providers, to_provider, backup_dir):
    scanned = 0
    changed = 0
    errors = []
    from_providers = set(from_providers)

    for path in iter_rollout_paths(codex_home):
        scanned += 1
        try:
            lines = path.read_text(encoding="utf-8-sig").splitlines()
        except UnicodeDecodeError as exc:
            errors.append(f"{path}: decode failed: {exc}")
            continue

        file_changed = False
        new_lines = []
        for line in lines:
            if '"session_meta"' not in line and "'session_meta'" not in line:
                new_lines.append(line)
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                new_lines.append(line)
                continue

            payload = obj.get("payload") if isinstance(obj, dict) else None
            if obj.get("type") == "session_meta" and isinstance(payload, dict):
                if payload.get("model_provider") in from_providers:
                    payload["model_provider"] = to_provider
                    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
                    file_changed = True
            new_lines.append(line)

        if file_changed:
            backup_rollout(codex_home, backup_dir, path)
            path.write_text("\n".join(new_lines) + "\n", encoding="utf-8", newline="\n")
            changed += 1

    return {
        "rollout_files_scanned": scanned,
        "rollout_files_changed": changed,
        "rollout_rewrite_errors": errors[:10],
    }


def rollout_provider_counts(codex_home):
    counts = {}
    scanned = 0
    for path in iter_rollout_paths(codex_home):
        scanned += 1
        try:
            with path.open("r", encoding="utf-8-sig") as f:
                for line in f:
                    if '"session_meta"' not in line and "'session_meta'" not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") == "session_meta":
                        provider = obj.get("payload", {}).get("model_provider") or "<missing>"
                        counts[provider] = counts.get(provider, 0) + 1
                        break
        except UnicodeDecodeError:
            continue
    return {
        "rollout_files_scanned": scanned,
        "rollout_provider_counts": [
            {"model_provider": provider, "count": count}
            for provider, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
        ],
    }


def rebuild_state(codex_home, doc_root, rows):
    state_path = codex_home / ".codex-global-state.json"
    if not state_path.exists():
        return {"state_updated": False}

    data = json.loads(read_text(state_path))
    saved_roots = [strip_long_prefix(x) for x in data.get("electron-saved-workspace-roots", [])]
    project_order = [strip_long_prefix(x) for x in data.get("project-order", [])]
    doc_root = strip_long_prefix(doc_root)

    def choose_root(cwd):
        cwd = strip_long_prefix(cwd)
        if under(cwd, doc_root):
            return doc_root
        candidates = [root for root in saved_roots if under(cwd, root)]
        if candidates:
            return max(candidates, key=len)
        return cwd

    hints = dict(data.get("thread-workspace-root-hints", {}))
    projectless = []
    seen_projectless = set()
    missing_roots = []
    existing_saved_keys = {norm_key(root) for root in saved_roots}

    for row in rows:
        root = choose_root(row["cwd"])
        hints[row["id"]] = root
        if under(root, doc_root):
            if row["id"] not in seen_projectless:
                projectless.append(row["id"])
                seen_projectless.add(row["id"])
        elif norm_key(root) not in existing_saved_keys:
            missing_roots.append(root)
            existing_saved_keys.add(norm_key(root))

    for thread_id in data.get("projectless-thread-ids", []):
        if thread_id not in seen_projectless:
            projectless.append(thread_id)
            seen_projectless.add(thread_id)

    if missing_roots:
        missing_keys = {norm_key(root) for root in missing_roots}
        data["electron-saved-workspace-roots"] = [
            root for root in saved_roots if norm_key(root) not in missing_keys
        ] + missing_roots
        data["project-order"] = [
            root for root in project_order if norm_key(root) not in missing_keys
        ] + missing_roots
    else:
        data["electron-saved-workspace-roots"] = saved_roots
        data["project-order"] = project_order

    data["thread-workspace-root-hints"] = hints
    data["projectless-thread-ids"] = projectless
    write_text(state_path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")

    return {
        "state_updated": True,
        "hint_count": len(hints),
        "projectless_count": len(projectless),
        "missing_roots_added_count": len(missing_roots),
    }


def unique_values(values):
    result = []
    seen = set()
    for value in values:
        if not value or value in seen:
            continue
        result.append(value)
        seen.add(value)
    return result


def provider_rewrite_plan(mode, cockpit_provider, cc_switch_provider, openai_provider):
    known_session_providers = unique_values([
        openai_provider,
        cockpit_provider,
        cc_switch_provider,
        "Codex API Service",
    ])
    if mode == "Normal":
        target = openai_provider
    elif mode == "Cockpit":
        target = cockpit_provider
    elif mode == "CCSwitch":
        target = cc_switch_provider
    else:
        target = None
    sources = [provider for provider in known_session_providers if provider != target]
    return target, sources


def update_threads(codex_home, mode, cockpit_provider, cc_switch_provider, openai_provider, doc_root, skip, backup_dir):
    db_path = codex_home / "state_5.sqlite"
    if skip or not db_path.exists():
        return {"db_present": db_path.exists(), "db_updated": False}

    con = sqlite3.connect(db_path, timeout=15)
    con.row_factory = sqlite3.Row
    cur = con.cursor()
    tables = {row[0] for row in cur.execute("select name from sqlite_master where type='table'")}
    if "threads" not in tables:
        con.close()
        return {"db_present": True, "db_updated": False, "reason": "threads table missing"}

    columns = table_columns(cur, "threads")
    provider_updates = 0
    visible_marked = 0

    target_provider, source_providers = provider_rewrite_plan(
        mode, cockpit_provider, cc_switch_provider, openai_provider
    )

    if {"model_provider"} <= columns and target_provider and source_providers:
        placeholders = ",".join("?" for _ in source_providers)
        cur.execute(
            f"update threads set model_provider = ? where model_provider in ({placeholders})",
            [target_provider, *source_providers],
        )
        provider_updates = cur.rowcount

    if {"archived", "has_user_event", "thread_source", "first_user_message", "title"} <= columns:
        cur.execute("""
            update threads
            set has_user_event = 1
            where archived = 0
              and has_user_event = 0
              and (thread_source is null or thread_source = 'user')
              and (coalesce(first_user_message, '') <> '' or coalesce(title, '') <> '')
        """)
        visible_marked = cur.rowcount

    select_columns = {"id", "cwd", "updated_at", "archived", "has_user_event", "thread_source"}
    rows = []
    if select_columns <= columns:
        rows = [dict(row) for row in cur.execute("""
            select id, cwd, updated_at
            from threads
            where archived = 0
              and has_user_event = 1
              and (thread_source is null or thread_source = 'user')
              and coalesce(cwd, '') <> ''
            order by updated_at desc
        """)]

    con.commit()
    counts = sqlite_counts(cur)
    con.close()

    state_result = rebuild_state(codex_home, doc_root, rows)
    rollout_result = {}
    if target_provider and source_providers:
        rollout_result = rewrite_rollout_session_meta_providers(
            codex_home, source_providers, target_provider, backup_dir
        )

    return {
        "db_present": True,
        "db_updated": True,
        "provider_updates": provider_updates,
        "visible_marked": visible_marked,
        "visible_rows": len(rows),
        "provider_counts": counts,
        **state_result,
        **rollout_result,
    }


def read_status(codex_home, cockpit_provider, cc_switch_provider):
    config_path = codex_home / "config.toml"
    config = read_text(config_path) if config_path.exists() else ""
    result = provider_status(config, cockpit_provider, cc_switch_provider)

    db_path = codex_home / "state_5.sqlite"
    result["db_present"] = db_path.exists()
    if db_path.exists():
        con = sqlite3.connect(db_path, timeout=15)
        cur = con.cursor()
        result["provider_counts"] = sqlite_counts(cur)
        con.close()
    else:
        result["provider_counts"] = []
    result.update(rollout_provider_counts(codex_home))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True, choices=["Normal", "Cockpit", "CCSwitch", "Status"])
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--cockpit-provider", required=True)
    parser.add_argument("--cc-switch-provider", required=True)
    parser.add_argument("--openai-provider", required=True)
    parser.add_argument("--cockpit-base-url", required=True)
    parser.add_argument("--cc-switch-base-url", required=True)
    parser.add_argument("--projectless-root", required=True)
    parser.add_argument("--backup-dir", default="")
    parser.add_argument("--skip-thread-rewrite", action="store_true")
    args = parser.parse_args()

    codex_home = pathlib.Path(args.codex_home)
    config_path = codex_home / "config.toml"

    if args.mode == "Status":
        result = read_status(codex_home, args.cockpit_provider, args.cc_switch_provider)
        result["mode"] = args.mode
        print(json.dumps(result, ensure_ascii=False))
        return 0

    if not config_path.exists():
        raise SystemExit(f"config.toml not found: {config_path}")

    config = read_text(config_path)
    if args.mode == "Normal":
        config = remove_top_provider(config, {
            args.cockpit_provider,
            args.cc_switch_provider,
            "Codex API Service",
        })
        config = ensure_provider_block(
            config,
            args.cockpit_provider,
            args.cockpit_base_url,
            "Codex API Service",
        )
        config = ensure_provider_block(
            config,
            args.cc_switch_provider,
            args.cc_switch_base_url,
            args.cc_switch_provider,
        )
    elif args.mode == "Cockpit":
        config = ensure_provider_block(
            config,
            args.cockpit_provider,
            args.cockpit_base_url,
            "Codex API Service",
        )
        config = ensure_provider_block(
            config,
            args.cc_switch_provider,
            args.cc_switch_base_url,
            args.cc_switch_provider,
        )
        config = set_top_provider(config, args.cockpit_provider)
    elif args.mode == "CCSwitch":
        config = ensure_provider_block(
            config,
            args.cockpit_provider,
            args.cockpit_base_url,
            "Codex API Service",
        )
        config = ensure_provider_block(
            config,
            args.cc_switch_provider,
            args.cc_switch_base_url,
            args.cc_switch_provider,
        )
        config = set_top_provider(config, args.cc_switch_provider)

    write_text(config_path, config)
    thread_result = update_threads(
        codex_home,
        args.mode,
        args.cockpit_provider,
        args.cc_switch_provider,
        args.openai_provider,
        args.projectless_root,
        args.skip_thread_rewrite,
        args.backup_dir,
    )

    result = {
        "mode": args.mode,
        "backup_dir": args.backup_dir,
        **provider_status(config, args.cockpit_provider, args.cc_switch_provider),
        **thread_result,
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
'@

$argsForPython = @(
    "--mode", $Mode,
    "--codex-home", $ResolvedCodexHome,
    "--cockpit-provider", $CockpitProvider,
    "--cc-switch-provider", $CCSwitchProvider,
    "--openai-provider", $OpenAIProvider,
    "--cockpit-base-url", $CockpitBaseUrl,
    "--cc-switch-base-url", $CCSwitchBaseUrl,
    "--projectless-root", $ProjectlessRoot
)

if ($BackupDir) {
    $argsForPython += @("--backup-dir", $BackupDir)
}
if ($SkipThreadRewrite) {
    $argsForPython += "--skip-thread-rewrite"
}

$jsonText = Invoke-SwitchPython -PythonCode $PythonCode -Arguments $argsForPython
$result = $jsonText | ConvertFrom-Json

Write-Host "Codex mode switch result"
Write-Host "Mode: $($result.mode)"
if ($result.backup_dir) {
    Write-Host "Backup: $($result.backup_dir)"
}
$top = $result.top_level_model_provider
if (-not $top) { $top = "<none>" }
Write-Host "Top-level model_provider: $top"
Write-Host "Cockpit provider block present: $($result.cockpit_provider_block_present)"
if ($result.cockpit_base_url) {
    Write-Host "Cockpit base_url: $($result.cockpit_base_url)"
}
Write-Host "CCSwitch provider block present: $($result.cc_switch_provider_block_present)"
if ($result.cc_switch_base_url) {
    Write-Host "CCSwitch base_url: $($result.cc_switch_base_url)"
}
if ($null -ne $result.provider_updates) {
    Write-Host "Thread provider rows changed: $($result.provider_updates)"
}
if ($null -ne $result.visible_marked) {
    Write-Host "User-visible rows marked: $($result.visible_marked)"
}
if ($null -ne $result.visible_rows) {
    Write-Host "Visible user rows indexed: $($result.visible_rows)"
}
if ($null -ne $result.projectless_count) {
    Write-Host "Projectless thread ids: $($result.projectless_count)"
}
if ($null -ne $result.rollout_files_changed) {
    Write-Host "JSONL session_meta files changed: $($result.rollout_files_changed) / scanned $($result.rollout_files_scanned)"
}
if ($result.provider_counts) {
    Write-Host "Thread provider counts:"
    foreach ($row in $result.provider_counts) {
        Write-Host ("  provider={0}; archived={1}; has_user_event={2}; count={3}" -f $row.model_provider, $row.archived, $row.has_user_event, $row.count)
    }
}
if ($result.rollout_provider_counts) {
    Write-Host "JSONL session_meta provider counts:"
    foreach ($row in $result.rollout_provider_counts) {
        Write-Host ("  provider={0}; count={1}" -f $row.model_provider, $row.count)
    }
}
