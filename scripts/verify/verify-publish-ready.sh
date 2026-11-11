#!/usr/bin/env bash
# 发布就绪检查：README 必需章节 / 发布文件与元数据 / 无本机绝对路径与 token / 核心回归（--skip-real）
#
# 用法：
#   bash scripts/verify/verify-publish-ready.sh            # 含 all.sh --skip-real 实跑
#   bash scripts/verify/verify-publish-ready.sh --skip-run # 只做静态检查（约 2 秒）
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
README="$PLUGIN_DIR/README.md"
PKG="$PLUGIN_DIR/package.json"
SKIP_RUN=0
[ "${1:-}" = "--skip-run" ] && SKIP_RUN=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }

has_line() { grep -qF "$2" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 1. 文档
section '1. README 必需章节'
for title in \
  '## 它能做什么 / 不做什么' \
  '## 环境要求' \
  '## 快速开始' \
  '## 配置项' \
  '## 场景布局契约' \
  '## LLM 精确布局' \
  '## 材质映射（asset-library 贴图）' \
  '## 几何模型库配置' \
  '## 导入到你的引擎' \
  '## 工具与 service' \
  '## 验证' \
  '## 已知限制' \
  '## 路线图' \
  '## 许可证'; do
  if has_line "$README" "$title"; then pass "README 包含《${title#\#\# }》"; else fail "README 缺少章节" "$title"; fi
done

section '2. README 关键内容'
assert_contains() { # 描述 关键词
  if grep -qF -- "$2" "$README" 2>/dev/null; then pass "$1"; else fail "$1" "README 里找不到：$2"; fi
}
assert_contains 'README 写明「合规声明」内容' '不涉及在线游戏自动化'
assert_contains 'README 写明不做可玩关卡生成器' '不是可玩关卡生成器'
assert_contains 'README 写明 layoutAxis 默认 z-up' '`axis`）——本版本默认 `z-up`'
assert_contains 'README 写明 breaking change' 'breaking change'
assert_contains 'README 写明 Unity 需转 Y-up' '先转成 Unity 的 Y-up'
assert_contains 'README 写明 UE 左手系' 'UE 是 Z-up 左手系'
assert_contains 'README 写明 Godot Y-up' 'Godot 是 Y-up 右手系'
assert_contains 'README 写明磁盘约 25 GB' '25 GB'
assert_contains 'README 写明不要并行跑验证脚本' '不要并行跑验证脚本'
assert_contains 'README 写明 LLM 布局成功率非 100%' 'LLM 布局成功率非 100%'
assert_contains 'README 写明路线图含 PBR 贴图' 'PBR 贴图'
assert_contains 'README 写明路线图含图生 3D' '图生 3D'
assert_contains 'README 写明材质映射需自备 CC0 贴图' '插件不自带任何贴图文件'
assert_contains 'README 写明几何映射需自备 GLB 资产' '插件不自带任何真实模型'
assert_contains 'README 写明 CC0 资产包链接 Kenney' 'kenney.nl/assets/nature-kit'
assert_contains 'README 写明 CC0 资产包链接 Quaternius' 'quaternius.com/packs/medievalvillagemegakit.html'
assert_contains 'README 写明 --with-unity 用法' '--with-unity'
assert_contains 'README 写明 --skip-real 用法' '--skip-real'
assert_contains 'README 记录 clone 自检' 'clone 自检记录'
assert_contains 'README 使用 127.0.0.1:8188 占位而非硬编码地址' '127.0.0.1:8188'

# ---------------------------------------------------------------- 3. 发布文件
section '3. 发布文件与元数据'
for f in LICENSE README.md .gitignore package.json cordis.patch.yml requirements-scenic.txt; do
  if [ -f "$PLUGIN_DIR/$f" ]; then pass "存在 $f"; else fail "缺少 $f"; fi
done
if [ -f "$PLUGIN_DIR/LICENSE" ] && grep -q 'MIT License' "$PLUGIN_DIR/LICENSE"; then
  pass 'LICENSE 是 MIT'
else
  fail 'LICENSE 不是 MIT 或缺失'
fi

python3 - "$PKG" <<'PY'
import json, sys
path = sys.argv[1]
problems = []
with open(path, encoding='utf8') as fh:
    pkg = json.load(fh)

def check(label, ok, detail=''):
    print(('PASS  ' if ok else 'FAIL  ') + label + (('  ' + detail) if detail and not ok else ''))
    if not ok:
        problems.append(label)

name = pkg.get('name') or ''
version = str(pkg.get('version') or '')
desc = pkg.get('description') or ''
check('package.json name 正确', name == 'dsh-scene-skeleton-pipeline', name)
check('package.json version 是 0.1.x', version.startswith('0.1.'), version)
check('package.json description 非空且不是旧文案', bool(desc) and '骨架 + 环境检测' not in desc, desc)
check('package.json license 是 MIT', pkg.get('license') == 'MIT')
repo = pkg.get('repository') or {}
check('package.json repository 有 url', bool(repo.get('url')))
keywords = [str(k).lower() for k in (pkg.get('keywords') or [])]
required = {'dsh-plugin', 'comfyui', 'blender', 'scene-generation', 'game-dev-tools', 'asset-pipeline'}
check('package.json keywords 含必需项', required.issubset(set(keywords)), ','.join(sorted(required - set(keywords))))
files = pkg.get('files') or []
for item in ('index.js', 'client.js', 'lib/', 'adapters/', 'examples/', 'scripts/', 'LICENSE'):
    check(f'package.json files 含 {item}', item in files)
check('package.json 声明 dsh.bundle.patch', bool((pkg.get('dsh') or {}).get('bundle', {}).get('patch')))
check('package.json 声明 dsh.client', bool((pkg.get('dsh') or {}).get('client')))
sys.exit(1 if problems else 0)
PY
if [ $? -ne 0 ]; then FAIL=$((FAIL + 1)); fi

# ---------------------------------------------------------------- 4. 卫生检查
section '4. 仓库卫生（无本机路径 / token / 硬编码地址）'
SCAN_FILES=$(cd "$PLUGIN_DIR" && find . -type f \
  \( -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.json' -o -name '*.md' -o -name '*.sh' \
     -o -name '*.yml' -o -name '*.py' -o -name '*.cs' -o -name '*.txt' \) \
  -not -path './node_modules/*' -not -name 'verify-publish-ready.sh' 2>/dev/null)

scan_report() { # 描述 正则
  local label="$1" pattern="$2" hits
  hits=$(cd "$PLUGIN_DIR" && printf '%s\n' "$SCAN_FILES" | xargs grep -nE -- "$pattern" 2>/dev/null | grep -v '^\./README.md:.*/Users/' | head -5)
  if [ -z "$hits" ]; then
    pass "$label"
  else
    fail "$label" "$(printf '%s' "$hits" | head -3)"
  fi
}
scan_report '没有 /Users/ 本机路径' '/Users/'
scan_report '没有 /home/ 本机路径' '/home/[a-z]'
scan_report '没有硬编码 token / 密钥' '(token=[A-Za-z0-9_-]{16,}|Bearer [A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,})'
scan_report '没有非 127.0.0.1 的硬编码 ComfyUI 地址' 'http://(?!127\.0\.0\.1)[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:8188' 2>/dev/null || true

# .gitignore 覆盖项
for pat in '.dsh-dev/' 'node_modules/' 'e2e-artifacts/**/*.png' '.env'; do
  if has_line "$PLUGIN_DIR/.gitignore" "$pat"; then pass ".gitignore 含 $pat"; else fail ".gitignore 缺少 $pat"; fi
done

# ---------------------------------------------------------------- 5. 核心回归
section '5. 核心回归（all.sh --skip-real）'
if [ "$SKIP_RUN" = "1" ]; then
  printf 'SKIP  手动跳过了 all.sh --skip-real\n'
else
  if (cd "$ROOT" && bash "$PLUGIN_DIR/scripts/verify/all.sh" --skip-real > /tmp/publish-ready-all.log 2>&1); then
    pass 'all.sh --skip-real 退出码 0'
  else
    fail 'all.sh --skip-real 未通过' "见 /tmp/publish-ready-all.log 尾部：$(tail -3 /tmp/publish-ready-all.log | tr '\n' ' ')"
  fi
  if grep -q '核心    PASS=13 FAIL=0' /tmp/publish-ready-all.log; then
    pass '核心组 13 项全 PASS'
  else
    fail '核心组未全 PASS' "$(grep '核心' /tmp/publish-ready-all.log | tail -1)"
  fi
  if grep -q 'harness PASS=4 FAIL=0' /tmp/publish-ready-all.log; then
    pass 'harness 组 4 项全 PASS'
  else
    fail 'harness 组未全 PASS' "$(grep 'harness' /tmp/publish-ready-all.log | tail -1)"
  fi
fi

# ---------------------------------------------------------------- 汇总
printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo '发布就绪检查通过。'
  exit 0
fi
echo '发布就绪检查失败。'
exit 1
