#!/usr/bin/env python3
"""Audit sanitized actual Codex MCP observations without connecting to a runtime."""

import hashlib
import json
from pathlib import Path


EVIDENCE = Path(__file__).resolve().parents[1] / "docs/sdlc/phase01/evidence"
TOOLS = {
    "runtime_define", "runtime_start", "runtime_invoke", "runtime_replace",
    "runtime_inspect", "runtime_events", "runtime_stop",
}
WORKER_FIELDS = ("pid", "artifact_id", "state", "worker_revision", "state_revision")


def read_json(name):
    """Read one committed evidence object."""
    return json.loads((EVIDENCE / name).read_text())


def calls(number):
    """Read one actual CLI session's normalized MCP calls."""
    path = EVIDENCE / f"codex-session{number:02}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()]


def snapshots(records, worker):
    """Select direct worker observations, excluding summary pages."""
    return [call for call in records if call["tool"] == "runtime_inspect"
            and call["arguments"].get("worker_id") == worker]


def worker_fields(data):
    """Compare committed identity/state without unrelated runtime generation."""
    return {key: data.get(key) for key in WORKER_FIELDS}


def verify():
    """Require observations for every actual demonstration assertion."""
    first, second = calls(1), calls(2)
    sessions = read_json("codex-sessions.json")
    manifest = read_json("runtime-manifest.json")
    assert sessions[0]["thread_id"] != sessions[1]["thread_id"]
    assert all(session["exit_code"] == 0 for session in sessions)
    assert len(first) == sessions[0]["mcp_calls"]
    assert len(second) == sessions[1]["mcp_calls"]
    assert {call["tool"] for call in first} == TOOLS
    assert {call["tool"] for call in second} <= {"runtime_inspect", "runtime_events"}
    assert first[0]["tool"] == "runtime_inspect"
    assert first[0]["result"]["generation"] == 0
    assert first[0]["result"]["workers"] == []
    assert first[0]["result"]["health"] == "ok"
    for call in first + second:
        assert call["server"] == "elixir_mixir"
        assert call["status"] in ("completed", "failed")
        assert call["result"]["api_version"] == "1"
        if "request_id" in call["arguments"]:
            assert call["result"]["request_id"] == call["arguments"]["request_id"]
    artifacts = [call for call in first if call["tool"] == "runtime_define"
                 and call["result"].get("compilation_status") == "compiled"]
    assert len(artifacts) == 7
    for call in artifacts:
        digest = hashlib.sha256(call["arguments"]["source"].encode()).hexdigest()
        assert digest == call["result"]["source_hash"]
    starts = {call["arguments"]["worker_id"]: call["result"]
              for call in first if call["tool"] == "runtime_start"}
    assert set(starts) == {"counter", "aggregate", "probe"}
    counter = snapshots(first, "counter")
    aggregate = snapshots(first, "aggregate")
    assert {1, 3, 7} <= {call["result"]["state"].get("count") for call in counter}
    assert any(call["result"]["state"] == {"events": 2, "total": 5} for call in aggregate)
    assert aggregate[-1]["result"]["state"] == {"events": 3, "total": 12}
    final_counter = counter[-1]["result"]
    assert final_counter["state"] == {"schema": 2, "counter": {"count": 7, "target": "aggregate"}}
    assert final_counter["artifact"]["state_schema"] == 2
    assert final_counter["implementation_version"] == 4
    assert final_counter["worker_revision"] == 4 and final_counter["state_revision"] == 6
    assert all(call["result"]["pid"] == starts["counter"]["pid"] for call in counter)
    assert all(call["result"]["pid"] == starts["aggregate"]["pid"] for call in aggregate)
    replacements = [call for call in first if call["tool"] == "runtime_replace"
                    and not call["result"].get("code")]
    assert [call["result"]["migration_result"] for call in replacements] == ["preserved", "preserved", "migrated"]
    assert all(call["result"]["pid_before"] == call["result"]["pid_after"] == starts["counter"]["pid"] for call in replacements)
    failures = [call for call in first if call["result"].get("code")]
    assert sorted(call["result"]["code"] for call in failures) == [
        "CALLBACK_FAILED", "CALLBACK_FAILED", "COMPILE_FAILED", "MIGRATION_FAILED", "REVISION_CONFLICT"]
    assert sorted(call["arguments"]["event"]["amount"] for call in failures
                  if call["tool"] == "runtime_invoke") == [-1, 0]
    for failure in failures:
        before = [call for call in counter if call["index"] < failure["index"]][-1]
        after = [call for call in counter if call["index"] > failure["index"]][0]
        assert worker_fields(before["result"]) == worker_fields(after["result"])
    probe = snapshots(first, "probe")
    assert any(call["result"].get("state") == {"seen": 1} for call in probe)
    assert probe[-1]["result"]["status"] == "stopped"
    history = [record for call in first + second if call["tool"] == "runtime_events"
               for record in call["result"]["events"]]
    for event_type in ("effect_log", "effect_scheduled", "effect_delivered", "worker_stopped"):
        assert any(record["type"] == event_type and record["worker_id"] == "probe" for record in history)
    for worker in ("counter", "aggregate"):
        prior = snapshots(first, worker)[-1]["result"]
        fresh = snapshots(second, worker)[-1]["result"]
        assert fresh == prior
    summaries = [call["result"] for call in second if call["tool"] == "runtime_inspect"
                 and "worker_id" not in call["arguments"]]
    assert summaries and all(data["generation"] == final_counter["generation"] == 23 for data in summaries)
    assert all(data["effects"] == {"pending": 0, "reserved": 0, "timers": 0} for data in summaries)
    assert manifest["container_before_session1"] == manifest["container_after_session2"]
    assert manifest["container_after_session2"]["running"]
    isolation = manifest["isolation"]
    assert isolation["user"] == "1000:1000" and isolation["read_only"]
    assert isolation["memory_bytes"] == 536870912 and isolation["nano_cpus"] == 1000000000
    assert isolation["pids_limit"] == 128 and isolation["cap_drop"] == ["ALL"]
    assert isolation["mounts"] == [] and isolation["distribution_disabled"]
    assert isolation["network_mode"] == "host" and isolation["loopback_listener"] == "127.0.0.1:4100"
    assert "no-new-privileges" in isolation["security_opt"]
    assert isolation["tmpfs"] == {"/tmp": "rw,noexec,nosuid,size=128m"}
    assert manifest["offline_startup"]["network_mode"] == "none"
    assert manifest["offline_startup"]["http_status"] == 200
    assert manifest["offline_startup"]["image_id"] == manifest["image_id"]
    assert manifest["cleanup"]["demo_container_removed"]
    print(f"Verified {len(first)} + {len(second)} actual Codex MCP calls, seven tools, source hashes, arithmetic, failure preservation, fresh-client continuity and isolation.")


if __name__ == "__main__":
    verify()
