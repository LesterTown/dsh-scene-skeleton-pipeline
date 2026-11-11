#!/usr/bin/env bash
# 语义资产库（asset-library.json）验收：类型白名单 / 尺寸范围 / 几何可区分 / 非法 type 拒绝 / 真实模型规划
#
# 用法：
#   bash scripts/verify/verify-layout-types.sh              # 全量（含真实模型 + Blender + 回归 verify-layout-llm）
#   bash scripts/verify/verify-layout-types.sh --skip-llm   # 跳过真实模型调用（离线快速跑）
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
LIBRARY="$PLUGIN_DIR/lib/asset-library.json"
BLENDER="${DSH_BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
WORK="$(mktemp -d /tmp/dsh-types-verify-XXXXXX)"
SKIP_LLM=0
[ "${1:-}" = "--skip-llm" ] && SKIP_LLM=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 资产库静态检查
section '1. asset-library.json 结构'
if python3 - "$LIBRARY" <<'PY'
import json, sys
library = json.load(open(sys.argv[1], encoding='utf8'))
assets = library['assets']
problems = []
def check(label, ok, detail=''):
    print(('PASS  ' if ok else 'FAIL  ') + label + (('  ' + detail) if detail and not ok else ''))
    if not ok:
        problems.append(label)

check('至少 15 个 type', len(assets) >= 15, f'当前 {len(assets)}')
check('type 唯一', len({a['type'] for a in assets}) == len(assets))
categories = set(library['categories'])
for entry in assets:
    t = entry.get('type')
    check(f'{t} 有 category', entry.get('category') in categories, str(entry.get('category')))
    check(f'{t} 有 placement', isinstance(entry.get('placement'), list) and len(entry['placement']) > 0)
    check(f'{t} 有 geometry', isinstance(entry.get('geometry'), list) and len(entry['geometry']) > 0)
    rng = entry.get('sizeRange') or {}
    check(f'{t} 有 sizeRange', isinstance(rng.get('height'), list) and isinstance(rng.get('footprint'), list))
    default = entry.get('defaultSize') or []
    check(f'{t} 有 defaultSize', isinstance(default, list) and len(default) == 3)
    if isinstance(rng.get('height'), list) and len(default) == 3:
        ok = rng['height'][0] <= default[1] <= rng['height'][1]
        check(f'{t} 默认尺寸在范围内', ok, f"{default[1]} vs {rng['height']}")
    for part in entry.get('geometry') or []:
        check(f"{t} 图元 shape 合法", part.get('shape') in ('box', 'cylinder', 'cone', 'sphere', 'blob', 'steps'),
              str(part.get('shape')))
        check(f"{t} 图元材质存在", part.get('material') in library['materials'], str(part.get('material')))
sys.exit(1 if problems else 0)
PY
then
  pass '资产库静态检查通过'
else
  fail '资产库静态检查失败'
fi

# ---------------------------------------------------------------- 2. 三处白名单一致
section '2. JS / Python / schema 白名单一致'
JS_TYPES=$(cd "$PLUGIN_DIR" && node --input-type=module -e "import('./lib/layout.js').then(m => console.log(m.PLAN_TYPES.join(',')))")
LIB_TYPES=$(python3 -c "import json,sys;print(','.join(a['type'] for a in json.load(open(sys.argv[1],encoding='utf8'))['assets']))" "$LIBRARY")
if [ "$JS_TYPES" = "$LIB_TYPES" ]; then
  pass "layout.js PLAN_TYPES 与资产库一致（$(echo "$LIB_TYPES" | tr ',' ' ' | wc -w | tr -d ' ') 种）"
else
  fail 'layout.js PLAN_TYPES 与资产库不一致' "js=$JS_TYPES lib=$LIB_TYPES"
fi
PY_TYPES=$(cd "$PLUGIN_DIR/lib/scripts" && python3 -c "import layout_validate as v;print(','.join(v.PLAN_TYPES))")
if [ "$PY_TYPES" = "$LIB_TYPES" ]; then
  pass 'layout_validate.py PLAN_TYPES 与资产库一致'
else
  fail 'layout_validate.py PLAN_TYPES 与资产库不一致' "py=$PY_TYPES lib=$LIB_TYPES"
fi
SCHEMA_TYPES=$(cd "$PLUGIN_DIR" && node --input-type=module -e "
import { PLAN_OUTPUT_SCHEMA } from './lib/plan-tool.js'
const enumTypes = PLAN_OUTPUT_SCHEMA.properties.plan.properties.objects.items.properties.type.enum
console.log(enumTypes.join(','))")
if [ "$SCHEMA_TYPES" = "$LIB_TYPES" ]; then
  pass 'plan_scene_layout schema 的 type enum 与资产库一致'
else
  fail 'schema type enum 与资产库不一致' "schema=$SCHEMA_TYPES"
fi
CATALOG_LINES=$(cd "$PLUGIN_DIR" && node --input-type=module -e "
import { buildTypeCatalog } from './lib/plan-tool.js'
console.log(buildTypeCatalog().split('\n').length)")
if [ "$CATALOG_LINES" -ge 15 ]; then
  pass "系统 prompt 的 type 清单覆盖全部类型（$CATALOG_LINES 行）"
else
  fail "系统 prompt 的 type 清单过短（$CATALOG_LINES 行）"
fi

# ---------------------------------------------------------------- 3. 真实模型规划（PTC headless）
section '3. 真实模型调用 plan_scene_layout'
if [ "$SKIP_LLM" = "1" ]; then
  printf 'SKIP  跳过了真实模型调用（--skip-llm）\n'
else
  MODEL_PLAN="$WORK/model-plan.json"
  TASK="请调用 plan_scene_layout 工具，场景描述：\"一座日式庭院：中央一个圆形喷泉，四角各一根石柱，北侧一段矮墙，西南角一棵大树，东侧一张长椅和一盏灯柱，南侧一个木箱和一只木桶，东南角立一座雕像\"。width=30，depth=24，savePath=\"$MODEL_PLAN\"。"
  if (cd "$ROOT" && DSH_TOOLS_MODE=ptc timeout 300 dsh --profile headless \
      --patch "$ROOT/scratch-plugin/cordis-headless-auth.yml" \
      --patch "$ROOT/scratch-plugin/cordis-ptc.yml" \
      --json "$TASK" > "$WORK/ptc.jsonl" 2>"$WORK/ptc.err"); then
    :
  fi
  if grep -q '"tool":"plan_scene_layout"' "$WORK/ptc.jsonl" 2>/dev/null; then
    pass '模型调用了 plan_scene_layout'
  else
    fail '模型没有调用 plan_scene_layout' "$(tail -2 "$WORK/ptc.err" 2>/dev/null | tr '\n' ' ')"
  fi
  python3 - "$WORK/ptc.jsonl" "$LIBRARY" "$MODEL_PLAN" <<'PYEOF2'
import json, os, re, sys
events = []
for line in open(sys.argv[1], encoding='utf8', errors='replace'):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        continue
library = json.load(open(sys.argv[2], encoding='utf8'))
allowed = {a['type'] for a in library['assets']}
model_plan_path = sys.argv[3]
plan = None
if os.path.exists(model_plan_path):
    try:
        plan = json.load(open(model_plan_path, encoding='utf8'))
    except Exception:
        plan = None
if plan is None:
    # 回退：从 plan_scene_layout 的 tool_result 渲染文本里解析 “id（type）”
    plan_ids = {}
    for event in events:
        if event.get('type') != 'tool_result':
            continue
        text = str(event.get('result') or '')
        for match in re.finditer(r'-\s+([A-Za-z0-9_]+)（([a-z_]+)）', text):
            plan_ids[match.group(1)] = match.group(2)
    if plan_ids:
        objects = [{'id': key, 'type': value} for key, value in plan_ids.items()]
        plan = {'objects': objects}
if plan is None:
    print('FAIL  没能从事件流或 savePath 里提取 plan')
    sys.exit(1)
objects = plan.get('objects') or []
types = [o.get('type') for o in objects]
print(f"模型 plan 对象数={len(objects)} 类型={sorted(set(types))}")
failed = False
def check(label, ok, detail=''):
    global failed
    print(('PASS  ' if ok else 'FAIL  ') + label + (('  ' + detail) if detail and not ok else ''))
    failed = failed or not ok
check('plan 对象数 >= 5', len(objects) >= 5, str(len(objects)))
unknown = sorted({t for t in types if t not in allowed})
check('plan 里所有 type 都在资产库白名单中', not unknown, str(unknown))
check('覆盖的 type 种类 >= 4', len(set(types)) >= 4, str(len(set(types))))
sys.exit(1 if failed else 0)
PYEOF2
  if [ $? -ne 0 ]; then FAIL=$((FAIL + 1)); fi
fi

# ---------------------------------------------------------------- 4. Blender：全类型几何
section '4. Blender llm 模式（18 种 type 全覆盖）'
python3 - "$LIBRARY" "$WORK/plan.json" <<'PY'
import json, sys
library = json.load(open(sys.argv[1], encoding='utf8'))
assets = library['assets']
objects = []
cols = 6
for index, entry in enumerate(assets):
    x = (index % cols - 2.5) * 5.5
    z = (index // cols - 1) * 7.0
    objects.append({
        'id': f"{entry['type']}_01",
        'type': entry['type'],
        'position': [round(x, 2), 0, round(z, 2)],
        'size': entry['defaultSize'],
    })
plan = {'sceneName': 'TypeShowcase', 'bounds': {'width': 40, 'depth': 24}, 'objects': objects}
json.dump(plan, open(sys.argv[2], 'w', encoding='utf8'), ensure_ascii=False, indent=2)
print(f'plan objects={len(objects)}')
PY
if python3 "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/plan.json" > /dev/null; then
  pass '全类型 plan 通过布局校验'
else
  fail '全类型 plan 未通过布局校验'
fi
if [ ! -x "$BLENDER" ]; then
  fail "找不到 Blender 可执行文件：$BLENDER"
else
  if (cd "$PLUGIN_DIR" && "$BLENDER" --background --factory-startup --python lib/scripts/run_scenic.py -- \
      lib/scripts/scenes/courtyard.py "$WORK/scene.blend" "$WORK/scene.glb" "$WORK/scene.fbx" "$WORK/layout.json" \
      "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/plan.json\",\"layoutAxis\":\"y-up\"}" \
      > "$WORK/blender.log" 2>&1); then
    pass 'Blender llm 模式执行成功'
  else
    fail 'Blender llm 模式执行失败' "$(tail -3 "$WORK/blender.log" | tr '\n' ' ')"
  fi
  RESULT=$(grep -o 'DSH_BLENDER_RESULT:.*' "$WORK/blender.log" | head -1 | sed 's/^DSH_BLENDER_RESULT://')
  if [ -n "$RESULT" ]; then
    python3 - "$RESULT" "$WORK/plan.json" <<'PY'
import json, sys
result = json.loads(sys.argv[1])
plan = json.load(open(sys.argv[2], encoding='utf8'))
objects = plan['objects']
print(f"blender objectCount={result.get('objectCount')} blenderObjects={result.get('objects')}")
checks = [
    ('layout 对象数 = plan 对象数 + 地面', result.get('objectCount') == len(objects) + 1),
    ('分组含 Terrain/Buildings/Props', all(g in result.get('groups', []) for g in ('Terrain', 'Buildings', 'Props'))),
    ('Blender 网格数 >= 每种 type 至少 1 个', (result.get('objects') or 0) >= len(objects)),
]
failed = False
for label, ok in checks:
    print(('PASS  ' if ok else 'FAIL  ') + label)
    failed = failed or not ok
sys.exit(1 if failed else 0)
PY
    if [ $? -ne 0 ]; then FAIL=$((FAIL + 1)); fi
  else
    fail 'Blender 没有输出 DSH_BLENDER_RESULT'
  fi
  # 每个 type 的 base Empty 带 dsh_type 自定义属性、且网格子节点名字以 type 开头
  cat > "$WORK/inspect.py" <<'PY'
import bpy, json, sys
report = {}
for obj in bpy.data.objects:
    if obj.type == 'EMPTY' and 'dsh_type' in obj.keys():
        report[obj.name] = {
            'type': obj['dsh_type'],
            'category': obj['dsh_category'],
            'parts': sorted(child.name for child in obj.children if child.type == 'MESH'),
        }
print('DSH_TYPES_REPORT:' + json.dumps(report))
PY
  "$BLENDER" --background "$WORK/scene.blend" --python "$WORK/inspect.py" 2>/dev/null | grep 'DSH_TYPES_REPORT:' | sed 's/^DSH_TYPES_REPORT://' > "$WORK/types.json"
  python3 - "$WORK/types.json" "$WORK/plan.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding='utf8'))
plan = json.load(open(sys.argv[2], encoding='utf8'))
expected = {o['id']: o['type'] for o in plan['objects']}
problems = []
for object_id, object_type in expected.items():
    entry = report.get(object_id)
    if entry is None:
        problems.append(f'{object_id} 没有 dsh_type 标记')
        continue
    if entry['type'] != object_type:
        problems.append(f"{object_id} dsh_type={entry['type']} != {object_type}")
    if not entry['parts']:
        problems.append(f'{object_id} 没有网格子节点')
    elif not all(part.startswith(object_id) for part in entry['parts']):
        problems.append(f"{object_id} 的网格子节点名字不规范：{entry['parts'][:2]}")
part_counts = {entry['type']: len(entry['parts']) for entry in report.values()}
if len(set(part_counts.values())) < 2:
    problems.append('所有 type 的图元数量完全相同，视觉可能不可区分')
if problems:
    print('FAIL  几何可区分性检查失败：')
    for problem in problems[:8]:
        print('      - ' + problem)
    sys.exit(1)
print(f'PASS  {len(report)} 种 type 都有 dsh_type 标记与网格子节点（图元数 {min(part_counts.values())}–{max(part_counts.values())}）')
PY
  if [ $? -ne 0 ]; then FAIL=$((FAIL + 1)); fi
  # layout.json 里每个 plan 对象都存在
  python3 - "$WORK/layout.json" "$WORK/plan.json" <<'PY'
import json, sys
layout = json.load(open(sys.argv[1], encoding='utf8'))
plan = json.load(open(sys.argv[2], encoding='utf8'))
layout_names = {o['instanceName'] for g in layout['groups'] for o in g['objects']}
missing = [o['id'] for o in plan['objects'] if o['id'] not in layout_names]
if missing:
    print(f'FAIL  layout.json 缺少对象：{missing[:5]}')
    sys.exit(1)
print(f'PASS  layout.json 包含 plan 的全部 {len(plan["objects"])} 个对象')
PY
  if [ $? -ne 0 ]; then FAIL=$((FAIL + 1)); fi
fi

# ---------------------------------------------------------------- 5. 非法 type 拒绝
section '5. 非法 type 被拒绝'
python3 - "$WORK/bad-plan.json" <<'PY'
import json, sys
plan = {'sceneName': 'Bad', 'objects': [
    {'id': 'x_01', 'type': 'spaceship', 'position': [0, 0, 0], 'size': [2, 2, 2]},
]}
json.dump(plan, open(sys.argv[1], 'w', encoding='utf8'), ensure_ascii=False)
PY
if python3 "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/bad-plan.json" > /dev/null 2>"$WORK/bad.err"; then
  fail '非法 type 竟然通过了校验'
else
  pass '非法 type 被校验器拒绝'
fi
if grep -q 'type 必须是' "$WORK/bad.err" && grep -q 'archway' "$WORK/bad.err" && grep -q 'chair' "$WORK/bad.err"; then
  pass '错误信息列出了可用 type 列表'
else
  fail '错误信息没有列出可用 type' "$(head -2 "$WORK/bad.err" | tr '\n' ' ')"
fi
if grep -q 'group 与 type 不匹配\|group 只能是' "$WORK/bad.err" 2>/dev/null; then
  : # 本例没写 group，不要求
fi

# category 与 type 不匹配也要拒绝
python3 - "$WORK/bad-group.json" <<'PY'
import json, sys
plan = {'objects': [
    {'id': 'tree_01', 'type': 'tree', 'position': [0, 0, 0], 'size': [3, 5, 3], 'group': 'Buildings'},
]}
json.dump(plan, open(sys.argv[1], 'w', encoding='utf8'), ensure_ascii=False)
PY
if python3 "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/bad-group.json" > /dev/null 2>"$WORK/bad-group.err"; then
  fail 'category 与 type 不匹配竟然通过'
else
  if grep -q 'group 与 type 不匹配' "$WORK/bad-group.err"; then
    pass 'category 与 type 不匹配被拒绝'
  else
    fail 'category 不匹配的报错信息不清晰' "$(head -2 "$WORK/bad-group.err" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- 6. 回归 verify-layout-llm
section '6. 回归 verify-layout-llm.sh'
if (cd "$ROOT" && bash "$PLUGIN_DIR/scripts/verify/verify-layout-llm.sh" > "$WORK/llm-regression.log" 2>&1); then
  pass 'verify-layout-llm.sh 仍通过'
else
  fail 'verify-layout-llm.sh 回归失败' "$(tail -3 "$WORK/llm-regression.log" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 汇总
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo '资产库 / 类型扩展验收通过。'
  exit 0
fi
echo '资产库 / 类型扩展验收失败。'
exit 1
