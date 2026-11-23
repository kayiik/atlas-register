"""Publish retained Atlas payloads without changing their evidence.

The caller owns evidence collection. This shared publisher owns transport,
preview, retries and exact readback. Its command always leaves delivery green.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


class Refused(ValueError):
    pass


class Unreachable(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def stamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError, TypeError) as exc:
        raise Refused("invalid observation timestamp") from exc
    require(parsed.tzinfo is not None, "observation timestamp needs a timezone")
    return parsed


def matches(expected, actual):
    if not isinstance(actual, dict):
        return False
    return all(
        key in actual
        and (
            stamp(actual[key]) == stamp(value)
            if key == "observed_at"
            else actual[key] == value
        )
        for key, value in expected.items()
    )


def record_matches(expected, actual):
    return isinstance(actual, dict) and all(
        actual.get(key) == expected.get(key)
        for key in ("document_id", "source_repository", "source_revision", "content")
    )


def load_payload(env):
    """Validate the entire outbox before any network write, including previews."""
    moment = env.get("ATLAS_MOMENT", "")
    require(moment in {"record", "merge", "release", "deploy"}, "invalid moment")
    repo = env.get("ATLAS_REPOSITORY", "").lower()
    require(re.fullmatch(r"[a-z0-9_.-]+/[a-z0-9_.-]+", repo), "invalid repository")
    payload = json.loads(Path(env["ATLAS_PAYLOAD_FILE"]).read_text(encoding="utf-8"))
    if moment in {"record", "merge"}:
        require(isinstance(payload, dict), "record payload must be an object")
        require(payload.get("source_repository") == repo, "record repository mismatch")
        require(
            payload.get("content", {}).get("repository", {}).get("id") == repo,
            "record owner mismatch",
        )
        revision = env.get("ATLAS_REVISION", "")
        require(re.fullmatch(r"[a-f0-9]{40}", revision), "revision must be a full SHA")
        require(payload.get("source_revision") == revision, "record revision mismatch")
        document_id = payload.get("document_id", "")
        require(
            isinstance(document_id, str)
            and re.fullmatch(r"[a-z0-9][a-z0-9._/-]{1,160}", document_id),
            "invalid document id",
        )
        selected = env.get("ATLAS_DOCUMENT_ID", "")
        require(not selected or selected == document_id, "document id mismatch")
        return repo, [
            ("/v1/semantics/" + urllib.parse.quote(document_id, safe="/"), payload)
        ]

    require(
        isinstance(payload, list) and 0 < len(payload) <= 100,
        "report payload must be a nonempty list of at most 100 reports",
    )
    kind = {"release": "release_summary", "deploy": "deployment_summary"}[moment]
    bindings = set()
    entries = []
    for item in payload:
        require(isinstance(item, dict), "report must be an object")
        require(item.get("repository_id") == repo, "report repository mismatch")
        require(item.get("kind") == kind, "report kind does not match moment")
        for field in ("subject", "source", "state"):
            require(
                isinstance(item.get(field), str)
                and re.fullmatch(r"[a-z0-9][a-z0-9._/-]{1,160}", item[field]),
                "invalid report binding or state",
            )
        require(
            item["source"] not in {"http", "gatus"}, "health sources belong to Atlas"
        )
        require(
            stamp(item.get("observed_at")) <= datetime.now(timezone.utc),
            "observation is in the future",
        )
        require(
            isinstance(item.get("details"), dict), "report details must be an object"
        )
        binding = (item["subject"], item["source"], kind)
        require(binding not in bindings, "duplicate report binding")
        bindings.add(binding)
        entries.append(
            (
                "/v1/foreign-summaries/" + urllib.parse.quote(item["subject"], safe=""),
                item,
            )
        )
    return repo, entries


class Client:
    def __init__(self, env, *, opener=None, sleep=time.sleep):
        self.url = env.get("ATLAS_URL", "").rstrip("/")
        parsed = urllib.parse.urlsplit(self.url)
        require(
            parsed.scheme in {"http", "https"}
            and parsed.hostname
            and not (
                parsed.username or parsed.password or parsed.query or parsed.fragment
            ),
            "Atlas URL must be an HTTP(S) base without private URL parts",
        )
        self.read_key = env.get("ATLAS_READ_KEY", "")
        self.writer_key = env.get("ATLAS_WRITER_KEY", "")
        require(self.read_key, "read key is required")
        require(
            all(
                "\r" not in value and "\n" not in value
                for value in (self.read_key, self.writer_key)
            ),
            "invalid credential header",
        )
        dry_run = env.get("ATLAS_DRY_RUN", "false")
        require(dry_run in {"true", "false"}, "dry-run must be true or false")
        self.dry = dry_run == "true" or not self.writer_key
        self.open = opener or urllib.request.build_opener(NoRedirect).open
        self.sleep = sleep

    def request(self, path, body=None, *, preview=False):
        headers = {"X-Atlas-Key": self.read_key, "User-Agent": "atlas-register"}
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode()
            if preview:
                path += "?dry_run=true"
            else:
                headers["X-Atlas-Writer-Key"] = self.writer_key
        request = urllib.request.Request(
            self.url + path,
            data=data,
            headers=headers,
            method="PUT" if body is not None else "GET",
        )
        for attempt in range(3):
            try:
                with self.open(request, timeout=30) as response:
                    return json.loads(response.read())
            except urllib.error.HTTPError as exc:
                if exc.code < 500:
                    raise Refused(f"Atlas returned HTTP {exc.code}") from exc
            except (urllib.error.URLError, TimeoutError, OSError):
                pass
            if attempt < 2:
                self.sleep(2 ** (attempt + 1))
        raise Unreachable("Atlas did not answer after three attempts")

    def context(self, repo):
        return self.request(
            "/v1/context/repository/" + urllib.parse.quote(repo, safe="/")
        )


def check_answer(expected, actual, *, record=False, preview=False):
    answer = actual.get("answer", {})
    require(isinstance(answer, dict), "Atlas omitted its answer")
    if preview:
        require(answer.get("dry_run") is True, "Atlas did not confirm a dry run")
    require(
        not any(
            field.get("result") in {"skipped", "kept", "refused"}
            for field in answer.get("fields", [])
        ),
        "Atlas did not apply the complete payload",
    )
    require(
        (record_matches if record else matches)(expected, actual),
        "Atlas response differs from the retained payload",
    )
    outcome = answer.get("outcome", "")
    require(
        outcome in {"created", "updated", "unchanged"},
        "Atlas did not confirm publication",
    )
    return outcome


def publish(env, *, client=None):
    repo, entries = load_payload(env)
    client = client or Client(env)
    record = env["ATLAS_MOMENT"] in {"record", "merge"}
    guard_path = env.get("ATLAS_EXPECTED_CURRENT_FILE", "")
    require(record or not guard_path, "current-record guard is only valid for records")
    guard = (
        json.loads(Path(guard_path).read_text(encoding="utf-8")) if guard_path else None
    )
    if guard_path:
        require(
            isinstance(guard, dict) and guard.get("source_repository") == repo,
            "invalid current-record guard",
        )
    outcomes = []
    # Preview the complete list first: a later refused report must not leave an
    # earlier report published. A transport failure during real writes can still
    # leave a partial batch; replay this unchanged outbox to finish it.
    for path, payload in entries:
        outcomes.append(
            check_answer(
                payload,
                client.request(path, payload, preview=True),
                record=record,
                preview=True,
            )
        )
    if client.dry:
        return outcomes[-1], False
    if record:
        current = client.context(repo).get("semantics", [])
        require(len(current) <= 1, "ambiguous existing repository record")
        if guard_path:
            require(
                len(current) == 1 and record_matches(guard, current[0]),
                "repository record changed since preparation; prepare it again",
            )
        before = current
        # Keep preview and last conflict check in this shared publication step.
        require(
            client.context(repo).get("semantics", []) == before,
            "repository record changed during preview",
        )
    outcomes = []
    for path, payload in entries:
        outcomes.append(
            check_answer(payload, client.request(path, payload), record=record)
        )
    context = client.context(repo)
    for _, payload in entries:
        if record:
            candidates = [
                item
                for item in context.get("semantics", [])
                if item.get("document_id") == payload["document_id"]
            ]
            exact = record_matches
        else:
            candidates = [
                item
                for item in context.get("foreign_summaries", [])
                if all(
                    item.get(key) == payload[key]
                    for key in ("repository_id", "subject", "source", "kind")
                )
            ]
            exact = matches
        require(
            len(candidates) == 1 and exact(payload, candidates[0]),
            "stored Atlas context differs from retained evidence",
        )
        require(
            candidates[0].get("freshness", "fresh") == "fresh",
            "stored Atlas evidence is stale",
        )
    outcome = (
        "updated"
        if "updated" in outcomes
        else ("created" if "created" in outcomes else "unchanged")
    )
    return outcome, True


def main():
    outcome, verified = "refused", False
    reason = ""
    try:
        outcome, verified = publish(os.environ)
    except Unreachable:
        outcome = "unreachable"
        print(
            "::warning::atlas-register: Atlas unavailable; replay the retained payload"
        )
    except Refused as exc:
        # These diagnostics are controlled messages, never provider bodies.
        reason = str(exc)
        print(f"::warning::atlas-register: {reason}")
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        # Never echo input, credentials or provider response bodies into logs.
        print(
            "::warning::atlas-register: payload refused or exact readback failed; nothing verified"
        )
    result = f"outcome={outcome}\nverified={str(verified).lower()}\n"
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(result)
    message = f"### Atlas retained payload\nOutcome: **{outcome}**\nExact stored readback: **{str(verified).lower()}**\n"
    if reason:
        message += reason + "\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(message)
    else:
        print(message)


if __name__ == "__main__":
    main()
