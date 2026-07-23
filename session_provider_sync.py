#!/usr/bin/env python3
"""Synchronize Codex session providers with bounded, recoverable backups."""

from __future__ import annotations

import argparse
from contextlib import closing
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import sys
from typing import Dict, List, Optional, Tuple
import uuid
import zipfile


BACKUP_FORMAT_VERSION = 1
FULL_BACKUP_NAME = "full-latest.zip"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value: Optional[dt.datetime] = None) -> str:
    return (value or utc_now()).isoformat().replace("+00:00", "Z")


def atomic_write_bytes(path: Path, data: bytes) -> None:
    temp_path = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    try:
        with temp_path.open("wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def atomic_write_json(path: Path, data: dict) -> None:
    content = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    atomic_write_bytes(path, content)


class SessionProviderSync:
    def __init__(self, args: argparse.Namespace) -> None:
        self.codex_home = Path(args.codex_home).resolve()
        self.backup_root = Path(args.backup_root).resolve()
        self.target_provider = args.target_provider
        self.source_providers = set(args.source_provider)
        self.updated_config_path = Path(args.updated_config)
        self.config_changed = bool(args.config_changed)
        self.full_backup_max_age_days = args.full_backup_max_age_days
        self.rollback_retention_count = args.rollback_retention_count
        self.force_full_backup = bool(args.force_full_backup)

        self.backup_root.mkdir(parents=True, exist_ok=True)
        self.transactions_root = self.backup_root / "transactions"
        self.transactions_root.mkdir(parents=True, exist_ok=True)
        self.full_backup_path = self.backup_root / FULL_BACKUP_NAME

    @property
    def config_path(self) -> Path:
        return self.codex_home / "config.toml"

    @property
    def database_path(self) -> Path:
        return self.codex_home / "state_5.sqlite"

    def rollout_paths(self):
        for root_name in ("sessions", "archived_sessions"):
            root = self.codex_home / root_name
            if root.exists():
                yield from sorted(root.rglob("*.jsonl"))

    def sqlite_schema_fingerprint(self) -> Optional[str]:
        if not self.database_path.exists():
            return None
        with closing(sqlite3.connect(self.database_path, timeout=15)) as connection:
            rows = list(
                connection.execute(
                    """
                    select type, name, tbl_name, coalesce(sql, '')
                    from sqlite_master
                    order by type, name, tbl_name
                    """
                )
            )
        payload = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()

    def load_full_manifest(self) -> dict:
        with zipfile.ZipFile(self.full_backup_path, "r") as archive:
            manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
            names = set(archive.namelist())
            if "config.toml" not in names:
                raise RuntimeError("full backup is missing config.toml")
            if manifest.get("database_present") and "state_5.sqlite" not in names:
                raise RuntimeError("full backup is missing state_5.sqlite")
            rollout_count = sum(name.startswith("rollouts/") for name in names)
            if rollout_count != manifest.get("session_file_count"):
                raise RuntimeError("full backup rollout count does not match its manifest")
        return manifest

    def full_backup_refresh_reason(
        self, schema_fingerprint: Optional[str]
    ) -> Tuple[Optional[str], Optional[Dict]]:
        if self.force_full_backup:
            if not self.full_backup_path.exists():
                return "forced", None
            try:
                return "forced", self.load_full_manifest()
            except Exception:
                return "forced", None
        if not self.full_backup_path.exists():
            return "missing", None
        try:
            manifest = self.load_full_manifest()
        except Exception as exc:
            return f"invalid: {exc}", None
        if manifest.get("format_version") != BACKUP_FORMAT_VERSION:
            return "format_changed", manifest
        if manifest.get("sqlite_schema_fingerprint") != schema_fingerprint:
            return "sqlite_schema_changed", manifest
        try:
            created_at = dt.datetime.fromisoformat(manifest["created_at"].replace("Z", "+00:00"))
        except Exception:
            return "invalid_created_at", manifest
        max_age = dt.timedelta(days=self.full_backup_max_age_days)
        if utc_now() - created_at >= max_age:
            return "expired", manifest
        return None, manifest

    def create_full_backup(self, schema_fingerprint: Optional[str], reason: str) -> Dict:
        candidate = self.backup_root / f".full-candidate-{uuid.uuid4().hex}.zip"
        sqlite_snapshot = self.backup_root / f".sqlite-snapshot-{uuid.uuid4().hex}.db"
        session_files = list(self.rollout_paths())
        total_source_bytes = 0

        try:
            if self.database_path.exists():
                with closing(sqlite3.connect(self.database_path, timeout=15)) as source:
                    with closing(sqlite3.connect(sqlite_snapshot)) as destination:
                        source.backup(destination)

            with zipfile.ZipFile(
                candidate,
                "w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=6,
                allowZip64=True,
            ) as archive:
                archive.write(self.config_path, "config.toml")
                total_source_bytes += self.config_path.stat().st_size
                if sqlite_snapshot.exists():
                    archive.write(sqlite_snapshot, "state_5.sqlite")
                    total_source_bytes += sqlite_snapshot.stat().st_size
                for path in session_files:
                    relative = path.relative_to(self.codex_home).as_posix()
                    archive.write(path, f"rollouts/{relative}")
                    total_source_bytes += path.stat().st_size

                manifest = {
                    "format_version": BACKUP_FORMAT_VERSION,
                    "created_at": iso_utc(),
                    "refresh_reason": reason,
                    "sqlite_schema_fingerprint": schema_fingerprint,
                    "database_present": self.database_path.exists(),
                    "session_file_count": len(session_files),
                    "total_source_bytes": total_source_bytes,
                }
                archive.writestr(
                    "manifest.json",
                    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                )

            with zipfile.ZipFile(candidate, "r") as archive:
                bad_entry = archive.testzip()
                if bad_entry:
                    raise RuntimeError(f"full backup verification failed: {bad_entry}")
                verified_manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
                if verified_manifest != manifest:
                    raise RuntimeError("full backup manifest verification failed")

            os.replace(candidate, self.full_backup_path)
            return manifest
        finally:
            candidate.unlink(missing_ok=True)
            sqlite_snapshot.unlink(missing_ok=True)

    def ensure_full_backup(self, required: bool) -> dict:
        schema_fingerprint = self.sqlite_schema_fingerprint()
        reason, existing_manifest = self.full_backup_refresh_reason(schema_fingerprint)
        if not required and reason != "forced":
            return {
                "path": str(self.full_backup_path) if self.full_backup_path.exists() else None,
                "created": False,
                "reason": "not_required",
                "created_at": existing_manifest.get("created_at") if existing_manifest else None,
            }
        if reason is None:
            return {
                "path": str(self.full_backup_path),
                "created": False,
                "reason": "reused",
                "created_at": existing_manifest.get("created_at"),
            }

        try:
            manifest = self.create_full_backup(schema_fingerprint, reason)
        except Exception as exc:
            if existing_manifest and reason in {"expired", "forced"}:
                return {
                    "path": str(self.full_backup_path),
                    "created": False,
                    "reason": "reused_after_refresh_failure",
                    "created_at": existing_manifest.get("created_at"),
                    "warning": str(exc),
                }
            raise

        return {
            "path": str(self.full_backup_path),
            "created": True,
            "reason": reason,
            "created_at": manifest["created_at"],
        }

    def collect_sqlite_changes(self) -> List[Dict]:
        if not self.database_path.exists() or not self.source_providers:
            return []
        with closing(sqlite3.connect(self.database_path, timeout=15)) as connection:
            tables = {
                row[0]
                for row in connection.execute("select name from sqlite_master where type = 'table'")
            }
            if "threads" not in tables:
                return []
            columns = {row[1] for row in connection.execute("pragma table_info(threads)")}
            if not {"id", "model_provider"} <= columns:
                raise RuntimeError("threads table lacks id or model_provider; safe rollback is unavailable")
            placeholders = ",".join("?" for _ in self.source_providers)
            return [
                {"id": row[0], "old_provider": row[1]}
                for row in connection.execute(
                    f"select id, model_provider from threads where model_provider in ({placeholders})",
                    sorted(self.source_providers),
                )
            ]

    @staticmethod
    def decode_jsonl(path: Path) -> Tuple[List[str], str, bool, bool]:
        raw = path.read_bytes()
        has_bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw.decode("utf-8-sig")
        newline = "\r\n" if "\r\n" in text else "\n"
        return text.splitlines(), newline, text.endswith(("\r", "\n")), has_bom

    @staticmethod
    def encode_jsonl(lines: List[str], newline: str, had_final_newline: bool, has_bom: bool) -> bytes:
        text = newline.join(lines)
        if had_final_newline:
            text += newline
        data = text.encode("utf-8")
        return (b"\xef\xbb\xbf" + data) if has_bom else data

    def collect_jsonl_changes(self) -> Tuple[List[Dict], int]:
        changes = []
        scanned = 0
        for path in self.rollout_paths():
            scanned += 1
            lines, _, _, _ = self.decode_jsonl(path)
            records = []
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
                old_provider = payload.get("model_provider")
                if old_provider in self.source_providers:
                    records.append({"line_index": index, "old_provider": old_provider})
            if records:
                changes.append(
                    {
                        "path": path.relative_to(self.codex_home).as_posix(),
                        "records": records,
                    }
                )
        return changes, scanned

    def resolve_rollout_path(self, relative: str) -> Path:
        parts = PurePosixPath(relative).parts
        if not parts or any(part in {"", ".", ".."} for part in parts):
            raise RuntimeError(f"unsafe rollout path in rollback log: {relative}")
        path = self.codex_home.joinpath(*parts).resolve()
        if self.codex_home not in path.parents:
            raise RuntimeError(f"rollout path escapes CODEX_HOME: {relative}")
        return path

    def update_jsonl_file(self, change: dict, restore: bool = False) -> None:
        path = self.resolve_rollout_path(change["path"])
        lines, newline, had_final_newline, has_bom = self.decode_jsonl(path)
        for record in change["records"]:
            index = record["line_index"]
            if index >= len(lines):
                raise RuntimeError(f"JSONL line moved: {path}:{index + 1}")
            item = json.loads(lines[index])
            payload = item.get("payload") if isinstance(item, dict) else None
            if item.get("type") != "session_meta" or not isinstance(payload, dict):
                raise RuntimeError(f"JSONL metadata changed: {path}:{index + 1}")
            expected = self.target_provider if restore else record["old_provider"]
            replacement = record["old_provider"] if restore else self.target_provider
            if payload.get("model_provider") != expected:
                raise RuntimeError(f"JSONL provider changed concurrently: {path}:{index + 1}")
            payload["model_provider"] = replacement
            lines[index] = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
        atomic_write_bytes(path, self.encode_jsonl(lines, newline, had_final_newline, has_bom))

    def update_sqlite_rows(self, changes: List[Dict], restore: bool = False) -> None:
        if not changes:
            return
        with closing(sqlite3.connect(self.database_path, timeout=15)) as connection:
            if restore:
                connection.executemany(
                    "update threads set model_provider = ? where id = ?",
                    [(row["old_provider"], row["id"]) for row in changes],
                )
            else:
                connection.executemany(
                    "update threads set model_provider = ? where id = ? and model_provider = ?",
                    [
                        (self.target_provider, row["id"], row["old_provider"])
                        for row in changes
                    ],
                )
                for row in changes:
                    current = connection.execute(
                        "select model_provider from threads where id = ?",
                        (row["id"],),
                    ).fetchone()
                    if current is None or current[0] != self.target_provider:
                        raise RuntimeError(
                            f"SQLite provider changed concurrently for thread {row['id']}"
                        )
            connection.commit()

    def prune_transactions(self) -> None:
        completed = []
        for path in self.transactions_root.iterdir():
            manifest_path = path / "rollback.json"
            if not path.is_dir() or not manifest_path.exists():
                continue
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if manifest.get("status") == "completed":
                completed.append(path)
        completed.sort(key=lambda path: path.name, reverse=True)
        for path in completed[self.rollback_retention_count :]:
            shutil.rmtree(path)

    def run(self) -> dict:
        sqlite_changes = self.collect_sqlite_changes()
        jsonl_changes, jsonl_files_scanned = self.collect_jsonl_changes()
        session_changes_required = bool(sqlite_changes or jsonl_changes)
        full_backup = self.ensure_full_backup(session_changes_required or self.force_full_backup)

        result = {
            "sqlite_rows_changed": 0,
            "jsonl_files_scanned": jsonl_files_scanned,
            "jsonl_files_changed": 0,
            "jsonl_records_changed": 0,
            "config_changed": False,
            "full_backup_path": full_backup.get("path"),
            "full_backup_created": full_backup.get("created", False),
            "full_backup_reason": full_backup.get("reason"),
            "full_backup_created_at": full_backup.get("created_at"),
            "full_backup_warning": full_backup.get("warning"),
            "transaction_path": None,
        }
        if not session_changes_required and not self.config_changed:
            return result

        stamp = utc_now().strftime("%Y%m%dT%H%M%S%fZ")
        transaction_dir = self.transactions_root / f"{stamp}-{uuid.uuid4().hex[:8]}"
        transaction_dir.mkdir(parents=True)
        (transaction_dir / "config.toml").write_bytes(self.config_path.read_bytes())
        manifest_path = transaction_dir / "rollback.json"
        manifest = {
            "format_version": BACKUP_FORMAT_VERSION,
            "status": "prepared",
            "created_at": iso_utc(),
            "target_provider": self.target_provider,
            "source_providers": sorted(self.source_providers),
            "config_changed": self.config_changed,
            "sqlite_rows": sqlite_changes,
            "jsonl_files": jsonl_changes,
        }
        atomic_write_json(manifest_path, manifest)
        result["transaction_path"] = str(transaction_dir)

        changed_jsonl = []
        sqlite_committed = False
        config_written = False
        try:
            for change in jsonl_changes:
                self.update_jsonl_file(change)
                changed_jsonl.append(change)

            self.update_sqlite_rows(sqlite_changes)
            sqlite_committed = bool(sqlite_changes)

            if self.config_changed:
                atomic_write_bytes(self.config_path, self.updated_config_path.read_bytes())
                config_written = True

            manifest["status"] = "completed"
            manifest["completed_at"] = iso_utc()
            atomic_write_json(manifest_path, manifest)
            self.prune_transactions()

            result["sqlite_rows_changed"] = len(sqlite_changes)
            result["jsonl_files_changed"] = len(jsonl_changes)
            result["jsonl_records_changed"] = sum(
                len(item["records"]) for item in jsonl_changes
            )
            result["config_changed"] = self.config_changed
            return result
        except Exception as exc:
            rollback_errors = []
            if config_written:
                try:
                    atomic_write_bytes(
                        self.config_path,
                        (transaction_dir / "config.toml").read_bytes(),
                    )
                except Exception as rollback_exc:
                    rollback_errors.append(f"config.toml: {rollback_exc}")
            if sqlite_committed:
                try:
                    self.update_sqlite_rows(sqlite_changes, restore=True)
                except Exception as rollback_exc:
                    rollback_errors.append(f"SQLite: {rollback_exc}")
            for change in reversed(changed_jsonl):
                try:
                    self.update_jsonl_file(change, restore=True)
                except Exception as rollback_exc:
                    rollback_errors.append(f"{change['path']}: {rollback_exc}")
            manifest["status"] = "rolled_back" if not rollback_errors else "rollback_failed"
            manifest["error"] = str(exc)
            manifest["rollback_errors"] = rollback_errors
            atomic_write_json(manifest_path, manifest)
            if rollback_errors:
                raise RuntimeError(
                    f"sync failed and rollback was incomplete: {exc}; {rollback_errors}"
                ) from exc
            raise RuntimeError(f"sync failed and was rolled back: {exc}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--backup-root", required=True)
    parser.add_argument("--target-provider", required=True)
    parser.add_argument("--source-provider", action="append", default=[])
    parser.add_argument("--updated-config", required=True)
    parser.add_argument("--config-changed", type=int, choices=(0, 1), required=True)
    parser.add_argument("--full-backup-max-age-days", type=int, default=7)
    parser.add_argument("--rollback-retention-count", type=int, default=20)
    parser.add_argument("--force-full-backup", type=int, choices=(0, 1), default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    result = SessionProviderSync(args).run()
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
