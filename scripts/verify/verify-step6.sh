#!/usr/bin/env bash
# ============================================================================
# 阶段 6 验证：README 示例 / PTC 示例 / 发布文件 / 回归入口
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step6.sh [--skip-real]
#   bash dsh-scene-skeleton-pipeline/scripts/verify/all.sh        # 2→6 全套回归
#
# [1]-[6] 是仓库与文档一致性检查（不需要真实软件）；
# [7]-[9] 是 scenic 阶段真实链路（需要真实 ComfyUI 8188 / Blender）：scenic 安装检查 +
# scenic/legacy 各跑一次（引擎无关核心；Unity 断言见 adapters/unity/verify-unity-adapter.sh）。
# ============================================================================
set -uo pipefail

SKIP_REAL=0
[ "${1:-}" = "--skip-real" ] && SKIP_REAL=1

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

echo "[1] 发布文件齐全"
for f in LICENSE .gitignore README.md package.json cordis.patch.yml index.js client.js \
         requirements-scenic.txt \
         lib/layout.js lib/pipeline.js lib/pipeline-tool.js lib/settings.js lib/store.js \
         lib/executors/comfy.js lib/executors/blender.js lib/executors/process.js \
         lib/scripts/build_scene.py lib/scripts/run_scenic.py lib/scripts/scenes/courtyard.py \
         adapters/unity/unity.js adapters/unity/SceneSkeletonPipelineEditor.cs \
         adapters/unity/verify-unity-adapter.sh \
         lib/workflows/txt2img.json lib/workflows/pbr-superpbr.json lib/workflows/pbr-superpbr-lite.json lib/asset-library.json \
         scripts/verify/fixtures/models/kenney_nature/tree_pine.glb \
         examples/ptc-run-scene.ts; do
  check "存在 $f" "[ -s '$PLUGIN_DIR/$f' ]"
done
for f in verify-load.sh verify-step2.sh verify-step3.sh verify-step4.sh verify-step5.sh verify-step6.sh \
         verify-blender-export.sh verify-layout-axis.sh verify-layout-llm.sh verify-layout-types.sh \
         verify-layout-validation.sh verify-texture.sh verify-material-mapping.sh verify-geometry-mapping.sh \
         verify-regression-meta.sh verify-publish-ready.sh all.sh real-e2e.mjs layout-axis-probe.mjs; do
  check "存在 scripts/verify/$f" "[ -s '$PLUGIN_DIR/scripts/verify/$f' ]"
done

echo "[2] package.json 元数据"
node - "$PLUGIN_DIR/package.json" <<'NODE'
const fs = require('fs')
const p = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const want = [
  ['name 正确', p.name === 'dsh-scene-skeleton-pipeline'],
  ['version 是 0.1.x', /^0\.1\./.test(String(p.version))],
  ['description 非空且不再是“骨架 + 环境检测”', Boolean(p.description) && !/插件骨架 \+ 环境检测/.test(p.description)],
  ['license 是 MIT', p.license === 'MIT'],
  ['repository 有 url', Boolean(p.repository && p.repository.url)],
  ['files 含 examples/ 与 scripts/', Array.isArray(p.files) && p.files.includes('examples/') && p.files.includes('scripts/')],
  ['dsh.bundle.patch 已声明', p.dsh?.bundle?.patch === './cordis.patch.yml'],
  ['dsh.client.platform 是 web', p.dsh?.client?.platform === 'web'],
  ['exports 暴露 ./client', p.exports?.['./client'] === './client.js'],
]
for (const [name, okv] of want) { console.log(`${okv ? 'ok' : 'FAIL'} ${name}`) }
process.exit(want.every(([, okv]) => okv) ? 0 : 1)
NODE
if [ $? -eq 0 ]; then PASS=$((PASS + 9)); else FAIL=$((FAIL + 1)); fi

echo "[3] cordis.patch.yml 挂载声明"
grep -q '^- insert:' "$PLUGIN_DIR/cordis.patch.yml" && grep -q 'id: dsh-scene-skeleton-pipeline' "$PLUGIN_DIR/cordis.patch.yml" \
  && ok "insert 条目含 id" || bad "insert 条目含 id"

echo "[4] README 章节与引用"
for h in '## 它能做什么 / 不做什么' '## 环境要求' '## 快速开始' '## 场景布局契约' '## 导入到你的引擎' '## 验证' '## 已知限制' '## 路线图' '## 许可证'; do
  check "README 有章节 $h" "grep -qF '$h' '$PLUGIN_DIR/README.md'"
done
check "README 引用 examples/ptc-run-scene.ts 且文件存在" "grep -qF 'examples/ptc-run-scene.ts' '$PLUGIN_DIR/README.md' && [ -s '$PLUGIN_DIR/examples/ptc-run-scene.ts' ]"
check "README 引用 scripts/verify/all.sh 且文件存在" "grep -qF 'scripts/verify/all.sh' '$PLUGIN_DIR/README.md' && [ -s '$PLUGIN_DIR/scripts/verify/all.sh' ]"
check "README 引用 layout.json 契约示例" "grep -qF '\"sceneName\": \"SceneSkeleton\"' '$PLUGIN_DIR/README.md'"
check "README 不再残留过时路径 scratch-plugin/verify-step" "! grep -qF 'scratch-plugin/verify-step' '$PLUGIN_DIR/README.md'"

echo "[5] examples/ptc-run-scene.ts 语法可解析（按 run_code 语义：async 函数体）"
node --input-type=module - "$PLUGIN_DIR/examples/ptc-run-scene.ts" <<'NODE'
import { readFileSync } from 'node:fs'
const src = readFileSync(process.argv[2], 'utf8')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
try {
  new AsyncFunction('tools', src)
  const need = ['tools.run_scene_pipeline', 'dryRun: false', 'summary.scenePath', 'failedStage', 'logs']
  const missing = need.filter(token => !src.includes(token))
  if (missing.length) { console.error('缺少关键片段:', missing.join(', ')); process.exit(1) }
  console.log('ok 语法与关键片段')
} catch (error) {
  console.error('语法错误:', error.message)
  process.exit(1)
}
NODE
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo "[6] 回归入口可执行（语法 + 路径）"
for f in verify-step2.sh verify-step3.sh verify-step4.sh verify-step5.sh verify-step6.sh all.sh verify-load.sh; do
  check "bash -n scripts/verify/$f" "bash -n '$PLUGIN_DIR/scripts/verify/$f'"
done
check "all.sh 依次调用 step2..step6" "grep -qF 'verify-step2.sh' '$PLUGIN_DIR/scripts/verify/all.sh' && grep -qF 'verify-step6.sh' '$PLUGIN_DIR/scripts/verify/all.sh'"
check ".gitignore 排除 .dsh-dev/" "grep -qF '.dsh-dev/' '$PLUGIN_DIR/.gitignore'"
check ".gitignore 排除 node_modules/" "grep -qF 'node_modules/' '$PLUGIN_DIR/.gitignore'"
check ".gitignore 排除大产物" "grep -qF 'e2e-artifacts/**/*.png' '$PLUGIN_DIR/.gitignore'"

# ---------------------------------------------------------------------------
# 阶段 6（scenic）真实链路：scenic 安装检查 + scenic/legacy 两种模式各跑一次
# （需要真实 ComfyUI 8188 / Blender；引擎无关核心，不依赖 Unity）
# ---------------------------------------------------------------------------
BLENDER_EXE="${BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"

echo "[7] scenic 安装检查"
check "Blender 可执行存在" "[ -x '$BLENDER_EXE' ]"
check "scenic 可在 Blender Python 导入" "'$BLENDER_EXE' --background --factory-startup --python-expr 'import scenic' >/dev/null 2>&1"

if [ "$SKIP_REAL" -eq 1 ]; then
  echo
  echo '[8][9] 真实链路：已跳过（--skip-real）'
else

echo "[8] scenic 模式真实链路（默认模式）"
SCENIC_OUT=/tmp/dsh-scene-e2e-step6-scenic
rm -rf "$SCENIC_OUT"
SCENIC_LOG=/tmp/step6-scenic.log
if node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" '' "$SCENIC_OUT" \
  'a quiet courtyard with stone walls and a watchtower, isometric concept art' scenic >"$SCENIC_LOG" 2>&1; then
  ok 'scenic 真实执行 exit 0'
else
  bad "scenic 真实执行失败（日志 ${SCENIC_LOG}）"
fi
SCENIC_LAYOUT=$(ls "$SCENIC_OUT"/jobs/*/blender/layout.json 2>/dev/null | head -1)
SCENIC_JOB="$SCENIC_OUT/last-job.json"
python3 - "$SCENIC_LAYOUT" "$SCENIC_JOB" <<'PY'
import json, os, sys
ok = 0
def check(name, cond, extra=''):
    global ok
    print(('ok  ' if cond else 'FAIL ') + name + (f'（{extra}）' if extra and not cond else ''))
    if cond: ok += 1
layout = json.load(open(sys.argv[1])) if sys.argv[1] and os.path.exists(sys.argv[1]) else None
job = json.load(open(sys.argv[2])) if sys.argv[2] and os.path.exists(sys.argv[2]) else None
check('scenic layout.json 存在', layout is not None)
groups = [g.get('name') for g in layout.get('groups', [])] if layout else []
objects = sum(len(g.get('objects', [])) for g in layout.get('groups', [])) if layout else 0
check('scenic layout 分组 >= 3', len(groups) >= 3, ','.join(groups))
check('scenic layout 对象 >= 5', objects >= 5, str(objects))
check('scenic layout 有 lighting/camera/prefab 段',
      bool(layout.get('lighting')) and bool(layout.get('camera')) and 'prefab' in layout)
check('job status done', bool(job and job.get('status') == 'done'), str(job.get('status')) if job else '')
print(f'OK={ok}/5')
sys.exit(0 if ok == 5 else 1)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 5)); else FAIL=$((FAIL + 1)); fi

echo "[9] legacy 模式回归（旧固定体块链路仍可用）"
LEGACY_OUT=/tmp/dsh-scene-e2e-step6-legacy
rm -rf "$LEGACY_OUT"
LEGACY_LOG=/tmp/step6-legacy.log
if node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" '' "$LEGACY_OUT" \
  'a quiet courtyard with stone walls and a watchtower, isometric concept art' legacy >"$LEGACY_LOG" 2>&1; then
  ok 'legacy 真实执行 exit 0'
else
  bad "legacy 真实执行失败（日志 ${LEGACY_LOG}）"
fi
LEGACY_LAYOUT=$(ls "$LEGACY_OUT"/jobs/*/blender/layout.json 2>/dev/null | head -1)
python3 - "$LEGACY_LAYOUT" <<'PY'
import json, os, sys
ok = 0
def check(name, cond, extra=''):
    global ok
    print(('ok  ' if cond else 'FAIL ') + name + (f'（{extra}）' if extra and not cond else ''))
    if cond: ok += 1
layout = json.load(open(sys.argv[1])) if sys.argv[1] and os.path.exists(sys.argv[1]) else None
groups = [g.get('name') for g in layout.get('groups', [])] if layout else []
objects = sum(len(g.get('objects', [])) for g in layout.get('groups', [])) if layout else 0
check('legacy layout 分组 = Terrain/Props/Reference', groups == ['Terrain', 'Props', 'Reference'], ','.join(groups))
check('legacy layout 对象 >= 2', objects >= 2, str(objects))
print(f'OK={ok}/2')
sys.exit(0 if ok == 2 else 1)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo '阶段 6 验证失败'; exit 1; fi
echo '阶段 6 验证通过'
