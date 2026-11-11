// ============================================================================
// PTC（run_code）示例：在 DSH 的 PTC 会话里调用 dsh-scene-skeleton-pipeline
// ============================================================================
// 用法：在 PTC preset 的会话中，把下面整段代码交给 run_code 工具执行。
// PTC 会话会把 dsh-scene-skeleton-pipeline 注册的工具暴露成 `tools.<name>`，
// 本示例对应 run_scene_pipeline：
//   prompt  : string  必填，场景描述（等价于面板里的 prompt / sceneDescription）
//   dryRun  : boolean 可选，默认 true；false 才会真实启动 ComfyUI/Blender/Unity
// 输出目录、Unity 工程、ComfyUI 地址等走插件配置（设置面板 / config.json），
// 不是工具参数。
// ============================================================================

const prompt =
  'a quiet courtyard with stone walls and a watchtower, concept art, isometric view'

// 1) 真实执行一次三节点流水线（ComfyUI → Blender → Unity，约 1-3 分钟）
const result = await tools.run_scene_pipeline({ prompt, dryRun: false })

// 2) 失败时从 failedStage + logs 里拿到可读原因（PTC 返回的是普通 JSON）
if (!result.ok) {
  const logs = Array.isArray(result.logs) ? result.logs.join('\n') : ''
  throw new Error(`流水线失败：failedStage=${result.failedStage ?? '(未知)'}\n${logs}`)
}

// 3) 读取并直接使用结构化 summary（下面这些字段就是模型后续代码的输入）
const summary = result.summary
if (!summary || !summary.scenePath) {
  throw new Error('流水线返回成功，但没有 summary.scenePath')
}

// 简单的后续校验：场景必须有层级分组和至少一个对象
if (!summary.groups?.includes('Terrain')) {
  throw new Error(`场景缺少 Terrain 分组：${JSON.stringify(summary.groups)}`)
}
if (!(summary.objectCount >= 1)) {
  throw new Error(`场景对象数异常：${summary.objectCount}`)
}

return {
  jobId: result.jobId,
  status: result.status,
  scenePath: summary.scenePath,
  objectCount: summary.objectCount,
  groups: summary.groups,
  prefabPath: summary.prefabPath ?? null,
  artifacts: result.artifacts,
}
