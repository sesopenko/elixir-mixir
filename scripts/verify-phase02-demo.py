#!/usr/bin/env python3
"""Audit actual Codex calls, cold-store records and independent recovery observations."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/sdlc/phase02-restart/evidence"
TOOLS = {"runtime_define", "runtime_start", "runtime_invoke", "runtime_replace", "runtime_stop", "runtime_inspect", "runtime_events"}


def read(name):
    return json.loads((EVIDENCE / name).read_text())


def calls(number):
    return [json.loads(line) for line in (EVIDENCE / f"codex-session{number:02}.jsonl").read_text().splitlines()]


def snapshots(records, worker):
    return [call for call in records if call["tool"] == "runtime_inspect" and call["arguments"].get("worker_id") == worker]


def stable(worker):
    return {key: worker[key] for key in ("artifact_id", "pid", "state", "worker_revision", "state_revision")}


def stamp(value):
    return datetime.datetime.fromisoformat(value).timestamp()


def row(store, table, identity):
    return next(entry["record"] for entry in store[table] if entry["id"] == identity)


def verify():
    first, second = calls(1), calls(2)
    sessions = read("codex-sessions.json")
    manifest = read("restart-manifest.json")
    observed = {entry["stage"]: entry for entry in read("runtime-observations.json")}
    cold, final_store = read("store-after-kill.json"), read("store-final.json")
    assert len(sessions) == 2 and sessions[0]["thread_id"] != sessions[1]["thread_id"]
    for number, records in enumerate((first, second), 1):
        session = sessions[number - 1]
        assert session["exit_code"] == 0 and session["mcp_calls"] == len(records)
        assert session["command"][:2] == ["codex", "exec"]
        assert "--ephemeral" in session["command"] and "--ignore-user-config" in session["command"]
        assert session["command"][session["command"].index("--sandbox") + 1] == "read-only"
        assert records[0]["tool"] == "runtime_inspect"
        for call in records:
            assert call["server"] == "elixir_mixir" and call["tool"] in TOOLS
            assert call["result"]["api_version"] == "1"
            if call["status"] == "failed":
                # Codex reports an MCP isError result as a failed tool item.
                assert call["tool"] == "runtime_invoke"
                assert call["arguments"]["event"] == {"amount": 0}
                assert call["result"]["code"] == "CALLBACK_FAILED"
            else:
                assert call["status"] == "completed"
            if "request_id" in call["arguments"]:
                assert call["result"]["request_id"] == call["arguments"]["request_id"]
        assert (ROOT / "docs/prompts" / Path(session["prompt"]).name).exists()
    assert {call["tool"] for call in first} == TOOLS
    assert {tool["name"] for tool in read("tool-catalog.json")["tools"]} == TOOLS
    assert first[0]["result"]["workers"] == [] and first[0]["result"]["generation"] == 0
    assert first[0]["result"]["storage"] == {"mode": "durable", "format_version": 1}
    definitions = [call for call in first + second if call["tool"] == "runtime_define" and call["result"].get("compilation_status") == "compiled"]
    assert len(definitions) == 4
    for call in definitions:
        assert hashlib.sha256(call["arguments"]["source"].encode()).hexdigest() == call["result"]["source_hash"]
        stored = next(entry for entry in final_store["artifacts"] if entry["id"] == call["result"]["artifact_id"])
        assert stored["stored_source_sha256"] == call["result"]["source_hash"] == stored["record"]["source_hash"]
    counter_definitions = [call["result"] for call in definitions if call["arguments"]["logical_name"] == "counter"]
    assert [artifact["revision"] for artifact in counter_definitions] == [1, 2, 3]
    assert [artifact["state_schema"] for artifact in counter_definitions] == [1, 2, 2]
    before = observed["before-kill"]
    restored = observed["restored-before-timer"]
    delivered = observed["timer-completed-without-codex"]
    final = observed["after-second-codex"]
    assert before["counter"]["state"] == {"schema": 2, "counter": {"count": 13, "target": "aggregate"}}
    assert before["aggregate"]["state"] == {"events": 3, "total": 20}
    assert before["summary"]["effects"] == {"dispatch": "enabled", "pending": 1, "reserved": 0, "timers": 1}
    assert restored["counter"]["state"] == before["counter"]["state"]
    for key in ("artifact_id", "worker_revision", "state_revision"):
        assert restored["counter"][key] == before["counter"][key]
    assert before["counter"]["worker_revision"] == 2 and before["counter"]["state_revision"] == 6
    assert restored["aggregate"]["state"] == {"events": 3, "total": 20}
    assert delivered["aggregate"]["state"] == {"events": 4, "total": 31}
    assert restored["summary"]["effects"]["pending"] == 1 and delivered["summary"]["effects"]["pending"] == 0
    for entry in observed.values():
        assert entry["stopped_probe"]["status"] == "stopped"
        assert entry["stopped_probe"]["state"]["count"] == 0
    assert before["summary"]["recovery"]["lineage_id"] == restored["summary"]["recovery"]["lineage_id"]
    assert before["summary"]["recovery"]["boot_id"] != restored["summary"]["recovery"]["boot_id"]
    assert restored["summary"]["recovery"]["boot_id"] == final["summary"]["recovery"]["boot_id"]
    assert len(set(manifest["container_ids"])) == 2 and len(set(manifest["host_pids"])) == 2
    assert manifest["kill_exit_code"] == 137 and manifest["oom_killed"] is False
    for index, stage in enumerate(("before", "after")):
        witness = read(f"container-{stage}.json")
        assert witness["id"] == manifest["container_ids"][index]
        assert witness["host_pid"] == manifest["host_pids"][index]
        assert witness["started_at"] == manifest["started_at"][index]
        assert witness["image"] == manifest["image_id"]
    termination = read("termination-witness.json")
    assert termination["container_id"] == manifest["container_ids"][0]
    assert termination["state"]["ExitCode"] == 137 and not termination["state"]["Running"]
    stopped = read("normal-stop-witness.json")
    assert stopped["timeout_seconds"] == 30 and stopped["state"]["ExitCode"] == 0
    assert manifest["safety"]["user"] == "1000:1000" and manifest["safety"]["read_only_root"]
    assert stamp(sessions[0]["exited_at"]) <= stamp(before["observed_at"]) <= stamp(manifest["killed_at"])
    assert stamp(manifest["killed_at"]) < stamp(restored["observed_at"]) < stamp(delivered["observed_at"]) < stamp(sessions[1]["started_at"])
    assert manifest["no_codex_interval"] == {"from": sessions[0]["exited_at"], "until": sessions[1]["started_at"]}
    pending = cold["effects"]
    assert len(pending) == 1 and pending[0]["id"] == manifest["effect_id"]
    intent = pending[0]["record"]
    assert intent["effect"] == {"type": "schedule", "to": "aggregate", "event": {"value": 11}, "delay_ms": 60000}
    assert intent["due_at"] == manifest["due_at"] > int(stamp(manifest["killed_at"]) * 1000)
    assert intent["status"] == "pending" and intent["source"] == "counter"
    assert row(cold, "states", "counter")["last_operation_id"] == intent["operation_id"]
    schedule = next(call for call in first if call["tool"] == "runtime_invoke" and call["arguments"]["event"].get("op") == "schedule")
    assert schedule["result"]["effects"][0]["effect_id"] == manifest["effect_id"]
    assert intent["correlation_id"] == schedule["arguments"]["request_id"]
    audits = [entry["record"] for entry in final_store["audits"] if entry["record"].get("effect_id") == manifest["effect_id"]]
    assert len(audits) == 1 and audits[0]["type"] == "effect_delivered" and audits[0]["outcome"] == "ok"
    assert final_store["effects"] == []
    assert final["counter"]["state"] == {"schema": 2, "counter": {"count": 21, "target": "aggregate"}}
    assert final["counter"]["worker_revision"] == 3 and final["counter"]["state_revision"] == 8
    assert final["aggregate"]["state"] == {"events": 6, "total": 67}
    assert row(final_store, "states", "counter")["data"] == final["counter"]["state"]
    assert row(final_store, "states", "aggregate")["data"] == final["aggregate"]["state"]
    assert final["summary"]["topology"] == [{"from": "counter", "to": "aggregate", "count": 6, "pending": 0}]
    initial_second = snapshots(second, "counter")[0]["result"]
    assert initial_second["state"] == restored["counter"]["state"]
    assert initial_second["artifact_id"] == restored["counter"]["artifact_id"]
    replacements = [call for call in first + second if call["tool"] == "runtime_replace" and not call["result"].get("code")]
    assert [call["result"]["migration_result"] for call in replacements] == ["migrated", "preserved"]
    assert all(call["result"]["pid_before"] == call["result"]["pid_after"] for call in replacements)
    rejection = next(call for call in second if call["tool"] == "runtime_invoke" and call["arguments"]["event"].get("amount") == 0)
    assert rejection["result"]["code"] == "CALLBACK_FAILED"
    counter_reads = snapshots(second, "counter")
    prior = [call for call in counter_reads if call["index"] < rejection["index"]][-1]
    later = [call for call in counter_reads if call["index"] > rejection["index"]][0]
    assert stable(prior["result"]) == stable(later["result"])
    for filename in ("codex-session01.jsonl", "codex-session02.jsonl", "codex-sessions.json"):
        text = (EVIDENCE / filename).read_text()
        assert "Authorization:" not in text and "Bearer " not in text and "sk-proj-" not in text
    print(f"PASS: {len(first) + len(second)} actual MCP calls in two distinct Codex sessions; migration, SIGKILL, automatic timer recovery, post-restart evolution and failure preservation verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, default=EVIDENCE)
    args = parser.parse_args()
    EVIDENCE = args.evidence_dir.resolve()
    verify()
