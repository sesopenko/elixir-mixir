# Planning checkpoint verification

This records verification of the planning documents, not implementation of Phase 1.
The governing [assignment](../../prompts/phase01-planning.md) is preserved verbatim;
its SHA-256 is `10a4c96a842b7201f6298541ebc9fc486a5a17e202384f242d666fddc23c3b68`.
The [plan](plan.md) and ten task documents remain pending implementation.
Approved [amendment 01](../../prompts/phase01-planning-amendment-01.md) splits workers
into three tasks and requires real-HTTP checks within each feature checkpoint.
The original snapshot and its checksum are unchanged.

## Structural verification

Run this from the repository root. It checks exact task/node/edge sets, prerequisite
agreement, acyclicity, execution order, task recovery/gate sections, local links,
all fourteen ADR acceptance rows, inclusion of the generated recovery rule, amendment
links, feature ownership of all seven tools, and continuous HTTP verification gates.

```sh
python3 - <<'PY'
from pathlib import Path
import re, hashlib
base=Path('docs/sdlc/phase01')
plan=(base/'plan.md').read_text()
rows=re.findall(r'^\| (\d+) \| \[([a-z0-9-]+)\]\(tasks/([a-z0-9-]+)\.md\) \| [^|]+ \| ([^|]+) \|',plan,re.M)
assert len(rows)==10
order=[r[1] for r in rows]
assert len(order)==len(set(order))
assert [int(r[0]) for r in rows]==list(range(1,11))
deps={id:[] if dep.strip()=='none' else dep.strip().split(', ') for _,id,file,dep in rows if id==file}
assert len(deps)==10
assert set(p.stem for p in (base/'tasks').glob('*.md'))==set(order)
graph=re.search(r'```mermaid\nflowchart TD\n(.*?)```',plan,re.S)[1]
nodes=re.findall(r'^    ([a-z0-9-]+)\["([a-z0-9-]+)"\]$',graph,re.M)
assert len(nodes)==10 and all(a==b for a,b in nodes)
assert set(a for a,b in nodes)==set(order)
edges=re.findall(r'^    ([a-z0-9-]+) --> ([a-z0-9-]+)$',graph,re.M)
assert len(edges)==len(set(edges))
assert set(edges)=={(d,id) for id,ds in deps.items() for d in ds}
for id,ds in deps.items():
 assert all(d in deps and order.index(d)<order.index(id) for d in ds)
 text=(base/'tasks'/f'{id}.md').read_text()
 declared=re.search(r'^Prerequisite IDs: (.+)$',text,re.M)[1]
 assert declared==(', '.join(ds) if ds else 'none')
 assert len(re.findall(r'^## ',text,re.M))==9
 for term in ['compaction summary','both planning','mix check','pre-commit hook','three unsuccessful','Only after that working commit']:
  assert term in text,(id,term)
 assert 'Execution evidence: pending implementation.' in text
visiting=set();done=set()
def visit(node):
 assert node not in visiting
 if node in done:return
 visiting.add(node)
 for dep in deps[node]:visit(dep)
 visiting.remove(node);done.add(node)
for node in order:visit(node)
checked=0
for p in [base/'plan.md',*(base/'tasks').glob('*.md')]:
 for link in re.findall(r'\[[^\]]+\]\(([^)]+)\)',p.read_text()):
  if '://' in link or link.startswith('#'):continue
  assert (p.parent/link.split('#')[0]).exists(),(str(p),link)
  checked+=1
coverage=re.findall(r'^\| A(\d\d) \|',plan,re.M)
assert coverage==[f'{n:02}' for n in range(1,15)]
adr=Path('docs/adr/001-architecture-initial-phases.md').read_text()
criteria=adr.split('### 9.4 Acceptance criteria')[1].split('### 9.5')[0]
assert criteria.count('- [ ]')==14
rule=Path('rules/60-context-recovery.md').read_text()
assert rule in Path('AGENTS.md').read_text()
snapshot=Path('docs/prompts/phase01-planning.md').read_bytes()
assert snapshot.startswith(b'# Phase 1 planning assignment for the build agent\n')
assert snapshot.endswith(b'Stop after delivering the committed plan; runtime implementation is a subsequent assignment.\n')
assert order==['kernel-api','mcp-bootstrap','artifact-compiler','worker-start',
 'worker-invoke','worker-recovery','event-effects','runtime-inspection',
 'live-replacement','codex-demo']
assert not ({'worker-hosts','mcp-tools','runtime-integration'} & set(order))
amendment=Path('docs/prompts/phase01-planning-amendment-01.md')
assert amendment.exists()
for id in order:
 text=(base/'tasks'/f'{id}.md').read_text()
 assert 'phase01-planning-amendment-01.md' in text
 if id not in ['kernel-api','mcp-bootstrap','codex-demo']:
  assert 'mix test test/mcp test/integration --warnings-as-errors' in text,id
 if id!='kernel-api':
  assert 'HTTP' in text and 'growing real-HTTP integration suite' in text,id
owners={'mcp-bootstrap':['runtime_inspect'], 'artifact-compiler':['runtime_define'],
 'worker-start':['runtime_start','runtime_stop'], 'worker-invoke':['runtime_invoke'],
 'runtime-inspection':['runtime_events'], 'live-replacement':['runtime_replace']}
assert sum(len(names) for names in owners.values())==7
for id,names in owners.items():
 text=(base/'tasks'/f'{id}.md').read_text()
 assert all(name in text for name in names),(id,names)
assert hashlib.sha256(snapshot).hexdigest()=='10a4c96a842b7201f6298541ebc9fc486a5a17e202384f242d666fddc23c3b68'
print(f'PASS: {len(order)} tasks; {len(nodes)} unique graph nodes; {len(edges)} matching edges; acyclic; deterministic order valid; {checked} relative links; 14/14 acceptance rows; recovery rule generated; amendment linked in all tasks; 7 tools owned by feature tasks; continuous HTTP gates present.')
print('Snapshot SHA-256:',hashlib.sha256(snapshot).hexdigest())
PY
```

Result on 2026-11-10: PASS — 10 task documents, 10 unique graph nodes, 9 matching
dependency edges, acyclic graph, valid deterministic order, 53 relative links,
14/14 acceptance rows, and recovery rule present in generated AGENTS.md. All task
documents link the approved amendment, all seven MCP tools have an owning feature
task, and all HTTP-capable feature gates run their growing integration suite.

## Review and quality verification

- Reread AGENTS.md, CONTRIBUTING.md, ADR-001, assignment snapshot, approved amendment,
  plan and task drafts.
- Replaced worker-hosts with worker-start, worker-invoke and worker-recovery;
  reassigned all former mcp-tools/runtime-integration work to feature checkpoints.
  Reviewed early discovery counts, shared fixture ownership, callback failures,
  crash isolation, restart budgets, resource limits and reconnect/replay scenarios.
  Updated acceptance mappings and prerequisite graph; no runtime code changed.
- Reviewed all fourteen acceptance mappings against ADR section 9.4 and all seven
  tool contracts against section 7. Reviewed callback/timeout/restart/resource/revision
  and effect contracts for tasks that can pass using completed prerequisites alone.
- Verified official Hex release requirements for Hermes 0.14.1, Plug 1.18.1,
  Bandit 1.8.0 and Jason 1.4.4; inspected published Hermes/Bandit source and Code
  documentation. Sources and conflicting transport documentation decisions are in
  the plan. Future dependency resolution/compilation remains implementation work.
- Ran `./scripts/build-agent-rules.sh`; verified recovery rule text appears in
  generated AGENTS.md and the existing subtask workflow rule remains unchanged.
- `git diff --check`: passed.
- `mix check`: passed on Elixir 1.18.3 / OTP 27: 1 doctest, 11 tests, zero failures;
  strict Credo clean, Doctor documentation/typespec coverage 100%, Dialyzer zero errors.
  Mix needed local TCP permission for Mix.PubSub in this restricted environment.
- The normal pre-commit hook must rerun the complete gate for the planning commit.
  Its successful completion is evidenced by the resulting commit.

The original checkpoint added the snapshot, planning documents, recovery rule and
regenerated AGENTS.md. This amendment checkpoint changes only planning documents
and adds the separately preserved amendment; the original snapshot/rules are unchanged. No runtime feature or domain application is implemented. Untracked
scripts/codex.sh is unrelated and remains untouched. Automated runtime integration and
the actual Codex demonstration are future tasks, not claimed evidence here.
