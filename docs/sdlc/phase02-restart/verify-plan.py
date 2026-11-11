#!/usr/bin/env python3
"""Verify restart-plan structure without running or claiming runtime implementation."""

import hashlib
import re
from pathlib import Path


BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def main():
    plan = (BASE / "plan.md").read_text()
    pattern = (
        r"^\| (\d+) \| \[([a-z0-9-]+)\]\(tasks/([a-z0-9-]+)\.md\)"
        r" \| [^|]+ \| ([^|]+) \| (\d+) \| ([567]) \|$"
    )
    rows = re.findall(pattern, plan, re.M)
    require(len(rows) == 12, "expected twelve final task rows")
    order = [row[1] for row in rows]
    require(len(set(order)) == len(order), "duplicate task IDs")
    require([int(row[0]) for row in rows] == list(range(1, 13)), "execution order")
    require(all(row[1] == row[2] for row in rows), "task filename agreement")
    require({p.stem for p in (BASE / "tasks").glob("*.md")} == set(order), "task set")
    deps = {
        row[1]: [] if row[3] == "none" else row[3].split(", ") for row in rows
    }
    graph_match = re.search(r"```mermaid\nflowchart TD\n(.*?)```", plan, re.S)
    require(graph_match is not None, "Mermaid graph")
    graph = graph_match[1]
    nodes = re.findall(r'^    ([a-z0-9-]+)\["([a-z0-9-]+)"\]$', graph, re.M)
    edges = re.findall(r"^    ([a-z0-9-]+) --> ([a-z0-9-]+)$", graph, re.M)
    require(len(nodes) == len(order), "node count")
    require(all(a == b for a, b in nodes), "node labels")
    require({a for a, _ in nodes} == set(order), "node set")
    require(len(edges) == len(set(edges)), "duplicate graph edges")
    require(set(edges) == {(d, t) for t, ds in deps.items() for d in ds}, "graph dependencies")
    for task, prerequisites in deps.items():
        require(all(p in deps and order.index(p) < order.index(task) for p in prerequisites),
                f"{task}: missing, cyclic or out-of-order prerequisite")

    verification = (BASE / "verification.md").read_text()
    for row in rows:
        task, size = row[1], int(row[4])
        require(size in {1, 3, 5, 8}, f"{task}: final size must be at most 8")
        text = (BASE / "tasks" / f"{task}.md").read_text()
        require(f"Prerequisite IDs: {row[3]}\n" in text, f"{task}: prerequisite list")
        require(f"Final size: {size}\n" in text, f"{task}: size agreement")
        for heading in ["Startup and context recovery", "Objective and observable outcome",
                        "Prerequisites and required outputs", "Implementation and contracts",
                        "Focused tests and continuous integration", "Verification commands and acceptance",
                        "Documentation and intended commit", "Completion checklist", "Relative size"]:
            require(f"## {heading}\n" in text, f"{task}: missing {heading}")
        for term in ["phase02-restart-planning.md", "compaction summary", "both planning",
                     "three unsuccessful", "mix check", "pre-commit hook",
                     "Only after that working commit", "mix test test/mcp test/integration --warnings-as-errors"]:
            require(term in text, f"{task}: missing recovery/verification gate {term}")
        require(f"## {task}\n" in verification, f"{task}: missing verification entry")
        if "Status: pending implementation." in text:
            require("Execution evidence: pending implementation." in text, f"{task}: evidence status")
            require("- [x]" not in text, f"{task}: pending task has checked completion")

    require(re.findall(r"^\| (A\d\d) \|", plan, re.M)
            == [f"A{i:02}" for i in range(1, 15)], "acceptance row coverage")
    for line in plan.splitlines():
        if re.match(r"^\| A\d\d \|", line):
            owners = line.split("|")[3].strip().split(", ")
            require(all(owner in deps for owner in owners), f"criterion owners: {line}")
    adr = (ROOT / "docs/adr/001-architecture-initial-phases.md").read_text()
    criteria = adr.split("### 10.9 Acceptance criteria")[1].split("### 10.10")[0]
    require(criteria.count("- [ ]") == 14, "architecture acceptance criteria changed")
    for milestone in [5, 6, 7]:
        require(f"| {milestone} — " in plan, f"milestone {milestone} exit condition")
    require("| durable-workers | 13 |" in plan and "| durable-effects | 13 |" in plan,
            "original 13 sizing/split record")
    require(min(int(row[4]) for row in rows) == 1, "simplest task size anchor")

    checked = 0
    for path in [BASE / "plan.md", BASE / "verification.md", BASE / "planning-verification.md",
                 *(BASE / "tasks").glob("*.md")]:
        for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text()):
            if "://" in link or link.startswith("#"):
                continue
            require((path.parent / link.split("#")[0]).exists(), f"broken link: {path.name}: {link}")
            checked += 1
    rule = (ROOT / "rules/60-context-recovery.md").read_text()
    require(rule in (ROOT / "AGENTS.md").read_text(), "generated recovery rule")
    require("docs/sdlc/phase02-restart/plan.md" in rule, "Phase 2 recovery entry point")
    snapshot = ROOT / "docs/prompts/phase02-restart-planning.md"
    digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
    require(digest in (BASE / "planning-verification.md").read_text(), "assignment checksum")
    print(f"PASS: {len(rows)} tasks, {len(nodes)} nodes, {len(edges)} matching edges; "
          f"acyclic/order valid; 14 criteria; 3 milestones; sizes 1–8; {checked} local links; "
          "recovery and completion gates; generated rules; snapshot checksum.")
    print(f"Snapshot SHA-256: {digest}")


if __name__ == "__main__":
    main()
