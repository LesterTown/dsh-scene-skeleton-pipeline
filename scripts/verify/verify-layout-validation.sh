#!/usr/bin/env bash
# 布局物理校验验收（块 B）：五类规则 + 结构化错误 + plan 工具重试闭环 + run_scenic 执行前校验
#
# 用法：
#   bash scripts/verify/verify-layout-validation.sh            # 全量（含真实模型 + 宿主接线）
#   bash scripts/verify/verify-layout-validation.sh --skip-llm # 跳过真实模型调用（离线快速跑）
#
# 覆盖：
#   [1] Python 校验器：合法通过；碰撞 / 悬浮 / 穿透 / 边界 / 支撑 各被拒且消息含对象 id 与数值
#   [2] JS 校验器与 Python 规则一致（同 5 个非法 plan 得到同样的 rule 集合）
#   [3] run_scenic.py 执行前校验：非法 plan → exit≠0、日志含「布局校验失败」、不产出 layout.json
#   [4] plan_scene_layout 重试闭环：首次非法→第二次合法（attempts=2）；三次都非法（attempts=3、errors 非空）
#   [5] 真实模型：plan_scene_layout 要么一次通过，要么重试后通过/3 次失败返回结构化错误
#   [6] 配置接线：宿主 /state 的 layoutValidation 默认值 + POST /config 修改后生效
#   [7] 回归：verify-layout-types.sh、verify-layout-llm.sh 仍通过
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
BLENDER="${DSH_BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
PATCH="$ROOT/scratch-plugin/cordis.yml"
DEV_HOME="$ROOT/.dsh-dev"
WORK="$(mktemp -d /tmp/dsh-layout-validation-XXXXXX)"
SKIP_LLM=0
[ "${1:-}" = "--skip-llm" ] && SKIP_LLM=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }
check() { if eval "$2" > /dev/null 2>&1; then pass "$1"; else fail "$1" "${3:-}"; fi; }

cleanup() {
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  # 还原开发配置（脚本会临时移走它，确保 /state 断言看到的是默认值）
  if [ -f "$WORK/config.bak" ]; then
    cp "$WORK/config.bak" "$CONFIG_FILE" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

write_plans() {
  python3 - "$WORK" <<'PY'
import json, sys
from pathlib import Path

work = Path(sys.argv[1])

def plan(objects, bounds=None, scene_name='ValidationCase'):
    data = {'sceneName': scene_name, 'objects': objects}
    if bounds:
        data['bounds'] = bounds
    return data

valid = plan([
    {'id': 'fountain_01', 'type': 'fountain', 'position': [0, 0, 0], 'size': [4, 0.8, 4]},
    {'id': 'column_01', 'type': 'column', 'position': [-8, 0, -6], 'size': [0.8, 3.5, 0.8]},
    {'id': 'tree_01', 'type': 'tree', 'position': [8, 0, 6], 'size': [3, 5, 3]},
], bounds={'width': 24, 'depth': 20})

collision = plan([
    {'id': 'column_01', 'type': 'column', 'position': [0, 0, 0], 'size': [1, 3, 1]},
    {'id': 'column_02', 'type': 'column', 'position': [0.2, 0, 0.2], 'size': [1, 3, 1]},
])
float_case = plan([
    {'id': 'column_01', 'type': 'column', 'position': [0, 1, 0], 'size': [1, 3, 1]},
])
ground_case = plan([
    {'id': 'column_01', 'type': 'column', 'position': [0, -0.3, 0], 'size': [1, 3, 1]},
])
bounds_case = plan([
    {'id': 'column_01', 'type': 'column', 'position': [60, 0, 0], 'size': [1, 3, 1]},
])
support_case = plan([
    {'id': 'planter_01', 'type': 'planter', 'position': [0, 1, 0], 'size': [0.6, 0.6, 0.6]},
])
support_ok = plan([
    {'id': 'table_01', 'type': 'table', 'position': [0, 0, 0], 'size': [1.6, 1.0, 0.9]},
    {'id': 'planter_01', 'type': 'planter', 'position': [0, 1.0, 0], 'size': [0.6, 0.6, 0.6]},
])
scene_bounds_case = plan([
    {'id': 'column_01', 'type': 'column', 'position': [8, 0, 0], 'size': [1, 3, 1]},
], bounds={'width': 24, 'depth': 20})

for name, data in [
    ('valid', valid), ('collision', collision), ('float', float_case), ('ground', ground_case),
    ('bounds', bounds_case), ('support', support_case), ('support_ok', support_ok),
    ('scene_bounds', scene_bounds_case),
]:
    (work / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')

(work / 'options_tight.json').write_text(json.dumps({'sceneBounds': [-5, 5]}, ensure_ascii=False), encoding='utf8')
(work / 'packed.json').write_text(json.dumps({'valid': valid, 'collision': collision, 'float': float_case,
                                               'ground': ground_case, 'bounds': bounds_case,
                                               'support': support_case, 'support_ok': support_ok},
                                              ensure_ascii=False), encoding='utf8')
PY
}

write_plans

# ---------------------------------------------------------------- 1. Python 校验器
section '1. Python 校验器（五类规则）'
cd "$PLUGIN_DIR/lib/scripts"
if python3 layout_validate.py "$WORK/valid.json" > "$WORK/valid.out" 2>&1; then
  pass '合法 plan 通过'
else
  fail '合法 plan 应通过' "$(cat "$WORK/valid.out")"
fi
check '合法 plan 输出 ok=true' "grep -q '\"ok\": true' '$WORK/valid.out'"

expect_reject() {
  local name="$1" rule="$2" needle="$3"
  if python3 layout_validate.py "$WORK/$name.json" > "$WORK/${name}.out" 2> "$WORK/${name}.err"; then
    fail "${name} 应被拒绝" 'exit=0'
    return
  fi
  if grep -q "$needle" "$WORK/${name}.err"; then
    pass "${name} 被拒（${rule}）且消息含「${needle}」"
  else
    fail "${name} 错误消息缺少「${needle}」" "$(cat "$WORK/${name}.err")"
  fi
}

expect_reject collision collision '碰撞'
expect_reject float float '悬浮'
expect_reject ground ground '沉入地面'
expect_reject bounds bounds '超出场景边界'
expect_reject support support '无有效支撑面'
check '碰撞错误含两个对象 id' "grep -q 'column_01 与 column_02' '$WORK/collision.err'"
check '碰撞错误含重叠体积' "grep -Eq '重叠体积约 [0-9.]+m' '$WORK/collision.err'"

if python3 layout_validate.py "$WORK/support_ok.json" > "$WORK/support_ok.out" 2>&1; then
  pass 'on_surface 有支撑时通过'
else
  fail 'on_surface 有支撑时应通过' "$(cat "$WORK/support_ok.out")"
fi

# 结构化输出（Python 函数层）
if python3 - "$WORK" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, '.')
from layout_validate import validate_plan

work = Path(sys.argv[1])
result = validate_plan(json.loads((work / 'collision.json').read_text(encoding='utf8')))
ok = (
    isinstance(result, dict)
    and result.get('ok') is False
    and isinstance(result.get('errors'), list)
    and result['errors']
    and all(isinstance(item, dict) and item.get('rule') and item.get('message') for item in result['errors'])
    and result['errors'][0]['rule'] == 'collision'
    and set(result['errors'][0].get('objects', [])) == {'column_01', 'column_02'}
)
sys.exit(0 if ok else 1)
PY
then
  pass 'validate_plan 返回结构化 {ok, errors:[{rule,message,objects}]}'
else
  fail 'validate_plan 结构化输出不符合预期'
fi

# ---------------------------------------------------------------- 2. JS 校验器一致性
section '2. JS 校验器与 Python 规则一致'
if (cd "$PLUGIN_DIR" && node --input-type=module -e "
import { readFileSync } from 'node:fs'
import { validatePlanDetailed } from './lib/layout.js'
const packed = JSON.parse(readFileSync('$WORK/packed.json', 'utf8'))
const expected = { collision: 'collision', float: 'float', ground: 'ground', bounds: 'bounds', support: 'support' }
let bad = 0
for (const [name, rule] of Object.entries(expected)) {
  const result = validatePlanDetailed(packed[name])
  if (result.ok || !result.errors.some(error => error.rule === rule)) {
    console.log('mismatch', name, JSON.stringify(result.errors.map(error => error.rule)))
    bad += 1
  }
}
const valid = validatePlanDetailed(packed.valid)
if (!valid.ok) { console.log('valid-failed', JSON.stringify(valid.errors)); bad += 1 }
const supportOk = validatePlanDetailed(packed.support_ok)
if (!supportOk.ok) { console.log('support-ok-failed', JSON.stringify(supportOk.errors)); bad += 1 }
process.exit(bad === 0 ? 0 : 1)
") ; then
  pass 'JS validatePlanDetailed 与 Python 规则一致（5 类违规 + 2 类合法）'
else
  fail 'JS 校验器结果与 Python 不一致'
fi

# ---------------------------------------------------------------- 3. run_scenic 执行前校验
section '3. run_scenic.py 执行前校验'
mkdir -p "$WORK/blender-bad"
if "$BLENDER" --background --factory-startup --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/blender-bad/scene.blend" "$WORK/blender-bad/scene.glb" "$WORK/blender-bad/scene.fbx" "$WORK/blender-bad/layout.json" \
  "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/collision.json\"}" > "$WORK/blender-bad/log.txt" 2>&1; then
  fail '非法 plan 时 Blender 应失败' 'exit=0'
else
  pass '非法 plan 时 Blender 退出码非 0'
fi
check '日志含「布局校验失败」' "grep -q '布局校验失败' '$WORK/blender-bad/log.txt'"
check '非法 plan 不产出 layout.json' "[ ! -f '$WORK/blender-bad/layout.json' ]"

mkdir -p "$WORK/blender-tight"
if "$BLENDER" --background --factory-startup --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/blender-tight/scene.blend" "$WORK/blender-tight/scene.glb" "$WORK/blender-tight/scene.fbx" "$WORK/blender-tight/layout.json" \
  "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/scene_bounds.json\",\"layoutValidation\":{\"sceneBounds\":[-5,5]}}" > "$WORK/blender-tight/log.txt" 2>&1; then
  fail 'layoutValidation.sceneBounds 应收紧边界' 'exit=0'
else
  pass 'layoutValidation.sceneBounds 生效（x=8 超出 ±5 被拒）'
fi
check '收紧边界错误含「超出场景边界」' "grep -q '超出场景边界' '$WORK/blender-tight/log.txt'"

mkdir -p "$WORK/blender-good"
if "$BLENDER" --background --factory-startup --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/blender-good/scene.blend" "$WORK/blender-good/scene.glb" "$WORK/blender-good/scene.fbx" "$WORK/blender-good/layout.json" \
  "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/valid.json\"}" > "$WORK/blender-good/log.txt" 2>&1; then
  pass '合法 plan 能正常装配（Blender 退出码 0）'
else
  fail '合法 plan 装配失败' "$(tail -3 "$WORK/blender-good/log.txt")"
fi
check '合法 plan 产出 layout.json' "[ -s '$WORK/blender-good/layout.json' ]"

# ---------------------------------------------------------------- 4. plan 工具重试闭环
section '4. plan_scene_layout 重试闭环'
if (cd "$ROOT" && node --input-type=module -e "
import { readFileSync } from 'node:fs'
import { createPlanSceneLayoutTool } from './dsh-scene-skeleton-pipeline/lib/plan-tool.js'
const packed = JSON.parse(readFileSync('$WORK/packed.json', 'utf8'))
const config = { scenicWidth: 24, scenicDepth: 20, layoutValidation: undefined, sceneSource: 'template', layoutObjects: '' }
const service = { getConfig: () => config }
function makeCtx(sequence) {
  let call = 0
  return {
    get(name) {
      if (name === 'llm') {
        return {
          stream() {
            const text = sequence[Math.min(call, sequence.length - 1)]
            call += 1
            return (async function* generate() { yield { type: 'text-delta', index: 0, text } })()
          },
        }
      }
      if (name === 'agentDefaultModel') return { currentSelection: () => ({ provider: 'p', model: 'm' }) }
      return null
    },
    effect: () => () => {},
  }
}
const retryCtx = makeCtx([JSON.stringify(packed.collision), JSON.stringify(packed.valid)])
const retry = await createPlanSceneLayoutTool({ ctx: retryCtx, service }).execute({ sceneDescription: '重试' })
console.log('retry', retry.ok, retry.attempts)
if (!(retry.ok === true && retry.attempts === 2)) process.exit(1)
const failCtx = makeCtx([JSON.stringify(packed.collision)])
const failed = await createPlanSceneLayoutTool({ ctx: failCtx, service }).execute({ sceneDescription: '一直非法' })
console.log('fail', failed.ok, failed.attempts, JSON.stringify(failed.errors).slice(0, 60))
if (!(failed.ok === false && failed.attempts === 3 && Array.isArray(failed.errors) && failed.errors.length > 0)) process.exit(1)
") ; then
  pass '首次非法 → 第二次合法（attempts=2）；三次全非法 → attempts=3 且 errors 非空'
else
  fail 'plan 工具重试闭环不符合预期'
fi

# ---------------------------------------------------------------- 5. 真实模型
section '5. 真实模型（plan_scene_layout）'
# 真实模型需要 DSH 账号（~/.dsh 里已登录）或 DEEPSEEK_API_KEY：
#   本仓库开发时账号登录在默认 DSH_HOME 中，因此这一节默认用 $HOME/.dsh，
#   需要跑在隔离环境时用 DSH_MODEL_HOME 覆盖。
MODEL_HOME="${DSH_MODEL_HOME:-$HOME/.dsh}"
if [ "$SKIP_LLM" = "1" ]; then
  printf 'SKIP  跳过真实模型调用（--skip-llm）\n'
else
  DSH_TOOLS_MODE=ptc DSH_HOME="$MODEL_HOME" dsh --profile headless \
    --patch "$ROOT/scratch-plugin/cordis-headless-auth.yml" \
    --patch "$ROOT/scratch-plugin/cordis-ptc.yml" \
    --json "请调用 plan_scene_layout 工具，场景描述：一座小型庭院，中央一个喷泉，四角各一根石柱，北侧一段矮墙，东侧两棵树。savePath 传 $WORK/model-plan.json 。完成后简短说明结果。" \
    > "$WORK/model.jsonl" 2> "$WORK/model.err" || true

  if grep -q 'ACCOUNT_SIGN_IN_REQUIRED\|MISSING_CREDENTIAL\|no API key' "$WORK/model.err"; then
    printf 'SKIP  真实模型不可用（账号未登录 / 没有 API Key）：%s\n' "$(head -1 "$WORK/model.err")"
  else
    if [ -s "$WORK/model.jsonl" ]; then
      pass '真实模型调用返回事件流'
    else
      fail '真实模型调用没有输出' "$(tail -3 "$WORK/model.err")"
    fi
    if grep -q '"tool":"plan_scene_layout"' "$WORK/model.jsonl"; then
      pass '模型调用了 plan_scene_layout'
    else
      fail '模型没有调用 plan_scene_layout' "$(grep -o '"tool":"[a-z_]*"' "$WORK/model.jsonl" | sort -u | tr '\n' ' ')"
    fi
    if grep -q '布局规划成功' "$WORK/model.jsonl"; then
      pass '模型规划通过校验（工具返回成功）'
    elif grep -q '布局规划失败\|尝试 3 次' "$WORK/model.jsonl"; then
      pass '模型 3 次尝试后返回结构化失败（ok=false + errors）'
    else
      fail '模型输出既没有成功也没有结构化失败' "$(grep -o '布局规划[^"]*' "$WORK/model.jsonl" | head -1)"
    fi
    if [ -s "$WORK/model-plan.json" ]; then
      if (cd "$PLUGIN_DIR/lib/scripts" && python3 layout_validate.py "$WORK/model-plan.json" > /dev/null 2>&1); then
        pass '模型写盘的 plan 通过校验器复核'
      else
        fail '模型写盘的 plan 未通过校验器'
      fi
    else
      printf 'SKIP  模型没有写 plan 文件（可能直接失败）\n'
    fi
  fi
fi

# ---------------------------------------------------------------- 6. 配置接线
section '6. layoutValidation 配置接线（宿主）'
CONFIG_FILE="$DEV_HOME/scene-skeleton-pipeline/config.json"
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$WORK/config.bak"
  rm -f "$CONFIG_FILE"
fi
HOST_LOG="$WORK/host.log"
(
  cd "$ROOT"
  DSH_HOME="$DEV_HOME" dsh --profile web --patch "$PATCH" --no-open --port 0 > "$HOST_LOG" 2>&1 &
  echo $! > "$WORK/host.pid"
)
HOST_PID=$(cat "$WORK/host.pid")
TOKEN_URL=''
for _ in $(seq 1 120); do
  TOKEN_URL=$(grep -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' "$HOST_LOG" | head -1 || true)
  [ -n "$TOKEN_URL" ] && break
  sleep 0.5
done
if [ -z "$TOKEN_URL" ]; then
  fail '宿主没有启动（没抓到 token URL）' "$(tail -3 "$HOST_LOG")"
else
  BASE="${TOKEN_URL%%/?token=*}"
  JAR="$WORK/cookies.txt"
  curl -sS -c "$JAR" -L "$TOKEN_URL" -o /dev/null 2>/dev/null || true
  api() { curl -sS -b "$JAR" -H 'content-type: application/json' "$@"; }

  STATE=$(api "$BASE/plugins/dsh-scene-skeleton-pipeline/state")
  if python3 - "$STATE" <<'PY'
import json, sys
state = json.loads(sys.argv[1])
validation = state.get('config', {}).get('layoutValidation')
ok = (
    isinstance(validation, dict)
    and abs(float(validation.get('maxCollisionOverlap', -1)) - 0.1) < 1e-9
    and abs(float(validation.get('maxFloatHeight', -1)) - 0.3) < 1e-9
    and abs(float(validation.get('groundTolerance', -1)) - 0.05) < 1e-9
    and validation.get('sceneBounds') == [-50, 50]
)
sys.exit(0 if ok else 1)
PY
  then
    pass '/state 的 layoutValidation 默认值为 0.1 / 0.3 / 0.05 / [-50,50]'
  else
    fail '/state 的 layoutValidation 默认值不对' "$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('config',{}).get('layoutValidation'))" "$STATE")"
  fi

  SAVED=$(api -X POST "$BASE/plugins/dsh-scene-skeleton-pipeline/config" \
    -d '{"layoutValidation":{"maxCollisionOverlap":0.25,"maxFloatHeight":0.6,"groundTolerance":0.08,"sceneBounds":[-20,20]}}')
  if python3 - "$SAVED" <<'PY'
import json, sys
saved = json.loads(sys.argv[1])
validation = saved.get('config', {}).get('layoutValidation') or {}
ok = (
    saved.get('saved') is True
    and abs(float(validation.get('maxCollisionOverlap', -1)) - 0.25) < 1e-9
    and abs(float(validation.get('maxFloatHeight', -1)) - 0.6) < 1e-9
    and abs(float(validation.get('groundTolerance', -1)) - 0.08) < 1e-9
    and validation.get('sceneBounds') == [-20, 20]
)
sys.exit(0 if ok else 1)
PY
  then
    pass 'POST /config 修改 layoutValidation 生效并持久化'
  else
    fail 'POST /config 修改 layoutValidation 失败' "$SAVED"
  fi

fi
kill "$HOST_PID" 2>/dev/null || true
HOST_PID=''
# 宿主写入的配置文件可能是测试值；还原脚本开始前的状态（cleanup 里也会兜底）
if [ -f "$WORK/config.bak" ]; then
  cp "$WORK/config.bak" "$CONFIG_FILE" 2>/dev/null || true
else
  rm -f "$CONFIG_FILE"
fi

# ---------------------------------------------------------------- 7. 回归
section '7. 回归'
if (cd "$PLUGIN_DIR" && bash scripts/verify/verify-layout-types.sh --skip-llm > "$WORK/types.log" 2>&1); then
  pass 'verify-layout-types.sh --skip-llm 仍通过'
else
  fail 'verify-layout-types.sh 回归失败' "$(tail -3 "$WORK/types.log")"
fi
if (cd "$PLUGIN_DIR" && bash scripts/verify/verify-layout-llm.sh > "$WORK/llm.log" 2>&1); then
  pass 'verify-layout-llm.sh 仍通过'
else
  fail 'verify-layout-llm.sh 回归失败' "$(tail -3 "$WORK/llm.log")"
fi

# ---------------------------------------------------------------- 汇总
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo '布局物理校验验收通过。'
  exit 0
fi
echo '布局物理校验验收失败。'
exit 1
