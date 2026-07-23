import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from session_provider_sync import SessionProviderSync  # noqa: E402


PROVIDERS = ("openai", "codex_local_access", "custom", "Codex API Service")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FailingAfterWriteSync(SessionProviderSync):
    def prune_transactions(self):
        raise RuntimeError("injected failure after writes")


class FailingRefreshSync(SessionProviderSync):
    def create_full_backup(self, schema_fingerprint, reason):
        raise RuntimeError("injected full backup refresh failure")


class SessionProviderSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.codex_home = self.root / ".codex"
        self.backup_root = self.codex_home / "codex-mode-switch-backups"
        (self.codex_home / "sessions").mkdir(parents=True)
        (self.codex_home / "archived_sessions").mkdir()
        self.config_path = self.codex_home / "config.toml"
        self.config_path.write_text(self.config_for("custom"), encoding="utf-8")

        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            connection.execute(
                "create table threads (id text primary key, model_provider text, archived integer, has_user_event integer)"
            )
            connection.executemany(
                "insert into threads values (?, ?, 0, 1)",
                [
                    ("openai", "openai"),
                    ("cockpit", "codex_local_access"),
                    ("custom", "custom"),
                    ("unknown", "loomex"),
                ],
            )
            connection.commit()

        for relative, provider in [
            ("sessions/openai.jsonl", "openai"),
            ("sessions/cockpit.jsonl", "codex_local_access"),
            ("archived_sessions/custom.jsonl", "custom"),
            ("sessions/unknown.jsonl", "loomex"),
        ]:
            path = self.codex_home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps(
                    {"type": "session_meta", "payload": {"model_provider": provider}},
                    separators=(",", ":"),
                )
                + "\n"
                + json.dumps(
                    {"type": "response_item", "payload": {"text": "body-sentinel"}},
                    separators=(",", ":"),
                )
                + "\n",
                encoding="utf-8",
            )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def config_for(provider):
        top = "" if provider == "openai" else 'model_provider = "{}"\n'.format(provider)
        return (
            'model = "gpt-test"\n'
            + top
            + "\n[model_providers.codex_local_access]\n"
            + 'name = "Cockpit Test"\nwire_api = "responses"\n'
            + "\n[model_providers.custom]\n"
            + 'name = "CC Switch Test"\nwire_api = "responses"\n'
        )

    def args_for(self, target, config_changed=True, force=False, retention=2):
        updated = self.root / "updated-config.toml"
        updated.write_text(self.config_for(target), encoding="utf-8")
        return argparse.Namespace(
            codex_home=str(self.codex_home),
            backup_root=str(self.backup_root),
            target_provider=target,
            source_provider=[provider for provider in PROVIDERS if provider != target],
            updated_config=str(updated),
            config_changed=int(config_changed),
            full_backup_max_age_days=7,
            rollback_retention_count=retention,
            force_full_backup=int(force),
        )

    def assert_provider_state(self, target):
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            providers = dict(connection.execute("select id, model_provider from threads"))
        self.assertEqual(providers["unknown"], "loomex")
        self.assertEqual({providers[key] for key in ("openai", "cockpit", "custom")}, {target})

        for path in list((self.codex_home / "sessions").rglob("*.jsonl")) + list(
            (self.codex_home / "archived_sessions").rglob("*.jsonl")
        ):
            lines = path.read_text(encoding="utf-8-sig").splitlines()
            metadata = json.loads(lines[0])
            expected = "loomex" if path.name == "unknown.jsonl" else target
            self.assertEqual(metadata["payload"]["model_provider"], expected)
            self.assertEqual(json.loads(lines[1])["payload"]["text"], "body-sentinel")

    def test_reuses_full_backup_and_prunes_lightweight_transactions(self):
        first = SessionProviderSync(self.args_for("custom", config_changed=False)).run()
        self.assertTrue(first["full_backup_created"])
        self.assertEqual(first["full_backup_reason"], "missing")
        full_path = Path(first["full_backup_path"])
        full_hash = sha256(full_path)
        full_mtime = full_path.stat().st_mtime_ns

        with zipfile.ZipFile(full_path, "r") as archive:
            self.assertIsNone(archive.testzip())
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["session_file_count"], 4)
            self.assertIn("rollouts/sessions/openai.jsonl", archive.namelist())
            extracted_db = self.root / "snapshot.sqlite"
            extracted_db.write_bytes(archive.read("state_5.sqlite"))
        with closing(sqlite3.connect(extracted_db)) as connection:
            baseline = set(row[0] for row in connection.execute("select model_provider from threads"))
        self.assertEqual(baseline, {"openai", "codex_local_access", "custom", "loomex"})

        second = SessionProviderSync(self.args_for("openai")).run()
        third = SessionProviderSync(self.args_for("codex_local_access")).run()
        self.assertFalse(second["full_backup_created"])
        self.assertFalse(third["full_backup_created"])
        self.assertEqual(second["full_backup_reason"], "reused")
        self.assertEqual(sha256(full_path), full_hash)
        self.assertEqual(full_path.stat().st_mtime_ns, full_mtime)
        self.assertEqual(len(list(self.backup_root.glob("full-*.zip"))), 1)
        self.assertFalse(list(self.backup_root.glob(".full-candidate-*")))

        transactions = sorted((self.backup_root / "transactions").iterdir())
        self.assertEqual(len(transactions), 2)
        for transaction in transactions:
            rollback_text = (transaction / "rollback.json").read_text(encoding="utf-8")
            self.assertNotIn("body-sentinel", rollback_text)
            self.assertNotIn("response_item", rollback_text)
            self.assertEqual(json.loads(rollback_text)["status"], "completed")

        self.assert_provider_state("codex_local_access")

        idempotent = SessionProviderSync(
            self.args_for("codex_local_access", config_changed=False)
        ).run()
        self.assertIsNone(idempotent["transaction_path"])
        self.assertEqual(idempotent["full_backup_reason"], "not_required")
        self.assertEqual(len(list((self.backup_root / "transactions").iterdir())), 2)
        self.assertEqual(sha256(full_path), full_hash)

    def test_failure_after_writes_rolls_back_every_modified_store(self):
        file_paths = [
            self.config_path,
            self.codex_home / "sessions" / "openai.jsonl",
            self.codex_home / "sessions" / "cockpit.jsonl",
        ]
        before = {path: sha256(path) for path in file_paths}
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            database_before = list(
                connection.execute("select id, model_provider from threads order by id")
            )
        sync = FailingAfterWriteSync(self.args_for("custom", config_changed=True))
        with self.assertRaisesRegex(RuntimeError, "rolled back"):
            sync.run()
        self.assertEqual({path: sha256(path) for path in file_paths}, before)
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            database_after = list(
                connection.execute("select id, model_provider from threads order by id")
            )
        self.assertEqual(database_after, database_before)

        transactions = list((self.backup_root / "transactions").iterdir())
        self.assertEqual(len(transactions), 1)
        manifest = json.loads((transactions[0] / "rollback.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["status"], "rolled_back")

    def test_forced_refresh_is_atomic_and_retains_verified_baseline_on_failure(self):
        first = SessionProviderSync(self.args_for("custom", config_changed=False)).run()
        full_path = Path(first["full_backup_path"])
        original_hash = sha256(full_path)

        refreshed = SessionProviderSync(
            self.args_for("custom", config_changed=False, force=True)
        ).run()
        self.assertTrue(refreshed["full_backup_created"])
        self.assertEqual(refreshed["full_backup_reason"], "forced")
        verified_hash = sha256(full_path)
        self.assertNotEqual(verified_hash, original_hash)
        self.assertEqual(len(list(self.backup_root.glob("full-*.zip"))), 1)

        failed = FailingRefreshSync(
            self.args_for("custom", config_changed=False, force=True)
        ).run()
        self.assertEqual(failed["full_backup_reason"], "reused_after_refresh_failure")
        self.assertIn("injected full backup refresh failure", failed["full_backup_warning"])
        self.assertEqual(sha256(full_path), verified_hash)
        self.assertFalse(list(self.backup_root.glob(".full-candidate-*")))

    def test_database_schema_change_refreshes_the_single_full_baseline(self):
        first = SessionProviderSync(self.args_for("custom", config_changed=False)).run()
        full_path = Path(first["full_backup_path"])
        first_hash = sha256(full_path)

        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            connection.execute("create table schema_change_sentinel (id integer primary key)")
            connection.commit()

        refreshed = SessionProviderSync(self.args_for("openai")).run()
        self.assertTrue(refreshed["full_backup_created"])
        self.assertEqual(refreshed["full_backup_reason"], "sqlite_schema_changed")
        self.assertNotEqual(sha256(full_path), first_hash)
        self.assertEqual(len(list(self.backup_root.glob("full-*.zip"))), 1)
        self.assertFalse(list(self.backup_root.glob(".full-candidate-*")))


if __name__ == "__main__":
    unittest.main()
