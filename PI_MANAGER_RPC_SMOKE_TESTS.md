# Pi Manager RPC Smoke Tests

Quick validation notes for checking Pi RPC mechanics and Pi Manager native bridge behavior without launching the macOS app.

## Model choice

Use cheap GLM/ZAI models for smoke tests:

```bash
pi --list-models glm
```

Recommended default:

```bash
--model zai/glm-4.5-air
```

Use OpenAI/expensive coding models only when you need high-quality code generation or deeper implementation reasoning. Smoke tests are mostly protocol/mechanics checks, so GLM is suitable.

## Baseline RPC session

Verify that Pi RPC starts and returns state:

```bash
SESSION_DIR="$(mktemp -d)"
pi --mode rpc \
  --model zai/glm-4.5-air \
  --no-tools \
  --no-skills \
  --no-context-files \
  --no-extensions \
  --session-dir "$SESSION_DIR" <<'JSON'
{"type":"get_state","id":"state"}
JSON
```

Expected: one JSON `response` with `command: "get_state"`, model info, session file, and session id.

## Ambient extension isolation check

Always include `--no-extensions` in native-child-style tests unless intentionally testing extension discovery. Without it, globally installed extensions may emit unrelated `extension_ui_request` events.

Good child baseline:

```bash
pi --mode rpc \
  --model zai/glm-4.5-air \
  --no-tools \
  --no-skills \
  --no-context-files \
  --no-extensions \
  --session-dir "$(mktemp -d)"
```

## Built-in tool execution check

Confirms RPC tool execution events are working:

```bash
python3 - <<'PY'
import json, os, selectors, subprocess, tempfile, time
cmd = [
    'pi', '--mode', 'rpc', '--model', 'zai/glm-4.5-air',
    '--no-skills', '--no-context-files', '--no-extensions',
    '--tools', 'bash', '--session-dir', tempfile.mkdtemp(prefix='pi-rpc-bash-')
]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
p.stdin.write(json.dumps({'type':'prompt','id':'prompt','message':'Use the bash tool to run: printf SMOKE_OK'})+'\n'); p.stdin.flush()
start = time.time()
try:
    while time.time() - start < 60:
        for key, _ in sel.select(timeout=1):
            line = key.fileobj.readline()
            if line and ('tool_execution' in line or 'SMOKE_OK' in line or key.data == 'err'):
                print(key.data.upper(), line.rstrip())
finally:
    p.terminate()
PY
```

Expected: `tool_execution_start`, `tool_execution_update`, and `tool_execution_end` for `bash`, with `SMOKE_OK` in the result.

## Bridge extension load checks

Extract or write the generated bridge extension sources, then verify Pi can load them:

```bash
pi --mode rpc \
  --model zai/glm-4.5-air \
  --no-tools \
  --no-skills \
  --no-context-files \
  --no-extensions \
  --extension /path/to/managed-subagent-bridge.ts \
  --session-dir "$(mktemp -d)" <<'JSON'
{"type":"get_state","id":"state"}
JSON
```

Repeat for `contact-supervisor-bridge.ts`.

Expected: no “failed to load extension” errors.

## Parent bridge smoke: `managed_subagent`

Run Pi RPC with only the parent bridge extension and ask GLM to call `managed_subagent`:

```bash
python3 - <<'PY'
import json, os, selectors, subprocess, tempfile, time
ext = '/path/to/managed-subagent-bridge.ts'
cmd = [
    'pi', '--mode', 'rpc', '--model', 'zai/glm-4.5-air',
    '--no-skills', '--no-context-files', '--no-extensions',
    '--extension', ext, '--tools', 'managed_subagent',
    '--system-prompt', 'You are a test agent. Use tools when asked.',
    '--session-dir', tempfile.mkdtemp(prefix='pi-rpc-parentbridge-')
]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
def send(obj): p.stdin.write(json.dumps(obj)+'\n'); p.stdin.flush()
send({'type':'prompt','id':'prompt','message':'Use managed_subagent with agent scout, task say hello, context fresh.'})
start = time.time()
try:
    while time.time() - start < 90:
        for key, _ in sel.select(timeout=1):
            line = key.fileobj.readline()
            if not line: continue
            if key.data == 'err' or 'tool_execution' in line or 'extension_ui' in line:
                print(key.data.upper(), line.rstrip())
            if key.data == 'out':
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get('type') == 'extension_ui_request' and ev.get('method') == 'editor':
                    print('PAYLOAD', ev.get('prefill'))
                    send({'type':'extension_ui_response','id':ev.get('id'),'value':'NATIVE_CHILD_RESULT'})
finally:
    p.terminate()
PY
```

Expected:

- `tool_execution_start` for `managed_subagent`
- `extension_ui_request` with title `PI_MANAGER_BRIDGE managed_subagent`
- payload includes `agent`, `task`, `context`, and `toolCallId`
- host `extension_ui_response` becomes the tool result

## Child bridge smoke: `contact_supervisor`

Run Pi RPC with only the child bridge extension and ask GLM to call `contact_supervisor`:

```bash
python3 - <<'PY'
import json, os, selectors, subprocess, tempfile, time
ext = '/path/to/contact-supervisor-bridge.ts'
cmd = [
    'pi', '--mode', 'rpc', '--model', 'zai/glm-4.5-air',
    '--no-skills', '--no-context-files', '--no-extensions',
    '--extension', ext, '--tools', 'contact_supervisor',
    '--system-prompt', 'You are a test agent. Use tools when asked.',
    '--session-dir', tempfile.mkdtemp(prefix='pi-rpc-childbridge-')
]
env = {**os.environ, 'PI_MANAGER_SUBAGENT_RUN_ID':'TEST_RUN', 'PI_MANAGER_SUBAGENT_AGENT':'test-agent'}
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
def send(obj): p.stdin.write(json.dumps(obj)+'\n'); p.stdin.flush()
send({'type':'prompt','id':'prompt','message':'Use contact_supervisor with kind progress_update, title Smoke, message Hello supervisor.'})
start = time.time()
try:
    while time.time() - start < 90:
        for key, _ in sel.select(timeout=1):
            line = key.fileobj.readline()
            if not line: continue
            if key.data == 'err' or 'tool_execution' in line or 'extension_ui' in line:
                print(key.data.upper(), line.rstrip())
            if key.data == 'out':
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get('type') == 'extension_ui_request' and ev.get('method') == 'editor':
                    print('PAYLOAD', ev.get('prefill'))
                    send({'type':'extension_ui_response','id':ev.get('id'),'value':'OK_FROM_SUPERVISOR'})
finally:
    p.terminate()
PY
```

Expected:

- `tool_execution_start` for `contact_supervisor`
- `extension_ui_request` with title `PI_MANAGER_BRIDGE contact_supervisor`
- payload includes `requestKind`, `title`, `message`, `runID`, `agent`, and `toolCallId`
- host `extension_ui_response` becomes the tool result

## Parent bridge smoke: `managed_chain`

Run Pi RPC with the parent bridge and ask GLM to call `managed_chain`:

```bash
python3 - <<'PY'
import json, selectors, subprocess, tempfile, time
ext = '/path/to/managed-subagent-bridge.ts'
cmd = [
    'pi', '--mode', 'rpc', '--model', 'zai/glm-4.5-air',
    '--no-skills', '--no-context-files', '--no-extensions',
    '--extension', ext, '--tools', 'managed_chain',
    '--system-prompt', 'You are a test agent. Use tools when asked.',
    '--session-dir', tempfile.mkdtemp(prefix='pi-rpc-chainbridge-')
]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
def send(obj): p.stdin.write(json.dumps(obj)+'\n'); p.stdin.flush()
send({'type':'prompt','id':'prompt','message':'Use managed_chain with chain smoke-chain and task say hello, worktree false.'})
start = time.time()
try:
    while time.time() - start < 90:
        for key, _ in sel.select(timeout=1):
            line = key.fileobj.readline()
            if not line: continue
            if key.data == 'err' or 'tool_execution' in line or 'extension_ui' in line:
                print(key.data.upper(), line.rstrip())
            if key.data == 'out':
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get('type') == 'extension_ui_request' and ev.get('method') == 'editor':
                    print('PAYLOAD', ev.get('prefill'))
                    send({'type':'extension_ui_response','id':ev.get('id'),'value':'NATIVE_CHAIN_RESULT'})
finally:
    p.terminate()
PY
```

Expected: `extension_ui_request` title `PI_MANAGER_BRIDGE managed_chain`; payload includes `chain`, `task`, `worktree`, and `toolCallId`.

## Parent bridge smoke: `managed_parallel`

Run Pi RPC with the parent bridge and ask GLM to call `managed_parallel`:

```bash
python3 - <<'PY'
import json, selectors, subprocess, tempfile, time
ext = '/path/to/managed-subagent-bridge.ts'
cmd = [
    'pi', '--mode', 'rpc', '--model', 'zai/glm-4.5-air',
    '--no-skills', '--no-context-files', '--no-extensions',
    '--extension', ext, '--tools', 'managed_parallel',
    '--system-prompt', 'You are a test agent. Use tools when asked.',
    '--session-dir', tempfile.mkdtemp(prefix='pi-rpc-parallelbridge-')
]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
def send(obj): p.stdin.write(json.dumps(obj)+'\n'); p.stdin.flush()
send({'type':'prompt','id':'prompt','message':'Use managed_parallel with two scout tasks that say hello, concurrency 2, worktree false.'})
start = time.time()
try:
    while time.time() - start < 90:
        for key, _ in sel.select(timeout=1):
            line = key.fileobj.readline()
            if not line: continue
            if key.data == 'err' or 'tool_execution' in line or 'extension_ui' in line:
                print(key.data.upper(), line.rstrip())
            if key.data == 'out':
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get('type') == 'extension_ui_request' and ev.get('method') == 'editor':
                    print('PAYLOAD', ev.get('prefill'))
                    send({'type':'extension_ui_response','id':ev.get('id'),'value':'NATIVE_PARALLEL_RESULT'})
finally:
    p.terminate()
PY
```

Expected: `extension_ui_request` title `PI_MANAGER_BRIDGE managed_parallel`; payload includes `tasks`, `concurrency`, `worktree`, and `toolCallId`.

## Isolated worktree workflow smoke

This one is best run against a disposable git repo or temporary branch from the macOS app because the Swift workflow validates the persisted run record before applying/discarding.

Expected app behavior:

1. Run a native subagent with worktree isolation enabled.
2. Let the child edit a file in the isolated worktree.
3. Use run card → Artifacts → Generate/Open Worktree Patch.
4. Confirm `worktree.patch` appears under the run artifact directory.
5. Apply should refuse if the parent checkout is dirty.
6. Apply should run `git apply --check --3way --binary` before mutating the parent checkout.
7. Discard should run `git worktree remove --force <run-worktree>` and keep the artifact directory.

## Notes

- The bridge tools should use TypeBox schemas and `StringEnum` for string enums. Plain JSON-schema-shaped objects may load but can make tool execution unreliable.
- These tests validate Pi RPC mechanics, extension loading, tool execution, and extension UI routing. They do not validate SwiftUI rendering or full app lifecycle.
- Full macOS app build validation currently runs in GitHub Actions with `runs-on: macos-26` and Xcode 26.4+.
