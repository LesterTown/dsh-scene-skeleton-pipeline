/**
 * run_scene_pipeline 工具定义（阶段 5：返回结构化装配报告）。
 *
 * 与 check_environment 一样走「纯对象定义 + ctx.tools.register」：
 * 不 import 任何 @deepseek-ai/* 值，宿主只校验 output.schema。
 *
 * 返回值形状（模型可直接读）：
 * {
 *   ok, jobId, status,
 *   stages: { comfy: {status, detail}, blender: {...}, unity: {...} },
 *   artifacts: { image, blend, fbx, layout, scene, prefab },   // 真实路径，未产出为 null
 *   summary: { scenePath, objectCount, groups, prefabPath, root, layoutPath },
 *   failedStage, logs: [...]                                   // 失败时给出失败节点与日志尾部
 * }
 */

import { JOB_STATUS_ZH, STAGE_STATUS_ZH } from './pipeline.js'

/** 工具返回值 schema：外层结构固定，嵌套报告用 object 描述（不约束内部键）。 */
export const RUN_PIPELINE_OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'jobId', 'status', 'stages', 'artifacts', 'summary', 'failedStage', 'logs'],
  properties: {
    ok: { type: 'boolean', description: '流水线是否完整跑完（job.status === "done"）' },
    jobId: { type: 'string', description: '本次 job 的 id' },
    status: { type: 'string', description: 'job 状态：done / blocked / failed' },
    stages: { type: 'object', description: '按节点 id（comfy / blender / unity）索引的状态与详情' },
    artifacts: {
      type: 'object',
      description: '产物真实路径：image / blend / fbx / layout / scene / prefab / textures（没有的为 null）',
    },
    summary: {
      type: 'object',
      description: '场景装配摘要：scenePath / objectCount / groups / prefabPath / root / layoutPath / layoutAxis / texture / materialMapping / geometryMapping',
    },
    failedStage: { type: 'string', description: '失败或被阻塞的节点 id；成功时为空字符串' },
    logs: { type: 'array', items: { type: 'string' }, description: '失败节点的日志尾部（最多 8 行）' },
  },
}

const DESCRIPTION =
  '运行「场景骨架流水线」：ComfyUI 出图 → Blender 生成引擎无关的场景骨架（scenic 声明式场景，带层级 / 光照 / 相机，导出 .blend/.fbx/.glb + layout.json），按顺序逐节点执行。' +
  '默认 dryRun=true：只检查每个节点的前置环境（ComfyUI 是否可达、Blender 是否可执行），返回节点状态与产物占位，不启动任何软件；' +
  'dryRun=false 会真实执行：向 ComfyUI 提交工作流并等待出图（可能 1-3 分钟）、启动 Blender headless 生成并导出场景骨架。' +
  '开启 enableUnityAdapter 配置后，会额外追加 Unity 装配节点（batchmode 按 layout 生成 .unity 场景）。' +
  '成功时返回结构化摘要：summary.objectCount（装配对象数）、summary.groups（分组名）、summary.layoutAxis（坐标系）。' +
  '只有用户明确要求真实生成时才传 dryRun:false。需要真实环境状态时先调用 check_environment。'

const EMPTY_SUMMARY = {
  scenePath: null,
  objectCount: null,
  groups: [],
  prefabPath: null,
  root: null,
  layoutPath: null,
  layoutAxis: null,
  texture: null,
  materialMapping: null,
  geometryMapping: null,
}

/** 把工具结果渲染成模型可读的文本。 */
function renderResult(value) {
  const lines = []
  const stages = value?.stages ?? {}
  lines.push(
    `[场景骨架流水线] ${value?.jobId ?? '?'} — ${JOB_STATUS_ZH[value?.status] ?? value?.status ?? '?'}`,
  )
  for (const id of ['comfy', 'blender', 'unity']) {
    const stage = stages[id]
    if (!stage) continue
    const status = `${STAGE_STATUS_ZH[stage.status] ?? stage.status}(${stage.status})`
    lines.push(`- ${stage.label || id}：${status} — ${stage.detail ?? ''}`)
  }

  const artifacts = value?.artifacts ?? {}
  const artifactLines = Object.entries(artifacts)
    .filter(([, path]) => typeof path === 'string' && path !== '')
    .map(([kind, path]) => `${kind}: ${path}`)
  if (artifactLines.length > 0) {
    lines.push('产物：')
    for (const line of artifactLines) lines.push(`- ${line}`)
  }

  const summary = value?.summary ?? {}
  if (summary.scenePath) {
    lines.push(
      `场景摘要：${summary.scenePath}，根节点 ${summary.root ?? '?'}，` +
        `${Array.isArray(summary.groups) ? summary.groups.join(' / ') : ''}，` +
        `${summary.objectCount ?? '?'} 个对象` +
        (summary.prefabPath ? `，prefab ${summary.prefabPath}` : ''),
    )
  }
  if (value?.failedStage) lines.push(`失败节点：${value.failedStage}`)
  if (Array.isArray(value?.logs) && value.logs.length > 0) {
    lines.push('日志尾部：')
    for (const line of value.logs.slice(-8)) lines.push(`  ${line}`)
  }
  return lines.join('\n')
}

/**
 * 把 job 快照整理成工具返回值。
 *
 * @param {object} job - PipelineEngine.run() 的返回值。
 * @returns {object} 模型可读的结构化报告
 */
export function toToolResult(job) {
  const stages = {}
  for (const stage of Array.isArray(job?.stages) ? job.stages : []) {
    stages[stage.id] = { status: stage.status, detail: stage.detail ?? '', label: stage.label ?? '' }
  }
  return {
    ok: job?.status === 'done',
    jobId: job?.id ?? '',
    status: job?.status ?? 'failed',
    stages,
    artifacts: job?.artifacts ?? {
      image: null,
      blend: null,
      fbx: null,
      glb: null,
      layout: null,
      scene: null,
      prefab: null,
      textures: null,
    },
    summary: job?.summary ?? EMPTY_SUMMARY,
    failedStage: job?.failedStage ?? '',
    logs: Array.isArray(job?.failedLogs) ? job.failedLogs : [],
  }
}

/**
 * 构造 run_scene_pipeline 工具定义。
 *
 * @param {import('./pipeline.js').PipelineEngine} engine - 流水线引擎实例。
 * @returns {object} 可直接交给 ctx.tools.register 的工具定义。
 */
export function createRunPipelineTool(engine) {
  return {
    name: 'run_scene_pipeline',
    description: DESCRIPTION,
    parameters: {
      type: 'object',
      properties: {
        prompt: {
          type: 'string',
          description: '场景描述，例如「一座带台阶的日式庭院，中央有石灯笼」。会作为 ComfyUI 提示词与场景标题。',
        },
        dryRun: {
          type: 'boolean',
          description:
            '默认 true（只做前置检查，不启动软件）。传 false 会真实启动 ComfyUI / Blender / Unity，耗时较长，仅在用户明确要求真实生成时使用。',
        },
      },
      required: ['prompt'],
      additionalProperties: false,
    },
    output: {
      schema: RUN_PIPELINE_OUTPUT_SCHEMA,
      render: (_args, value) => [{ type: 'text', text: renderResult(value) }],
    },
    /**
     * 执行一次流水线，返回结构化报告。
     * @param {{ prompt?: unknown, dryRun?: unknown }} args - 模型参数。
     * @param {{ signal?: AbortSignal }} [_exec] - 宿主执行上下文。
     * @returns {Promise<object>}
     */
    async execute(args = {}, _exec) {
      const job = await engine.run({ prompt: args?.prompt, dryRun: args?.dryRun })
      return toToolResult(job)
    },
  }
}
