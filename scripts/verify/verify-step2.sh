#!/usr/bin/env bash
#
# 阶段 2 验收脚本：配置 + pipeline-service + 三项环境检测 + check_environment 工具 + 设置页。
#
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step2.sh
#
# 覆盖（能用断言就不靠肉眼）：
#   1. 单元层：unit-harness.mjs（Config 默认值、三项检测分支、工具契约、全 ok 路径用桩）
#   2. 客户端层：client-harness.mjs（client.js 解析、settings.section 注册、面板可渲染）
#   3. 真实宿主（隔离 DSH_HOME=.dsh-dev + --patch 覆盖层）：
#        - 加载日志：loaded / service registered / tool registered / settings routes registered
#        - 启动检测日志里的 environment JSON：三项 status ∈ {ok,missing,error}
#        - client 半边进入 index.html 的 client bundle 列表，且 bundle 内容可取回
#        - GET  /plugins/dsh-scene-skeleton-pipeline/state   → 200 + 字段齐全
#        - GET  /plugins/dsh-scene-skeleton-pipeline/        → 200 + HTML
#        - POST .../config（错误 Blender 路径 + 错误 ComfyUI 端口 + 非 Unity 目录）
#              → saved=true 且 blender/comfy/unity 全部 missing
#        - 重启宿主 → 配置已持久化（$DSH_HOME/scene-skeleton-pipeline/config.json）
#        - POST .../config 恢复默认 → blender ok（本机装了 Blender）
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

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}

HOST_PID=""
LOG_FILE=""
JAR=""
BASE=""

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
  [ -n "$JAR" ] && rm -f "$JAR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 单元层
echo '== 1. unit harness =='
if node "$ROOT/scratch-plugin/unit-harness.mjs" >"$ROOT/scratch-plugin/.unit-harness.log" 2>&1; then
  pass 'unit-harness.mjs 全部通过（Config/三项检测/工具/全 ok 路径）'
else
  fail 'unit-harness.mjs 有失败项' "见 scratch-plugin/.unit-harness.log"
  tail -30 "$ROOT/scratch-plugin/.unit-harness.log"
fi

# ---------------------------------------------------------------- 2. 客户端层
echo '== 2. client harness =='
if node "$ROOT/scratch-plugin/client-harness.mjs" >"$ROOT/scratch-plugin/.client-harness.log" 2>&1; then
  pass 'client-harness.mjs 全部通过（settings.section 注册、面板可渲染）'
else
  fail 'client-harness.mjs 有失败项' "见 scratch-plugin/.client-harness.log"
  tail -30 "$ROOT/scratch-plugin/.client-harness.log"
fi

# ---------------------------------------------------------------- 宿主启停
boot_host() {
  LOG_FILE="$(mktemp -t dsh-scene-skeleton.XXXXXX)"
  JAR="$(mktemp -t dsh-scene-jar.XXXXXX)"
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
  # token URL 会 303 到 ./ 并 Set-Cookie；带 jar 拿到后续请求的凭据。
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
status_of() { python3 -c "import json,sys;d=json.load(open('$1'));print(d['environment']['$2']['status'])"; }
config_field() { python3 -c "import json,sys;d=json.load(open('$1'));print(d['config'].get('$2',''))"; }

require_host() {
  if ! boot_host; then
    fail "$1" '宿主没有启动起来'
    stop_host
    return 1
  fi
  return 0
}

# 从干净状态开始：删掉开发者自己的持久化配置，确保断言可重复。
rm -f "$CONFIG_FILE"

# ---------------------------------------------------------------- 3. 首次启动与加载日志
echo '== 3. 宿主加载 + 启动检测 =='
if require_host '宿主启动'; then
  for pattern in \
    '\[dsh-scene-skeleton-pipeline\] loaded' \
    'service registered: scenePipeline' \
    'tool registered: check_environment' \
    'settings routes registered'; do
    # shellcheck disable=SC2086
    if grep -qE "$(printf '%s' "$pattern")" "$LOG_FILE"; then
      pass "日志包含：$(printf '%s' "$pattern" | sed 's/\\//g')"
    else
      fail "日志缺少：$(printf '%s' "$pattern" | sed 's/\\//g')"
    fi
  done

  ENV_LINE=$(grep -o '\[dsh-scene-skeleton-pipeline\] environment {.*}' "$LOG_FILE" | head -1 | sed 's/^\[dsh-scene-skeleton-pipeline\] environment //')
  if [ -n "$ENV_LINE" ]; then
    printf '%s' "$ENV_LINE" >/tmp/dsh-env-line.json
    if python3 - "$ENV_LINE" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
allowed = {'ok', 'missing', 'error'}
assert set(data) == {'blender', 'comfy', 'unity'}, data.keys()
for name, item in data.items():
    assert item['status'] in allowed, (name, item)
    assert isinstance(item.get('detail'), str) and item['detail'] != '', (name, 'empty detail')
print('ok')
PY
    then
      pass '启动检测日志：three-status JSON 合法（status ∈ ok/missing/error，detail 非空）'
    else
      fail '启动检测日志：JSON 结构不合法'
    fi
  else
    fail '启动检测日志：找不到 environment 行'
  fi

  # client 半边是否进入 web 端的 bundle 列表
  curl -sS -b "$JAR" "$BASE/" -o /tmp/dsh-index.html
  if grep -q 'dsh-scene-skeleton-pipeline/client.js' /tmp/dsh-index.html; then
    pass 'index.html 的 client bundle 列表包含 dsh-scene-skeleton-pipeline'
    BUNDLE_URL=$(python3 - <<'PY'
import re
html = open('/tmp/dsh-index.html', encoding='utf-8').read()
m = re.search(r'"url":"(plugins/\?\?dsh-scene-skeleton-pipeline/client\.js[^"]*)"', html)
print(m.group(1) if m else '')
PY
)
    if [ -n "$BUNDLE_URL" ]; then
      curl -sS -b "$JAR" "$BASE/$BUNDLE_URL" -o /tmp/dsh-bundle.js
      if grep -q '__ModuleLoader__' /tmp/dsh-bundle.js && grep -q "settings.section" /tmp/dsh-bundle.js; then
        pass 'client bundle 可取回，且包含 __ModuleLoader__ / settings.section'
      else
        fail 'client bundle 内容不对'
      fi
    else
      fail 'index.html 里找不到 client bundle URL'
    fi
  else
    fail 'index.html 的 client bundle 列表里没有 dsh-scene-skeleton-pipeline'
  fi

  # 宿主路由
  HTTP=$(curl -sS -b "$JAR" -o /tmp/dsh-state.json -w '%{http_code}' "$BASE$BASE_PATH/state")
  assert_eq 'GET /state 返回 200' '200' "$HTTP"
  if python3 - <<'PY'
import json
d = json.load(open('/tmp/dsh-state.json'))
allowed = {'ok', 'missing', 'error'}
assert set(d) >= {'config', 'environment', 'checkedAt', 'configEditable', 'configFile'}, sorted(d)
for key in ('blender', 'comfy', 'unity'):
    assert d['environment'][key]['status'] in allowed, (key, d['environment'][key])
for key in ('blenderExe', 'comfyUrl', 'unityProjectPath'):
    assert isinstance(d['config'].get(key), str), key
PY
  then
    pass 'GET /state 字段齐全（config/environment/checkedAt/configEditable/configFile）'
  else
    fail 'GET /state 字段不齐全'
  fi

  HTTP=$(curl -sS -b "$JAR" -o /tmp/dsh-page.html -w '%{http_code}' "$BASE$BASE_PATH/")
  assert_eq 'GET /（HTML 自检页）返回 200' '200' "$HTTP"
  if grep -q 'dsh-scene-skeleton-pipeline 环境检测' /tmp/dsh-page.html; then
    pass 'HTML 自检页包含标题'
  else
    fail 'HTML 自检页内容不对'
  fi
fi
stop_host

# ---------------------------------------------------------------- 4. 错误配置分支（通过设置页 API 保存）
echo '== 4. 错误配置 → missing，并验证持久化 =='
if require_host '宿主（错误配置分支）启动'; then
  HTTP=$(api '/config' -X POST -H 'content-type: application/json' \
    -d '{"blenderExe":"/nonexistent/blender","comfyUrl":"http://127.0.0.1:6553","unityProjectPath":"/tmp/not-a-unity-project"}' \
    -o /tmp/dsh-cfg.json -w '%{http_code}')
  assert_eq 'POST /config 返回 200' '200' "$HTTP"

  SAVED=$(python3 -c "import json;print(json.load(open('/tmp/dsh-cfg.json')).get('saved'))")
  assert_eq 'POST /config saved=true' 'True' "$SAVED"

  assert_eq '错误 blenderExe → blender=missing' 'missing' "$(status_of /tmp/dsh-cfg.json blender)"
  assert_eq '错误 ComfyUI 端口 → comfy=missing' 'missing' "$(status_of /tmp/dsh-cfg.json comfy)"
  assert_eq '非 Unity 目录 → unity=missing' 'missing' "$(status_of /tmp/dsh-cfg.json unity)"

  if grep -q '请确认 ComfyUI 已启动并监听' /tmp/dsh-cfg.json; then
    pass 'comfy detail 含“请确认 ComfyUI 已启动并监听 … 端口”'
  else
    fail 'comfy detail 缺少端口提示'
  fi
  if grep -q '请在设置中指定 Unity 项目根目录' /tmp/dsh-cfg.json; then
    pass 'unity detail 含“请在设置中指定 Unity 项目根目录”'
  else
    fail 'unity detail 缺少配置提示'
  fi

  HTTP=$(api '/check' -X POST -o /tmp/dsh-check.json -w '%{http_code}')
  assert_eq 'POST /check 返回 200' '200' "$HTTP"
  assert_eq '重新检测后 blender 仍 missing' 'missing' "$(status_of /tmp/dsh-check.json blender)"

  if [ -f "$CONFIG_FILE" ]; then
    pass "配置文件已写入：$CONFIG_FILE"
  else
    fail "配置文件未写入：$CONFIG_FILE"
  fi
fi
stop_host

if require_host '宿主（重启后读持久化配置）启动'; then
  curl -sS -b "$JAR" "$BASE$BASE_PATH/state" -o /tmp/dsh-state2.json
  assert_eq '重启后 blenderExe 已持久化' '/nonexistent/blender' "$(config_field /tmp/dsh-state2.json blenderExe)"
  assert_eq '重启后 comfyUrl 已持久化' 'http://127.0.0.1:6553' "$(config_field /tmp/dsh-state2.json comfyUrl)"
  assert_eq '重启后 unityProjectPath 已持久化' '/tmp/not-a-unity-project' "$(config_field /tmp/dsh-state2.json unityProjectPath)"
  assert_eq '重启后 blender=missing（持久化的坏路径生效）' 'missing' "$(status_of /tmp/dsh-state2.json blender)"
fi
stop_host

# ---------------------------------------------------------------- 5. 恢复默认 → 本机 Blender ok
echo '== 5. 恢复默认配置 =='
if require_host '宿主（恢复默认）启动'; then
  api '/config' -X POST -H 'content-type: application/json' \
    -d '{"blenderExe":"","comfyUrl":"http://127.0.0.1:8188","unityProjectPath":""}' \
    -o /tmp/dsh-reset.json >/dev/null

  assert_eq '默认配置下 blender=ok（本机 /Applications/Blender.app 存在）' 'ok' "$(status_of /tmp/dsh-reset.json blender)"
  COMFY_DEFAULT=$(status_of /tmp/dsh-reset.json comfy)
  if [ "$COMFY_DEFAULT" = 'missing' ] || [ "$COMFY_DEFAULT" = 'ok' ]; then
    pass "默认配置下 comfy 有明确结论（本机 8188 ${COMFY_DEFAULT}）"
  else
    fail '默认配置下 comfy 状态异常' "$COMFY_DEFAULT"
  fi
  assert_eq '默认配置下 unity=missing（未配置项目）' 'missing' "$(status_of /tmp/dsh-reset.json unity)"

  BLENDER_PATH=$(python3 -c "import json;print(json.load(open('/tmp/dsh-reset.json'))['environment']['blender'].get('path',''))")
  assert_eq 'blender path 指向真实可执行文件' '/Applications/Blender.app/Contents/MacOS/Blender' "$BLENDER_PATH"
fi
stop_host

# ---------------------------------------------------------------- 汇总
echo
echo "===== 阶段 2 验收：PASS=$PASS FAIL=$FAIL ====="
if [ "$FAIL" -ne 0 ]; then
  printf '失败项：\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  echo '注意：本脚本会保留 .dsh-dev/scene-skeleton-pipeline/config.json 的默认值；'
  echo '      “三项全 ok”的路径由 unit-harness.mjs 用临时 HTTP 桩 + 临时可执行文件 + 临时 Unity 工程验证。'
  echo '      默认配置下 comfy 的状态取决于本机 8188 是否在跑 ComfyUI，脚本只断言“有明确结论”。'
  exit 1
fi
echo '全部断言通过。'
echo '三项全 ok 的路径由 unit-harness.mjs 用临时桩验证（不依赖本机是否装了软件）。'
exit 0
