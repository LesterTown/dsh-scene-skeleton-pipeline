#!/usr/bin/env bash
#
# 阶段 3 验收脚本：流水线引擎（dry-run 节点编排）+ run_scene_pipeline 工具。
#
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step3.sh
#
# 覆盖：
#   1. 单元层：pipeline-harness.mjs（节点状态机、依赖阻塞、参数校验、job 存取、工具契约）
#   2. 真实宿主（隔离 DSH_HOME=.dsh-dev + --patch 覆盖层）：
#        - 加载日志：pipeline engine ready / pipeline tool registered
#        - /state 里出现 pipeline 字段（dryRunOnly / stages / lastJob）
#        - 环境未就绪时 dry-run → job blocked，节点 [blocked, skipped, skipped]
#        - 起一个假 ComfyUI（/health 200）+ 临时 Unity 工程 → POST /config 后三项全 ok
#        - 三项就绪时 dry-run → job done，节点全 ok，产物 kind = image/mesh/scene
#        - GET /pipeline/jobs 能读到这次 job
#        - /state.pipeline 声明真实执行已接线（realExecution=true；真实跑软件由 verify-step4.sh 覆盖）
#        - client bundle 包含流水线面板 UI（PipelineSection / 运行 dry-run）
#        - 结束时恢复默认配置并清掉临时 Unity 工程
#
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
PATCH="$ROOT/scratch-plugin/cordis.yml"
DEV_HOME="$ROOT/.dsh-dev"
BASE_PATH="/plugins/dsh-scene-skeleton-pipeline"
CONFIG_FILE="$DEV_HOME/scene-skeleton-pipeline/config.json"

PASS=0
FAIL=0
FAILED_NAMES=()
TMP="$(mktemp -d -t dsh-scene-step3.XXXXXX)"
COMFY_PID=""
HOST_PID=""
LOG_FILE=""
JAR=""
BASE=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}

json_get() { python3 -c "import json,sys;d=json.load(open('$1'));print($2)"; }

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [ -n "$COMFY_PID" ] && kill -0 "$COMFY_PID" 2>/dev/null; then
    kill "$COMFY_PID" 2>/dev/null || true
    wait "$COMFY_PID" 2>/dev/null || true
  fi
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
  [ -n "$JAR" ] && rm -f "$JAR"
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 单元层
echo '== 1. pipeline harness =='
if node "$ROOT/scratch-plugin/pipeline-harness.mjs" >"$TMP/harness.log" 2>&1; then
  pass 'pipeline-harness.mjs 全部通过（节点状态机/依赖阻塞/参数校验/job 存取/工具契约）'
else
  fail 'pipeline-harness.mjs 有失败项' '见输出'
  tail -30 "$TMP/harness.log"
fi

# ---------------------------------------------------------------- 宿主启停
boot_host() {
  LOG_FILE="$(mktemp -t dsh-scene-step3-host.XXXXXX)"
  JAR="$(mktemp -t dsh-scene-step3-jar.XXXXXX)"
  DSH_HOME="$DEV_HOME" dsh --profile web --patch "$PATCH" --no-open --port 0 >"$LOG_FILE" 2>&1 &
  HOST_PID=$!
  local token_url=""
  for _ in $(seq 1 160); do
    token_url=$(grep -o 'http://127.0.0.1:[0-9]*/?token=[A-Za-z0-9_-]*' "$LOG_FILE" | head -1)
    [ -n "$token_url" ] && break
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      echo '--- host log ---'; cat "$LOG_FILE"; return 1
    fi
    sleep 0.5
  done
  if [ -z "$token_url" ]; then
    echo '--- host log（没等到 dsh web URL）---'; cat "$LOG_FILE"; return 1
  fi
  BASE="${token_url%%/?token=*}"
  curl -sS -c "$JAR" -L "$token_url" -o /dev/null || return 1
  return 0
}

stop_host() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  HOST_PID=""
  [ -n "$JAR" ] && rm -f "$JAR"
  JAR=""
}

api() { curl -sS -b "$JAR" "$BASE$BASE_PATH$1" "${@:2}"; }

require_host() {
  if ! boot_host; then
    fail "$1" '宿主没有启动起来'
    stop_host
    return 1
  fi
  return 0
}

# 从干净状态开始。
rm -f "$CONFIG_FILE"

# ---------------------------------------------------------------- 2. 加载日志 + /state pipeline 字段
echo '== 2. 宿主加载 + /state pipeline 字段 =='
if require_host '宿主启动'; then
  for pattern in \
    '\[dsh-scene-skeleton-pipeline\] loaded' \
    'pipeline engine ready: comfy -> blender' \
    'pipeline tool registered: run_scene_pipeline' \
    'settings routes registered: .*pipeline/run'; do
    if grep -qE "$pattern" "$LOG_FILE"; then
      pass "日志包含：$(printf '%s' "$pattern" | sed 's/\\//g')"
    else
      fail "日志缺少：$(printf '%s' "$pattern" | sed 's/\\//g')"
    fi
  done

  HTTP=$(curl -sS -b "$JAR" -o "$TMP/state.json" -w '%{http_code}' "$BASE$BASE_PATH/state")
  assert_eq 'GET /state 返回 200' '200' "$HTTP"
  if python3 - "$TMP/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get('pipeline') or {}
assert p.get('dryRunOnly') is False, p
assert p.get('realExecution') is True, p
stages = p.get('stages') or []
assert [s['id'] for s in stages] == ['comfy', 'blender'], stages
assert all(isinstance(s.get('label'), str) and s['label'] for s in stages), stages
assert 'lastJob' in p, sorted(p)
PY
  then
    pass '/state.pipeline：realExecution=true，默认节点顺序 comfy → blender'
  else
    fail '/state.pipeline 结构不合法'
  fi

  # client bundle 是否带流水线面板
  curl -sS -b "$JAR" "$BASE/" -o "$TMP/index.html"
  HREF=$(python3 - "$TMP/index.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding='utf-8').read()
hrefs = re.findall(r'href="(plugins/\?\?[^"]*dsh-scene-skeleton-pipeline/client\.js[^"]*)"', html)
print((hrefs[0] if hrefs else '').replace('&amp;', '&'))
PY
)
  if [ -n "$HREF" ]; then
    curl -sS -b "$JAR" "$BASE/$HREF" -o "$TMP/bundle.js"
    if grep -q 'PipelineSection' "$TMP/bundle.js" && grep -q 'pipelineTitle' "$TMP/bundle.js"; then
      pass 'client bundle 包含流水线面板（PipelineSection）'
    else
      fail 'client bundle 里没有流水线面板代码'
    fi
  else
    fail 'index.html 里找不到 client bundle URL'
  fi
fi
stop_host

# ---------------------------------------------------------------- 3. 环境未就绪时的 dry-run（阻塞路径）
echo '== 3. 环境未就绪 → dry-run 阻塞 =='
if require_host '宿主（阻塞分支）启动'; then
  api '/config' -X POST -H 'content-type: application/json' \
    -d '{"blenderExe":"","comfyUrl":"http://127.0.0.1:6553","unityProjectPath":""}' \
    -o "$TMP/cfg-bad.json" >/dev/null

  HTTP=$(api '/pipeline/run' -X POST -H 'content-type: application/json' \
    -d '{"prompt":"一座带台阶的日式庭院"}' -o "$TMP/run-blocked.json" -w '%{http_code}')
  assert_eq 'POST /pipeline/run 返回 200' '200' "$HTTP"
  assert_eq 'job.dryRun = true' 'True' "$(json_get "$TMP/run-blocked.json" "d['job']['dryRun']")"
  assert_eq 'job.status = blocked' 'blocked' "$(json_get "$TMP/run-blocked.json" "d['job']['status']")"
  assert_eq '工具返回 ok=false' 'False' "$(json_get "$TMP/run-blocked.json" "d['ok']")"
  assert_eq '节点状态 [blocked, skipped]' "['blocked', 'skipped']" \
    "$(json_get "$TMP/run-blocked.json" "[s['status'] for s in d['job']['stages']]")"
  if grep -q '依赖未就绪' "$TMP/run-blocked.json"; then
    pass 'blocked 节点 detail 含“依赖未就绪”'
  else
    fail 'blocked 节点 detail 缺少原因'
  fi
  if grep -q '没有服务在监听' "$TMP/run-blocked.json"; then
    pass 'detail 带上了 ComfyUI 连接失败原因'
  else
    fail 'detail 缺少 ComfyUI 连接失败原因'
  fi

  HTTP=$(api '/pipeline/jobs' -o "$TMP/jobs-blocked.json" -w '%{http_code}')
  assert_eq 'GET /pipeline/jobs 返回 200' '200' "$HTTP"
  assert_eq 'jobs 至少 1 条' 'True' \
    "$(json_get "$TMP/jobs-blocked.json" "len(d['jobs']) >= 1")"
fi
stop_host

# ---------------------------------------------------------------- 4. 三项就绪 → dry-run 全绿
echo '== 4. 三项就绪 → dry-run 完成 =='

# 4a. 假 ComfyUI：/health 与 /queue 都回 200，端口随机。
cat > "$TMP/comfy_stub.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/health', '/queue'):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass

server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$TMP/comfy_stub.py" >"$TMP/comfy.port" 2>&1 &
COMFY_PID=$!
COMFY_PORT=""
for _ in $(seq 1 50); do
  COMFY_PORT=$(head -1 "$TMP/comfy.port" 2>/dev/null | tr -dc '0-9')
  [ -n "$COMFY_PORT" ] && break
  sleep 0.1
done
if [ -n "$COMFY_PORT" ]; then
  pass "假 ComfyUI 已启动：http://127.0.0.1:$COMFY_PORT"
else
  fail '假 ComfyUI 没启动起来'
fi

# 4b. 临时 Unity 工程（ProjectSettings/ProjectVersion.txt）。
UNITY_DIR="$TMP/MyUnityProject"
mkdir -p "$UNITY_DIR/ProjectSettings"
printf 'm_EditorVersion: 2022.3.10f1\n' >"$UNITY_DIR/ProjectSettings/ProjectVersion.txt"

if [ -n "$COMFY_PORT" ] && require_host '宿主（全绿分支）启动'; then
  HTTP=$(api '/config' -X POST -H 'content-type: application/json' \
    -d "{\"blenderExe\":\"\",\"comfyUrl\":\"http://127.0.0.1:$COMFY_PORT\",\"unityProjectPath\":\"$UNITY_DIR\"}" \
    -o "$TMP/cfg-ok.json" -w '%{http_code}')
  assert_eq 'POST /config 返回 200' '200' "$HTTP"
  assert_eq 'blender = ok' 'ok' "$(json_get "$TMP/cfg-ok.json" "d['environment']['blender']['status']")"
  assert_eq "comfy = ok（假 ComfyUI :${COMFY_PORT}）" 'ok' "$(json_get "$TMP/cfg-ok.json" "d['environment']['comfy']['status']")"
  assert_eq 'unity = ok（临时工程）' 'ok' "$(json_get "$TMP/cfg-ok.json" "d['environment']['unity']['status']")"

  HTTP=$(api '/pipeline/run' -X POST -H 'content-type: application/json' \
    -d '{"prompt":"一座带台阶的日式庭院"}' -o "$TMP/run-done.json" -w '%{http_code}')
  assert_eq 'POST /pipeline/run 返回 200' '200' "$HTTP"
  assert_eq 'job.status = done' 'done' "$(json_get "$TMP/run-done.json" "d['job']['status']")"
  assert_eq '工具返回 ok=true' 'True' "$(json_get "$TMP/run-done.json" "d['ok']")"
  assert_eq '节点状态全 ok' 'True' \
    "$(json_get "$TMP/run-done.json" "all(s['status'] == 'ok' for s in d['job']['stages'])")"
  assert_eq '产物 kind = [image, mesh]' "['image', 'mesh']" \
    "$(json_get "$TMP/run-done.json" "[s['artifacts'][0]['kind'] for s in d['job']['stages']]")"
  if grep -q 'dry-run' "$TMP/run-done.json"; then
    pass '节点 detail 说明是 dry-run'
  else
    fail '节点 detail 没说明 dry-run'
  fi

  api '/pipeline/jobs' -o "$TMP/jobs-done.json" >/dev/null
  assert_eq 'GET /pipeline/jobs 里最新 job 是 done' 'done' \
    "$(json_get "$TMP/jobs-done.json" "d['jobs'][0]['status']")"

  # 阶段 4 接线：dryRun:false 已接真实执行器（真实跑软件由 verify-step4.sh 覆盖）
  api '/state' -o "$TMP/state-real.json" >/dev/null
  assert_eq '/state.pipeline.realExecution = true' 'True' \
    "$(json_get "$TMP/state-real.json" "d['pipeline']['realExecution']")"
  assert_eq '/state.pipeline.dryRunOnly = false' 'False' \
    "$(json_get "$TMP/state-real.json" "d['pipeline']['dryRunOnly']")"
  if [ -n "$(json_get "$TMP/state-real.json" "d['pipeline'].get('outputDir','')")" ]; then
    pass '/state.pipeline.outputDir 已提供'
  else
    fail '/state.pipeline.outputDir 为空'
  fi

  # 收尾：恢复默认配置（保留本机 Blender ok / comfy missing / unity missing 的常态）
  api '/config' -X POST -H 'content-type: application/json' \
    -d '{"blenderExe":"","comfyUrl":"http://127.0.0.1:8188","comfyWorkflowPath":"","comfyCheckpoint":"","comfyNegativePrompt":"","unityProjectPath":"","unityExe":"","outputDir":""}' \
    -o /dev/null >/dev/null || fail '恢复默认配置失败'
fi
stop_host

# ---------------------------------------------------------------- 汇总
echo
echo "===== 阶段 3 验收：PASS=$PASS FAIL=$FAIL ====="
if [ "$FAIL" -ne 0 ]; then
  printf '失败项：\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
echo '全部断言通过。'
echo '说明：假 ComfyUI 与临时 Unity 工程只用于让三项检测全绿；dry-run 不会启动任何真实软件。'
exit 0
