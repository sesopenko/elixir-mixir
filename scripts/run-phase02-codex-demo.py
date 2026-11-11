#!/usr/bin/env python3
"""Run two actual Codex MCP clients around a disconnected production recovery interval."""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_smoke", ROOT / "scripts/smoke-phase02-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
EVIDENCE = ROOT / "docs/sdlc/phase02-restart/evidence"
TOOLS = {"runtime_define", "runtime_start", "runtime_invoke", "runtime_replace", "runtime_stop", "runtime_inspect", "runtime_events"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(name, data):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / name).write_text(json.dumps(data, indent=2) + "\n")


def extract(raw):
    events = [json.loads(line) for line in raw.read_text().splitlines() if line.strip()]
    thread = next(event["thread_id"] for event in events if event["type"] == "thread.started")
    assert any(event["type"] == "turn.completed" for event in events)
    calls = []
    for event in events:
        if event["type"] != "item.completed":
            continue
        item = event["item"]
        assert item["type"] not in {"command_execution", "file_change", "web_search"}, item["type"]
        if item["type"] != "mcp_tool_call":
            continue
        assert item["server"] == "elixir_mixir" and item["tool"] in TOOLS
        result = item.get("result") or {}
        data = result.get("structuredContent", result.get("structured_content"))
        if data is None:
            text = next(block["text"] for block in result["content"] if block["type"] == "text")
            data = json.loads(text)
        calls.append({"index": len(calls) + 1, "server": item["server"], "tool": item["tool"],
                      "arguments": item["arguments"], "status": item["status"], "result": data})
    return thread, calls


class Demo(release.Smoke):
    def __init__(self):
        super().__init__("elixir-mixir:phase02")
        self.prefix = "mixir-phase02-codex-" + uuid.uuid4().hex[:12]
        self.volume = self.prefix + "-data"
        self.observations = []
        self.sessions = []
        self.client_dir = Path(tempfile.mkdtemp(prefix="mixir-phase02-client-"))

    def codex_session(self, number):
        prompt = ROOT / f"docs/prompts/phase02-demo-session{number:02}.md"
        raw = self.client_dir / f"session{number:02}.raw.jsonl"
        final = self.client_dir / f"session{number:02}.final.json"
        error = self.client_dir / f"session{number:02}.stderr"
        config = f'mcp_servers.elixir_mixir={{url="{self.base}/mcp",required=true,default_tools_approval_mode="approve",startup_timeout_sec=15,tool_timeout_sec=15}}'
        command = ["codex", "exec", "--ignore-user-config", "--ephemeral", "--sandbox", "read-only",
                   "--skip-git-repo-check", "--cd", str(self.client_dir), "--json", "--config", config,
                   "--output-last-message", str(final), "-"]
        input_path = prompt
        amendments = []
        if number == 2:
            amendment = ROOT / "docs/prompts/phase02-demo-session02-contract-amendment.md"
            input_path = self.client_dir / "session02-complete-prompt.md"
            input_path.write_text(prompt.read_text() + "\n" + amendment.read_text())
            amendments = ["../../../prompts/phase02-demo-session02-contract-amendment.md"]
        started = now()
        with input_path.open() as input_file, raw.open("w") as output_file, error.open("w") as error_file:
            process = subprocess.Popen(command, stdin=input_file, stdout=output_file, stderr=error_file)
            deadline = time.monotonic() + 1_200
            while process.poll() is None:
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    print(json.dumps({"phase": "codex-running", "session": number, "pid": process.pid,
                                      "transcript_bytes": raw.stat().st_size}), flush=True)
                if time.monotonic() > deadline:
                    process.terminate()
                    process.wait(timeout=10)
                    raise RuntimeError("Codex session exceeded its finite demonstration deadline")
        assert process.returncode == 0, f"Codex exit {process.returncode}; inspect {error}"
        exited = now()
        thread, calls = extract(raw)
        report = json.loads(final.read_text())
        normalized = EVIDENCE / f"codex-session{number:02}.jsonl"
        normalized.write_text("".join(json.dumps(call, separators=(",", ":")) + "\n" for call in calls))
        save(f"codex-session{number:02}-final.json", report)
        metadata = {"session": number, "thread_id": thread, "mcp_calls": len(calls),
                    "tools": sorted({call["tool"] for call in calls}), "exit_code": process.returncode,
                    "started_at": started, "exited_at": exited, "client_pid": process.pid,
                    "prompt": f"../../../prompts/phase02-demo-session{number:02}.md", "amendments": amendments, "command": command}
        self.sessions.append(metadata)
        save("codex-sessions.json", self.sessions)
        print(json.dumps({"phase": "codex-exited", "session": number, "thread_id": thread,
                          "mcp_calls": len(calls)}), flush=True)
        return calls

    def observe(self, stage):
        self.initialize()
        snapshot = {"stage": stage, "observed_at": now(), "summary": self.tool("runtime_inspect", {})}
        for worker in ("counter", "aggregate", "stopped_probe"):
            snapshot[worker] = self.tool("runtime_inspect", {"worker_id": worker, "detail": "state"})
        snapshot["events"] = self.tool("runtime_events", {"limit": 100})
        self.disconnect()
        self.observations.append(snapshot)
        save("runtime-observations.json", self.observations)
        return snapshot

    def cold_snapshot(self, stage):
        # This reader runs only while the application container is stopped. It never puts records.
        code = '''{:ok, _} = Application.ensure_all_started(:cubdb)
{:ok, db} = CubDB.start_link(data_dir: "/data", auto_compact: false, auto_file_sync: true)
rows = Map.new(CubDB.select(db))
artifacts = for {{:artifact, id}, record} <- rows do
  hash = Base.encode16(:crypto.hash(:sha256, record["source"]), case: :lower)
  %{"id" => id, "record" => Map.delete(record, "source"), "stored_source_sha256" => hash}
end
result = %{"meta" => rows[:meta], "artifacts" => artifacts,
  "workers" => for({{:worker, id}, record} <- rows, do: %{"id" => id, "record" => record}),
  "states" => for({{:state, id}, record} <- rows, do: %{"id" => id, "record" => record}),
  "effects" => for({{:effect, id}, record} <- rows, do: %{"id" => id, "record" => record}),
  "edges" => for({{:edge, source, target}, record} <- rows, do: %{"source" => source, "target" => target, "record" => record}),
  "audits" => for({{:audit, sequence}, record} <- rows, do: %{"sequence" => sequence, "record" => record})}
IO.puts("MIXIR_RECORDS:" <> Jason.encode!(result))
GenServer.stop(db)
'''
        name = self.prefix + "-snapshot-" + stage
        self.containers.append(name)
        result = self.docker("run", "--rm", "--name", name, *self.flags(), "--mount",
                            f"type=volume,source={self.volume},target=/data", self.image, "eval", code)
        line = next(line for line in result.stdout.splitlines() if line.startswith("MIXIR_RECORDS:"))
        records = json.loads(line.removeprefix("MIXIR_RECORDS:"))
        save(f"store-{stage}.json", records)
        return records

    def container_witness(self, name, stage):
        container = self.inspect(name)
        save(f"container-{stage}.json", {
            "observed_at": now(), "id": container["Id"], "image": container["Image"],
            "host_pid": container["State"]["Pid"], "started_at": container["State"]["StartedAt"]})
        return container

    def run_demo(self):
        self.docker("volume", "create", "--label", "elixir-mixir.demo=phase02", self.volume)
        first = self.start("before")
        first_container = self.container_witness(first, "before")
        safety = self.permissions(first)
        self.initialize()
        catalog = self.rpc("tools/list", {})["result"]
        assert {tool["name"] for tool in catalog["tools"]} == TOOLS
        save("tool-catalog.json", catalog)
        self.disconnect()
        first_calls = self.codex_session(1)
        before = self.observe("before-kill")
        assert before["counter"]["state"]["counter"]["count"] == 13
        assert before["aggregate"]["state"] == {"events": 3, "total": 20}
        assert before["summary"]["effects"]["pending"] == 1
        assert before["summary"]["effects"]["timers"] == 1
        schedule = next(call for call in reversed(first_calls) if call["tool"] == "runtime_invoke"
                        and call["arguments"]["event"].get("op") == "schedule")
        effect_id = schedule["result"]["effects"][0]["effect_id"]
        killed_at = now()
        killed_ms = int(time.time() * 1000)
        self.docker("kill", "--signal", "KILL", first)
        assert self.docker("wait", first).stdout.strip() == "137"
        killed_state = self.inspect(first)["State"]
        save("termination-witness.json", {"killed_at": killed_at, "state": killed_state,
             "container_id": first_container["Id"], "effect_id": effect_id})
        assert not killed_state["OOMKilled"]
        self.docker("rm", first)
        closed = self.cold_snapshot("after-kill")
        assert len(closed["effects"]) == 1
        pending = closed["effects"][0]
        assert pending["id"] == effect_id and pending["record"]["status"] == "pending"
        assert pending["record"]["due_at"] > killed_ms
        second = self.start("after")
        second_container = self.container_witness(second, "after")
        restored = self.observe("restored-before-timer")
        assert restored["counter"]["state"] == before["counter"]["state"]
        for key in ("artifact_id", "worker_revision", "state_revision"):
            assert restored["counter"][key] == before["counter"][key]
        assert restored["aggregate"]["state"] == {"events": 3, "total": 20}
        assert restored["stopped_probe"]["status"] == "stopped"
        assert restored["summary"]["effects"]["pending"] == 1
        assert restored["summary"]["recovery"]["lineage_id"] == before["summary"]["recovery"]["lineage_id"]
        assert restored["summary"]["recovery"]["boot_id"] != before["summary"]["recovery"]["boot_id"]
        assert first_container["State"]["Pid"] != second_container["State"]["Pid"]
        self.initialize()
        polls = []
        deadline = time.monotonic() + 75
        while True:
            aggregate = self.tool("runtime_inspect", {"worker_id": "aggregate", "detail": "state"})
            polls.append({"observed_at": now(), "state": aggregate["state"]})
            if aggregate["state"] == {"events": 4, "total": 31}:
                break
            assert aggregate["state"] == {"events": 3, "total": 20}
            assert time.monotonic() < deadline
            time.sleep(1)
        self.disconnect()
        save("timer-observations.json", polls)
        completed = self.observe("timer-completed-without-codex")
        assert completed["summary"]["effects"]["pending"] == 0
        assert any(event.get("effect_id") == effect_id and event["type"] == "effect_delivered"
                   for event in completed["events"]["events"])
        print(json.dumps({"phase": "automatic-recovery-verified", "effect_id": effect_id,
                          "counter": 13, "aggregate": {"events": 4, "total": 31}}), flush=True)
        self.codex_session(2)
        final = self.observe("after-second-codex")
        assert final["counter"]["state"]["counter"]["count"] == 21
        assert final["counter"]["implementation_version"] == 3
        assert final["aggregate"]["state"] == {"events": 6, "total": 67}
        assert final["summary"]["effects"]["pending"] == 0
        assert self.sessions[0]["thread_id"] != self.sessions[1]["thread_id"]
        self.docker("stop", "--time", "30", second)
        stopped = self.inspect(second)["State"]
        save("normal-stop-witness.json", {"observed_at": now(), "state": stopped, "timeout_seconds": 30})
        assert stopped["ExitCode"] == 0
        final_store = self.cold_snapshot("final")
        assert final_store["effects"] == []
        save("restart-manifest.json", {"verified_at": now(), "volume": self.volume,
             "volume_retained": True, "image": self.image, "image_id": first_container["Image"],
             "endpoint": self.base + "/mcp", "safety": safety, "killed_at": killed_at,
             "kill_exit_code": killed_state["ExitCode"], "oom_killed": killed_state["OOMKilled"],
             "container_ids": [first_container["Id"], second_container["Id"]],
             "host_pids": [first_container["State"]["Pid"], second_container["State"]["Pid"]],
             "started_at": [first_container["State"]["StartedAt"], second_container["State"]["StartedAt"]],
             "effect_id": effect_id, "due_at": pending["record"]["due_at"],
             "no_codex_interval": {"from": self.sessions[0]["exited_at"], "until": self.sessions[1]["started_at"]},
             "commands": self.commands})
        print(json.dumps({"phase": "complete", "volume": self.volume, "sessions": len(self.sessions)}), flush=True)


def main():
    global EVIDENCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, default=EVIDENCE)
    args = parser.parse_args()
    EVIDENCE = args.evidence_dir.resolve()
    if (EVIDENCE / "codex-sessions.json").exists():
        raise RuntimeError("Preserve existing actual session evidence before starting another run")
    demo = Demo()
    try:
        demo.run_demo()
    except Exception as error:
        save("driver-failure.json", {"observed_at": now(), "type": type(error).__name__,
             "message": str(error), "volume": demo.volume, "commands": demo.commands})
        raise
    finally:
        demo.cleanup()


if __name__ == "__main__":
    main()
