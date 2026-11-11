#!/usr/bin/env python3
"""Exercise an owned production container/store; retain its named volume for inspection."""

import argparse
import datetime
import json
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid


SOURCE = '''defmodule Generated do
  @behaviour ElixirMixir.Behavior
  def init(config), do: {:ok, %{"count" => Map.get(config, "initial", 0)}}
  def handle_event(event, state) do
    count = state["count"] + Map.get(event, "amount", 1)
    {:ok, count, %{"count" => count}, []}
  end
  def state_schema(), do: 1
  def migrate(state, _metadata), do: {:ok, state}
end
'''


class Smoke:
    def __init__(self, image):
        self.image = image
        self.prefix = "mixir-phase02-smoke-" + uuid.uuid4().hex[:12]
        self.volume = self.prefix + "-data"
        self.containers = []
        self.commands = []
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.session = None
        self.rpc_id = 0

    def docker(self, *args, check=True):
        command = ["docker", *args]
        self.commands.append(command)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60, check=False)
        if check and result.returncode:
            raise RuntimeError(f"{command!r}: {result.stderr or result.stdout}")
        return result

    def inspect(self, name):
        return json.loads(self.docker("inspect", name).stdout)[0]

    def flags(self):
        return ["--network", "host", "--read-only", "--tmpfs",
                "/tmp:rw,noexec,nosuid,size=128m", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--memory", "512m",
                "--cpus", "1", "--pids-limit", "128"]

    def start(self, suffix):
        name = self.prefix + "-" + suffix
        self.containers.append(name)
        self.docker("run", "-d", "--name", name, *self.flags(), "--mount",
                    f"type=volume,source={self.volume},target=/data", "--env",
                    "ELIXIR_MIXIR_DATA_DIR=/data", "--env",
                    f"ELIXIR_MIXIR_PORT={self.port}", self.image)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(self.base + "/health", timeout=1) as response:
                    if response.status == 200 and json.load(response)["status"] == "ready":
                        return name
            except (OSError, urllib.error.HTTPError):
                pass
            if not self.inspect(name)["State"]["Running"]:
                raise RuntimeError(self.docker("logs", name).stdout)
            time.sleep(0.1)
        raise RuntimeError("Production release did not become ready")

    def rpc(self, method, params, notification=False):
        self.rpc_id += 1
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            message["id"] = self.rpc_id
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["mcp-session-id"] = self.session
        request = urllib.request.Request(self.base + "/mcp", json.dumps(message).encode(), headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            self.session = response.headers.get("mcp-session-id", self.session)
            body = response.read().decode()
        if not body:
            return None
        if body.startswith(("event:", "data:")):
            body = "\n".join(line[5:].strip() for line in body.splitlines() if line.startswith("data:"))
        return json.loads(body)

    def initialize(self):
        self.session = None
        result = self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                          "clientInfo": {"name": "mixir-release-smoke", "version": "1"}})
        assert "result" in result and self.session
        self.rpc("notifications/initialized", {}, notification=True)
        return self.session

    def tool(self, name, args):
        result = self.rpc("tools/call", {"name": name, "arguments": args})["result"]
        assert not result.get("isError"), result
        return result["structuredContent"]

    def disconnect(self):
        request = urllib.request.Request(self.base + "/mcp", method="DELETE",
                    headers={"mcp-session-id": self.session,
                             "Accept": "application/json, text/event-stream"})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status in (200, 202, 204)
        self.session = None

    def permissions(self, name):
        script = '''set -eu
[ "$(id -u)" = 1000 ]
[ "$(stat -c %u /app/bin/elixir_mixir)" = 0 ]
test -w /data
test ! -w /app
test ! -e /app/test
test ! -e /app/.git
test ! -e /app/.codex
test ! -e /app/.aws
test -z "$(find /app/lib -name '*TestSupport*' -o -name 'Elixir.ElixirMixir.Generated.Slot*.beam')"
touch /data/release-permission-proof
rm /data/release-permission-proof
'''
        self.docker("exec", name, "sh", "-c", script)
        config = self.inspect(name)
        assert config["Config"]["User"] == "1000:1000"
        assert config["HostConfig"]["ReadonlyRootfs"]
        assert config["HostConfig"]["CapDrop"] == ["ALL"]
        assert "no-new-privileges" in config["HostConfig"]["SecurityOpt"]
        assert config["HostConfig"]["NetworkMode"] == "host"
        assert config["HostConfig"]["PidsLimit"] == 128
        assert config["HostConfig"]["Memory"] == 512 * 1024 * 1024
        volumes = [mount for mount in config["Mounts"] if mount["Type"] == "volume"]
        assert len(volumes) == 1 and volumes[0]["Name"] == self.volume
        assert volumes[0]["Destination"] == "/data"
        assert all(mount["Type"] == "volume" or (mount["Type"] == "tmpfs" and mount["Destination"] == "/tmp") for mount in config["Mounts"])
        return {"user": config["Config"]["User"], "read_only_root": True,
                "application_owner_uid": 0, "data_writable": True,
                "test_and_generated_modules_absent": True, "only_volume": self.volume}

    def run(self):
        self.docker("volume", "create", "--label", "elixir-mixir.smoke=phase02", self.volume)
        first = self.start("first")
        safety = self.permissions(first)
        first_session = self.initialize()
        artifact = self.tool("runtime_define", {"logical_name": "release-counter", "source": SOURCE,
                             "expected_behavior": "elixir_mixir.behavior.v1", "request_id": "define"})
        self.tool("runtime_start", {"worker_id": "release_counter", "artifact_id": artifact["artifact_id"],
                  "config": {"initial": 7}, "request_id": "start"})
        assert self.tool("runtime_invoke", {"worker_id": "release_counter", "event": {"amount": 3},
                         "request_id": "first-event"})["reply"] == 10
        before = self.tool("runtime_inspect", {})
        before_worker = self.tool("runtime_inspect", {"worker_id": "release_counter", "detail": "state"})
        first_pid = self.inspect(first)["State"]["Pid"]
        self.disconnect()
        self.docker("kill", "--signal", "KILL", first)
        assert self.docker("wait", first).stdout.strip() == "137"
        killed = self.inspect(first)["State"]
        assert not killed["OOMKilled"] and killed["ExitCode"] == 137
        self.docker("rm", first)
        second = self.start("second")
        second_pid = self.inspect(second)["State"]["Pid"]
        assert first_pid != second_pid
        second_session = self.initialize()
        assert first_session != second_session
        after = self.tool("runtime_inspect", {})
        after_worker = self.tool("runtime_inspect", {"worker_id": "release_counter", "detail": "state"})
        assert before["recovery"]["boot_id"] != after["recovery"]["boot_id"]
        assert before["recovery"]["lineage_id"] == after["recovery"]["lineage_id"]
        assert after["storage"] == {"mode": "durable", "format_version": 1}
        assert after_worker["state"] == before_worker["state"] == {"count": 10}
        assert after_worker["artifact_id"] == artifact["artifact_id"]
        assert after_worker["state_revision"] == before_worker["state_revision"]
        assert self.tool("runtime_invoke", {"worker_id": "release_counter", "event": {"amount": 2},
                         "request_id": "continued"})["reply"] == 12
        request = urllib.request.Request(self.base + "/mcp", headers={
            "Accept": "text/event-stream", "mcp-session-id": self.session})
        stream = urllib.request.urlopen(request, timeout=45)
        assert stream.status == 200
        stopping = time.monotonic()
        self.docker("stop", "--time", "30", second)
        stop_seconds = time.monotonic() - stopping
        stream.close()
        self.session = None
        assert self.inspect(second)["State"]["ExitCode"] == 0
        denied = self.prefix + "-unwritable"
        self.containers.append(denied)
        self.docker("run", "-d", "--name", denied, *self.flags(), "--env",
                    "ELIXIR_MIXIR_DATA_DIR=/app/unwritable", "--env",
                    f"ELIXIR_MIXIR_PORT={self.port}", self.image)
        assert self.docker("wait", denied).stdout.strip() != "0"
        logs = self.docker("logs", denied)
        assert "storage_unavailable" in logs.stdout + logs.stderr
        return {"verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "image": self.image, "image_id": self.docker("image", "inspect", self.image, "--format", "{{.Id}}").stdout.strip(),
                "volume": self.volume, "volume_retained": True, "port": self.port,
                "safety": safety, "kill_signal": "KILL", "kill_exit_code": killed["ExitCode"],
                "oom_killed": killed["OOMKilled"], "host_pids": [first_pid, second_pid],
                "boot_ids": [before["recovery"]["boot_id"], after["recovery"]["boot_id"]],
                "lineage_id": after["recovery"]["lineage_id"],
                "restored_state": after_worker["state"], "continued_count": 12,
                "fresh_mcp_session": True, "normal_stop_exit_code": 0,
                "normal_stop_timeout_seconds": 30, "open_sse_during_stop": True,
                "normal_stop_elapsed_seconds": stop_seconds,
                "unwritable_storage_failed_closed": True, "commands": self.commands}

    def cleanup(self):
        for name in self.containers:
            self.docker("rm", "-f", name, check=False)
        # Named data volumes are deliberately retained, including after a failure.
        print(f"Retained smoke volume: {self.volume}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="elixir-mixir:phase02")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    smoke = Smoke(args.image)
    try:
        result = smoke.run()
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        smoke.cleanup()


if __name__ == "__main__":
    main()
