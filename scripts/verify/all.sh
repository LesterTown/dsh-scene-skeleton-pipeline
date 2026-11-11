#!/usr/bin/env bash
# ============================================================================
# 一条命令跑完全部回归（阶段 5 重构后：引擎无关核心 + 可选 Unity 适配器）
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/all.sh              # 核心 + harness（Unity 适配器 SKIP）
#   bash dsh-scene-skeleton-pipeline/scripts/verify/all.sh --with-unity # 额外跑 Unity 适配器断言
#   bash dsh-scene-skeleton-pipeline/scripts/verify/all.sh --skip-real  # 跳过需要真实软件的链路
#
# 三组：
#   [核心] verify-step2/3/4/5/6.sh + verify-blender-export.sh + verify-layout-axis.sh
#          + verify-layout-llm.sh + verify-layout-types.sh + verify-layout-validation.sh
#          + verify-texture.sh（全量回归里跳过真实贴图推理）
#          + verify-material-mapping.sh（材质映射：未配置/已配置/部分缺失/与 SuperPBR 共存）
#          + verify-geometry-mapping.sh（几何模型注入：未配置/配置/底部对齐+等比缩放/回退）
#          —— 全 PASS 才算回归通过
#   [适配器] adapters/unity/verify-unity-adapter.sh        —— 默认 SKIP（未启用适配器时不算失败）
#   [harness] scratch-plugin/{unit,pipeline,client,plan}-harness.mjs —— 全 PASS
#
# 前置：核心组真实链路需要本机 ComfyUI 已监听 127.0.0.1:8188（--skip-real 可跳过）；
#       Unity 适配器组另外需要 Unity 工程与 Unity 编辑器。
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
SKIP_REAL=0
WITH_UNITY=0
for arg in "$@"; do
  case "$arg" in
    --skip-real) SKIP_REAL=1 ;;
    --with-unity) WITH_UNITY=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

CORE_PASS=0; CORE_FAIL=0
ADAPTER_PASS=0; ADAPTER_FAIL=0; ADAPTER_SKIP=0
HARNESS_PASS=0; HARNESS_FAIL=0
FAILED_NAMES=()

run_core() {
  local name="$1"; shift
  echo
  echo "----------------------------------------------"
  echo "► [核心] $name"
  echo "----------------------------------------------"
  if bash "$HERE/$name" "$@"; then
    CORE_PASS=$((CORE_PASS + 1)); echo "✔ [核心] $name 通过"
  else
    CORE_FAIL=$((CORE_FAIL + 1)); FAILED_NAMES+=("core:$name"); echo "✘ [核心] $name 失败"
  fi
}

run_adapter() {
  local name="$1"; shift
  echo
  echo "----------------------------------------------"
  echo "► [适配器] $name"
  echo "----------------------------------------------"
  if [ "$WITH_UNITY" -ne 1 ]; then
    ADAPTER_SKIP=$((ADAPTER_SKIP + 1))
    echo "SKIP [适配器] ${name}（未传 --with-unity；用 --with-unity 启用）"
    return 0
  fi
  if bash "$PLUGIN_DIR/adapters/unity/verify-unity-adapter.sh" --force "$@"; then
    ADAPTER_PASS=$((ADAPTER_PASS + 1)); echo "✔ [适配器] $name 通过"
  else
    ADAPTER_FAIL=$((ADAPTER_FAIL + 1)); FAILED_NAMES+=("adapter:$name"); echo "✘ [适配器] $name 失败"
  fi
}

run_harness() {
  local file="$1"
  echo
  echo "----------------------------------------------"
  echo "► [harness] $file"
  echo "----------------------------------------------"
  if node "$ROOT/scratch-plugin/$file"; then
    HARNESS_PASS=$((HARNESS_PASS + 1)); echo "✔ [harness] $file 通过"
  else
    HARNESS_FAIL=$((HARNESS_FAIL + 1)); FAILED_NAMES+=("harness:$file"); echo "✘ [harness] $file 失败"
  fi
}

# ---------------------------------------------------------------- 核心组
run_core verify-step2.sh
run_core verify-step3.sh
if [ "$SKIP_REAL" -eq 1 ]; then
  run_core verify-step4.sh --skip-real
  run_core verify-step5.sh --skip-real
else
  run_core verify-step4.sh
  run_core verify-step5.sh
fi
if [ "$SKIP_REAL" -eq 1 ]; then
  run_core verify-step6.sh --skip-real
else
  run_core verify-step6.sh
fi
run_core verify-blender-export.sh
run_core verify-layout-axis.sh
run_core verify-layout-llm.sh
if [ "$SKIP_REAL" -eq 1 ]; then
  run_core verify-layout-types.sh --skip-llm
  run_core verify-layout-validation.sh --skip-llm
  run_core verify-texture.sh --skip-llm
  run_core verify-material-mapping.sh --skip-llm
  run_core verify-geometry-mapping.sh --skip-llm
else
  run_core verify-layout-types.sh
  run_core verify-layout-validation.sh
  # 贴图真实推理较重（每对象一次 SuperPBR+MoGe），全量回归里只验开关与降级；
  # 真实贴图请单独跑 `bash scripts/verify/verify-texture.sh`。
  run_core verify-texture.sh --skip-texture
  run_core verify-material-mapping.sh
  run_core verify-geometry-mapping.sh
fi

# ---------------------------------------------------------------- 适配器组
run_adapter verify-unity-adapter.sh

# ---------------------------------------------------------------- harness 组
run_harness unit-harness.mjs
run_harness pipeline-harness.mjs
run_harness client-harness.mjs
run_harness plan-harness.mjs

# ---------------------------------------------------------------- 汇总
echo
echo "=============================================="
echo "回归汇总"
echo "=============================================="
printf '核心    PASS=%d FAIL=%d\n' "$CORE_PASS" "$CORE_FAIL"
printf '适配器  PASS=%d FAIL=%d SKIP=%d\n' "$ADAPTER_PASS" "$ADAPTER_FAIL" "$ADAPTER_SKIP"
printf 'harness PASS=%d FAIL=%d\n' "$HARNESS_PASS" "$HARNESS_FAIL"

if [ "$CORE_FAIL" -ne 0 ] || [ "$ADAPTER_FAIL" -ne 0 ] || [ "$HARNESS_FAIL" -ne 0 ]; then
  echo
  echo "总回归失败：$((CORE_FAIL + ADAPTER_FAIL + HARNESS_FAIL)) 项未通过"
  printf '失败项:\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
echo
echo '总回归通过：核心 + harness 全部 PASS（Unity 适配器 SKIP 不影响结果）。'
