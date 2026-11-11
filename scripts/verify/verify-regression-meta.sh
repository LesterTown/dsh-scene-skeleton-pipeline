#!/usr/bin/env bash
# ============================================================================
# 回归体系元检查（阶段 5）：保证「引擎无关核心 + 可选 Unity 适配器」的分工不被回潮。
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-regression-meta.sh
#
# 断言：
#   [1] all.sh 可执行（bash -n）、含三组标签与 --with-unity 开关
#   [2] verify-step4/5/6.sh 已不含 Unity 断言（unity-result / Main Camera / PrefabInstance /
#       "环境 unity"），且顶部有迁移说明注释
#   [3] adapters/unity/verify-unity-adapter.sh 存在、语法正确、含 SKIP 分支与尺寸回归断言
#   [4] 实跑 `all.sh --skip-real`：退出码 0、汇总无 FAIL、适配器组 SKIP、harness 组 PASS
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
ADAPTER="$PLUGIN_DIR/adapters/unity/verify-unity-adapter.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo '[1] all.sh 结构'
check 'all.sh 语法正确' "bash -n '$HERE/all.sh'"
check 'all.sh 支持 --with-unity' "grep -q -- '--with-unity' '$HERE/all.sh'"
check 'all.sh 有核心/适配器/harness 三组标签' \
  "grep -q '\\[核心\\]' '$HERE/all.sh' && grep -q '\\[适配器\\]' '$HERE/all.sh' && grep -q '\\[harness\\]' '$HERE/all.sh'"
check 'all.sh 汇总含核心/适配器/harness 计数' \
  "grep -q '核心    PASS=' '$HERE/all.sh' && grep -q '适配器  PASS=' '$HERE/all.sh' && grep -q 'harness PASS=' '$HERE/all.sh'"

echo '[2] step4/5/6 已无 Unity 断言'
for step in verify-step4.sh verify-step5.sh verify-step6.sh; do
  check "$step 语法正确" "bash -n '$HERE/$step'"
  check "$step 不含 unity-result 断言" "! grep -q 'unity-result' '$HERE/$step'"
  check "$step 不含场景 Unity 对象断言" "! grep -q 'Main Camera' '$HERE/$step'"
  check "$step 不含 '环境 unity' 断言" "! grep -q \"环境 unity\" '$HERE/$step'"
  check "$step 顶部标注迁移去向" "grep -q 'verify-unity-adapter.sh' '$HERE/$step'"
done

echo '[3] Unity 适配器脚本'
check '适配器脚本存在' "[ -s '$ADAPTER' ]"
check '适配器脚本语法正确' "bash -n '$ADAPTER'"
check '适配器脚本含 SKIP 分支' "grep -q 'SKIP: Unity adapter disabled' '$ADAPTER'"
check '适配器脚本含 enableUnityAdapter 检查' "grep -q 'enableUnityAdapter' '$ADAPTER'"
check '适配器脚本含 100 倍缩放回归（包围盒）' \
  "grep -q 'DSH_UNITY_BOUNDS_OUT' '$ADAPTER' && grep -q '100 倍' '$ADAPTER'"
check '适配器脚本走 DSH_UNITY_ADAPTER=1 的真实链路' "grep -q 'DSH_UNITY_ADAPTER=1' '$ADAPTER'"

echo '[4] 实跑 all.sh --skip-real'
SUMMARY_LOG="$(mktemp -t dsh-regression-meta.XXXXXX)"
if bash "$HERE/all.sh" --skip-real >"$SUMMARY_LOG" 2>&1; then
  ok 'all.sh --skip-real 退出码 0'
else
  bad 'all.sh --skip-real 退出码非 0（尾部输出见下）'
  tail -30 "$SUMMARY_LOG"
fi
check 'all.sh 汇总显示核心组 FAIL=0' "grep -q '核心    PASS=[0-9]* FAIL=0' '$SUMMARY_LOG'"
check 'all.sh 汇总无失败项计数' "! grep -q '总回归失败' '$SUMMARY_LOG'"
check '适配器组默认 SKIP' "grep -q '适配器  PASS=0 FAIL=0 SKIP=1' '$SUMMARY_LOG'"
check 'harness 组全 PASS' "grep -q 'harness PASS=4 FAIL=0' '$SUMMARY_LOG'"
rm -f "$SUMMARY_LOG"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo '回归体系元检查失败'
  exit 1
fi
echo '回归体系元检查通过。'
