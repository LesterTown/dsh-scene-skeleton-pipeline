#!/usr/bin/env bash
#
# 阶段 5 验收脚本（引擎无关核心）：Blender 按 layout.json 产出带层级 / 光照 / 相机 / 可选 prefab 的场景骨架。
#
# 注意：Unity 相关断言已迁至 adapters/unity/verify-unity-adapter.sh。
#
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step5.sh                 # 完整验证（真实跑三个软件，约 3-5 分钟）
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step5.sh --skip-real     # 只验证宿主接线与 dry-run（不跑软件）
#
# 前提：
#   - 本机 ComfyUI 已在 http://127.0.0.1:8188 运行
#   - Blender 可执行（默认 /Applications/Blender.app/Contents/MacOS/Blender）
#
# 覆盖：
#   A. 宿主接线
#      1. 加载日志含 pipeline engine / pipeline tool
#      2. /config 保存后三项环境全 ok、realExecution=true、dryRunOnly=false
#      3. dry-run job done、节点全 ok、artifacts 是八键对象（含 glb/textures）、summary 为 null（未装配）
#      4. client bundle 含「场景装配结果」文案
#   B. 真实执行（核心）
#      5. real-e2e.mjs 经 run_scene_pipeline 工具执行 → exit 0
#      6. last-job.json：done、三节点 ok、artifacts.image/blend/fbx/layout/scene 全存在
#      7. layout.json：可解析、3 个分组、含 Terrain/Props、有 lighting/camera/prefab
#      8. layout.json：分组 / 对象数 / lighting+camera+prefab 段
#      9. 工具返回：summary / artifacts / failedStage
#     10. last-tool-result.json：ok、summary.scenePath / objectCount / groups 有值
#
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
PATCH="$ROOT/scratch-plugin/cordis.yml"
DEV_HOME="$ROOT/.dsh-dev"
BASE_PATH="/plugins/dsh-scene-skeleton-pipeline"
CONFIG_FILE="$DEV_HOME/scene-skeleton-pipeline/config.json"
UNITY_PROJECT="${UNITY_PROJECT:-$DEV_HOME/unity-e2e-project}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/dsh-scene-e2e-step5}"
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
CHECKPOINT="${CHECKPOINT:-DreamShaper_8_pruned.safetensors}"
BLENDER_EXE="${BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
REAL=1
[ "${1:-}" = "--skip-real" ] && REAL=0

PASS=0
FAIL=0
FAILED_NAMES=()
TMP="$(mktemp -d -t dsh-scene-step5.XXXXXX)"
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
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
  [ -n "$JAR" ] && rm -f "$JAR"
  rm -rf "$TMP"
}
trap cleanup EXIT

boot_host() {
  LOG_FILE="$(mktemp -t dsh-scene-step5-host.XXXXXX)"
  JAR="$(mktemp -t dsh-scene-step5-jar.XXXXXX)"
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

api() { curl -sS -b "$JAR" -m 60 "$BASE$BASE_PATH$1" "${@:2}"; }

# ---------------------------------------------------------------- 0. 前置条件
echo '== 0. 前置条件 =='
comfy_code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$COMFY_URL/queue" 2>/dev/null || true)"
[ "$comfy_code" = "200" ] && pass "ComfyUI 可达（$COMFY_URL/queue → 200）" \
  || fail "ComfyUI 不可达（$COMFY_URL/queue → ${comfy_code:-连接失败}）" '请先启动 ComfyUI 再跑本脚本'
[ -x "$BLENDER_EXE" ] && pass 'Blender 可执行存在' \
  || fail 'Blender 可执行不存在' "$BLENDER_EXE"

[ "$FAIL" = "0" ] || { echo; echo '前置条件不满足，终止。'; exit 1; }

# ---------------------------------------------------------------- A. 宿主接线
echo
echo '== A. 宿主接线（隔离 DSH_HOME + --patch）=='
rm -f "$CONFIG_FILE"
if ! boot_host; then
  fail '宿主启动' '见上方日志'
  echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

grep -q 'pipeline engine ready: comfy -> blender' "$LOG_FILE" \
  && pass '加载日志含 pipeline engine ready' || fail '缺少 pipeline engine ready 日志'
grep -q 'pipeline tool registered: run_scene_pipeline' "$LOG_FILE" \
  && pass '加载日志含 pipeline tool registered' || fail '缺少 pipeline tool registered 日志'

# 阶段 6 起默认 blenderSceneMode=scenic（声明式场景）；本脚本锁定 legacy 模式，
# 让「固定体块 + 参考图平面」这条老链路继续有回归保障（scenic 链路由 verify-step6.sh 覆盖）。
config_body=$(python3 -c 'import json,sys;print(json.dumps({"blenderSceneMode":"legacy","comfyUrl":sys.argv[1],"comfyCheckpoint":sys.argv[2],"outputDir":sys.argv[3]}))' \
  "$COMFY_URL" "$CHECKPOINT" "$OUTPUT_DIR")
api /config -X POST -H 'content-type: application/json' -d "$config_body" >"$TMP/config.json" 2>&1

assert_eq '/config 保存成功' 'True' "$(json_get "$TMP/config.json" "d['saved']")"
assert_eq '环境 blender' 'ok' "$(json_get "$TMP/config.json" "d['environment']['blender']['status']")"
assert_eq '环境 comfy' 'ok' "$(json_get "$TMP/config.json" "d['environment']['comfy']['status']")"
assert_eq '流水线 realExecution' 'True' "$(json_get "$TMP/config.json" "d['pipeline']['realExecution']")"
assert_eq '流水线 dryRunOnly' 'False' "$(json_get "$TMP/config.json" "d['pipeline']['dryRunOnly']")"

api /pipeline/run -X POST -H 'content-type: application/json' \
  -d '{"prompt":"a quiet shrine courtyard with stone lanterns","dryRun":true}' >"$TMP/dry.json" 2>&1
assert_eq 'dry-run job done' 'done' "$(json_get "$TMP/dry.json" "d['job']['status']")"
assert_eq 'dry-run 三个节点全 ok' 'True' \
  "$(json_get "$TMP/dry.json" "all(s['status']=='ok' for s in d['job']['stages'])")"
assert_eq 'dry-run artifacts 是八键对象' 'True' \
  "$(json_get "$TMP/dry.json" "sorted(d['job']['artifacts'].keys())==sorted(['image','blend','fbx','glb','layout','scene','prefab','textures'])")"
assert_eq 'dry-run 不产出真实产物' 'True' \
  "$(json_get "$TMP/dry.json" "all(v is None for v in d['job']['artifacts'].values())")"
assert_eq 'dry-run 不装配场景（summary 为 null）' 'None' "$(json_get "$TMP/dry.json" "d['job'].get('summary')")"

curl -sS -b "$JAR" "$BASE/" -o "$TMP/index.html"
HREF=$(python3 - "$TMP/index.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding='utf-8').read()
hrefs = re.findall(r'href="(plugins/\?\?[^"]*dsh-scene-skeleton-pipeline/client\.js[^"]*)"', html)
print((hrefs[0] if hrefs else '').replace('&amp;', '&'))
PY
)
if [ -n "$HREF" ]; then
  curl -sS -b "$JAR" "$BASE/$HREF" -o "$TMP/client-bundle.js"
  grep -q '场景装配结果' "$TMP/client-bundle.js" && pass 'client bundle 含场景装配结果文案' \
    || fail 'client bundle 缺少场景装配结果文案'
else
  fail 'index.html 里找不到 client bundle URL'
fi

stop_host

# ---------------------------------------------------------------- B. 真实执行
if [ "$REAL" = "1" ]; then
  echo
  echo '== B. 真实执行（ComfyUI → Blender(layout) → Unity 装配，约 3-5 分钟）=='
  rm -rf "$OUTPUT_DIR"
  # 与宿主阶段一致锁定 legacy（scenic 链路由 verify-step6.sh 覆盖）
  if node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" '' "$OUTPUT_DIR" \
      '' legacy >"$TMP/real.log" 2>&1; then
    pass 'real-e2e.mjs（经 run_scene_pipeline 工具）exit 0'
  else
    fail 'real-e2e.mjs 失败' "见 $TMP/real.log"
    tail -25 "$TMP/real.log"
  fi

  JOB="$OUTPUT_DIR/last-job.json"
  TOOL="$OUTPUT_DIR/last-tool-result.json"
  if [ -f "$JOB" ]; then
    assert_eq '真实 job done' 'done' "$(json_get "$JOB" "d['status']")"
    assert_eq '真实执行两个节点全 ok' 'True' \
      "$(json_get "$JOB" "all(s['status']=='ok' for s in d['stages'])")"

    for kind in image blend fbx layout; do
      path=$(json_get "$JOB" "d['artifacts'].get('$kind') or ''")
      if [ -n "$path" ] && [ -f "$path" ] && [ -s "$path" ]; then
        pass "artifacts.$kind 存在且非空（$(basename "$path")，$(wc -c <"$path" | tr -d ' ') 字节）"
      else
        fail "artifacts.$kind 缺失或为空" "${path:-（null）}"
      fi
    done
    assert_eq 'prefab 默认未启用（null）' 'None' "$(json_get "$JOB" "d['artifacts']['prefab']")"

    LAYOUT=$(json_get "$JOB" "d['artifacts'].get('layout') or ''")
    if [ -f "$LAYOUT" ]; then
      layout_info=$(python3 - "$LAYOUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
groups = [g.get('name') for g in d.get('groups', [])]
objects = sum(len(g.get('objects', [])) for g in d.get('groups', []))
prefab = (d.get('prefab') or {}).get('enabled')
print('|'.join([
    ','.join(groups), str(objects),
    'lighting' if isinstance(d.get('lighting'), dict) else 'nolight',
    'camera' if isinstance(d.get('camera'), dict) else 'nocamera',
    'prefab' if isinstance(d.get('prefab'), dict) else 'noprefab',
    str(prefab),
]))
PY
)
      groups="${layout_info%%|*}"
      rest="${layout_info#*|}"
      objects="${rest%%|*}"
      light_ok="$(printf '%s' "$layout_info" | cut -d'|' -f3)"
      camera_ok="$(printf '%s' "$layout_info" | cut -d'|' -f4)"
      prefab_ok="$(printf '%s' "$layout_info" | cut -d'|' -f5)"
      prefab_enabled="$(printf '%s' "$layout_info" | cut -d'|' -f6)"
      assert_eq 'layout.json 可解析（3 个分组）' 'Terrain,Props,Reference' "$groups"
      [ "$objects" -ge 2 ] && pass "layout.json 对象数 >= 2（${objects}）" || fail "layout.json 对象数不足（${objects}）"
      assert_eq 'layout 含 lighting / camera / prefab 段' 'lighting|camera|prefab' "$light_ok|$camera_ok|$prefab_ok"
      assert_eq 'layout.prefab.enabled 默认 false' 'False' "$prefab_enabled"
    else
      fail 'layout.json 不存在' "${LAYOUT:-（job 里没有 layout 路径）}"
    fi

  else
    fail 'last-job.json 不存在' '真实执行没有产出 job 记录'
  fi

  if [ -f "$TOOL" ]; then
    assert_eq '工具返回 ok=true' 'True' "$(json_get "$TOOL" "d['ok']")"
    assert_eq '工具返回 summary.scenePath 为 null（未启用适配器）' 'True' \
      "$(json_get "$TOOL" "d['summary'].get('scenePath') is None")"
    tool_count=$(json_get "$TOOL" "d['summary'].get('objectCount') or 0")
    [ "$tool_count" -ge 2 ] && pass "工具返回 summary.objectCount >= 2（${tool_count}）" \
      || fail "工具返回 summary.objectCount 不足（${tool_count}）"
    assert_eq '工具返回 summary.groups 含 Terrain' 'True' \
      "$(json_get "$TOOL" "'Terrain' in (d['summary'].get('groups') or [])")"
    assert_eq '工具返回 artifacts.layout 非空' 'True' \
      "$(json_get "$TOOL" "isinstance(d['artifacts'].get('layout'), str) and bool(d['artifacts']['layout'])")"
    assert_eq '工具返回 failedStage 为空' '' "$(json_get "$TOOL" "d['failedStage']")"
  else
    fail 'last-tool-result.json 不存在' '无法断言 run_scene_pipeline 返回值'
  fi
else
  echo
  echo '== B. 真实执行：已跳过（--skip-real）=='
fi

# ---------------------------------------------------------------- 收尾
rm -f "$CONFIG_FILE"
echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" != "0" ]; then
  printf '失败项:\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
echo '阶段 5 验收全部通过（引擎无关核心链路；Unity 断言见 adapters/unity/verify-unity-adapter.sh）。'
