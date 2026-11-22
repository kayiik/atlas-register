"""The retained-payload path preserves evidence and never guesses success."""

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publisher", ROOT / "publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def report(subject="worker"):
    return {
        "repository_id": "example/shop",
        "subject": subject,
        "source": "actual-deployer",
        "kind": "deployment_summary",
        "observed_at": "2026-01-01T00:00:00.123456Z",
        "state": "completed",
        "reason": "Migration finished successfully",
        "details_url": "https://ci.example/run/42",
        "details": {
            "version": "v2",
            "image": "registry.example/app@sha256:" + "a" * 64,
            "identifiers": [{"kind": "host", "value": "fixture-host"}],
            "config": [{"name": "DB", "source": "vault:shop/database"}],
        },
    }


def record():
    return {
        "document_id": "repository/shop",
        "source_repository": "example/shop",
        "source_revision": "a" * 40,
        "content": {
            "repository": {"id": "example/shop", "run_policy": "continuous"},
            "products": [{"id": "shop"}],
            "targets": [{"id": "production", "kind": "environment"}],
            "services": [
                {
                    "id": "migrator",
                    "kind": "worker",
                    "run_policy": "on_demand",
                    "target_id": "production",
                    "note": "Runs migrations",
                }
            ],
            "packages": [{"id": "release-contract", "kind": "schema"}],
            "relationships": [
                {"from_id": "migrator", "kind": "deployed_to", "to_id": "production"}
            ],
        },
    }


class FakeAtlas:
    dry = False

    def __init__(self):
        self.calls = []
        self.stored = []
        self.documents = []
        self.refuse_preview = None
        self.drop_echo = None
        self.change_readback = False
        self.fail_write = None

    def request(self, path, body, *, preview=False):
        self.calls.append((path, copy.deepcopy(body), preview))
        if (
            preview
            and self.refuse_preview
            and body.get("subject") == self.refuse_preview
        ):
            raise publisher.Refused("synthetic refusal")
        if not preview:
            if self.fail_write and body.get("subject") == self.fail_write:
                self.fail_write = None
                raise publisher.Unreachable("synthetic outage")
            if "source_repository" in body:
                self.documents = [copy.deepcopy(body)]
            else:
                self.stored = [
                    v for v in self.stored if v["subject"] != body["subject"]
                ]
                self.stored.append(copy.deepcopy(body))
        echoed = copy.deepcopy(body)
        if not preview and self.drop_echo:
            echoed.pop(self.drop_echo)
        return echoed | {
            "answer": {"outcome": "updated", "dry_run": preview, "fields": []}
        }

    def context(self, repo):
        stored = copy.deepcopy(self.stored)
        if self.change_readback:
            for item in stored:
                item["observed_at"] = "2026-02-01T00:00:00Z"
        return {"semantics": self.documents, "foreign_summaries": stored}


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "payload.json"
        self.env = {
            "ATLAS_PAYLOAD_FILE": str(self.path),
            "ATLAS_REPOSITORY": "example/shop",
            "ATLAS_REVISION": "a" * 40,
            "ATLAS_MOMENT": "deploy",
        }
        self.client = FakeAtlas()

    def save(self, value):
        self.path.write_text(json.dumps(value), encoding="utf-8")

    def run_publish(self):
        return publisher.publish(self.env, client=self.client)

    def test_retains_complete_migration_and_worker_evidence(self):
        values = [report(), report("migrator")]
        self.save(values)
        self.assertEqual(self.run_publish(), ("updated", True))
        self.assertEqual(self.client.stored, values)
        self.assertEqual(json.loads(self.path.read_text()), values)
        self.assertEqual([c[2] for c in self.client.calls], [True, True, False, False])

    def test_full_record_keeps_packages_targets_and_on_demand_policy(self):
        self.env["ATLAS_MOMENT"] = "record"
        self.save(record())
        self.assertEqual(self.run_publish(), ("updated", True))
        self.assertEqual(self.client.documents, [record()])

    def test_invalid_later_entry_and_duplicate_bindings_send_nothing(self):
        for values in (
            [report(), report() | {"repository_id": "other/repo"}],
            [report(), report()],
        ):
            self.save(values)
            with self.assertRaises(publisher.Refused):
                self.run_publish()
            self.assertEqual(self.client.calls, [])

    def test_later_server_preview_refusal_writes_nothing(self):
        self.save([report(), report("migrator")])
        self.client.refuse_preview = "migrator"
        with self.assertRaises(publisher.Refused):
            self.run_publish()
        self.assertEqual(self.client.stored, [])
        self.assertTrue(all(call[2] for call in self.client.calls))

    def test_dry_run_never_writes_or_claims_stored_verification(self):
        self.save([report()])
        self.client.dry = True
        self.assertEqual(self.run_publish(), ("updated", False))
        self.assertEqual(self.client.stored, [])

    def test_partial_outage_replays_the_original_timestamps(self):
        values = [report(), report("migrator")]
        self.save(values)
        self.client.fail_write = "migrator"
        with self.assertRaises(publisher.Unreachable):
            self.run_publish()
        self.assertEqual(self.client.stored, values[:1])
        self.assertEqual(self.run_publish(), ("updated", True))
        self.assertEqual(self.client.stored, values)

    def test_incomplete_echo_and_arbitrary_newer_context_do_not_verify(self):
        self.save([report()])
        self.client.drop_echo = "state"
        with self.assertRaises(publisher.Refused):
            self.run_publish()
        self.client.drop_echo = None
        self.client.change_readback = True
        with self.assertRaises(publisher.Refused):
            self.run_publish()

    def test_record_changed_since_ancestry_selection_is_not_written(self):
        self.env["ATLAS_MOMENT"] = "record"
        self.save(record())
        guard = Path(self.temp.name) / "current.json"
        guard.write_text(
            json.dumps(record() | {"source_revision": "b" * 40}), encoding="utf-8"
        )
        self.env["ATLAS_EXPECTED_CURRENT_FILE"] = str(guard)
        self.client.documents = [record() | {"source_revision": "c" * 40}]
        with self.assertRaises(publisher.Refused):
            self.run_publish()
        self.assertTrue(all(call[2] for call in self.client.calls))

    def test_record_revision_and_report_moment_must_match_selection(self):
        self.env["ATLAS_MOMENT"] = "record"
        self.save(record() | {"source_revision": "b" * 40})
        with self.assertRaises(publisher.Refused):
            self.run_publish()
        self.env["ATLAS_MOMENT"] = "release"
        self.save([report()])
        with self.assertRaises(publisher.Refused):
            self.run_publish()

    def test_cli_refusal_returns_zero_without_echoing_payload(self):
        self.path.write_text("sensitive invalid input", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(ROOT / "publish.py")],
            env=os.environ | self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("refused", result.stdout)
        self.assertNotIn("sensitive", result.stdout + result.stderr)

    def test_client_retries_transient_errors_with_unchanged_body(self):
        seen = []

        def opened(request, timeout):
            seen.append(request.data)
            if len(seen) < 3:
                raise urllib.error.HTTPError(
                    request.full_url, 503, "unavailable", {}, None
                )
            return BytesIO(json.dumps(report()).encode())

        env = self.env | {
            "ATLAS_URL": "https://atlas.example",
            "ATLAS_READ_KEY": "read",
            "ATLAS_WRITER_KEY": "writer",
        }
        client = publisher.Client(env, opener=opened, sleep=lambda _: None)
        self.assertEqual(client.request("/reports/worker", report()), report())
        self.assertEqual(len(seen), 3)
        self.assertTrue(all(body == seen[0] for body in seen))

    def test_redirect_is_refused_and_credentials_never_sent_to_another_origin(self):
        env = self.env | {
            "ATLAS_URL": "https://atlas.example",
            "ATLAS_READ_KEY": "read",
        }
        client = publisher.Client(env)
        handlers = client.open.__self__.handlers
        redirect = next(
            handler for handler in handlers if isinstance(handler, publisher.NoRedirect)
        )
        self.assertIsNone(
            redirect.redirect_request(
                None, None, 302, "redirect", {}, "https://other.example"
            )
        )


if __name__ == "__main__":
    unittest.main()
