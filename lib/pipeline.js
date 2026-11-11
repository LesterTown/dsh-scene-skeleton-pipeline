/**
 * 流水线引擎（阶段 7）：ComfyUI → Blender 两节点顺序执行，终点是引擎无关的场景骨架。
 * Unity 装配降级为可选适配器：配置 enableUnityAdapter=true 时才动态追加 Unity 节点。
 *
 * - dryRun: true（默认）：只做前置环境检查，不启动任何软件，产物是占位信息。
 * - dryRun: false：真正执行：
 *     1. ComfyUI executor：提交工作流、轮询 /history、下载图片；
 *     2. Blender executor：headless 运行 scenic spec（或 legacy build_scene.py），
 *        在 Blender 内建好层级 / 光照 / 相机，导出 .blend / .fbx / .glb + layout.json；
 *     3.（可选）Unity adapter：batchmode 按 layout.json 装配 .unity 场景。
 *
 * 数据结构（给工具 / 设置页 / 后续阶段共用）：
 *   job = {
 *     id, status: 'queued' | 'running' | 'done' | 'blocked' | 'failed',
 *     prompt, dryRun, jobDir, createdAt, startedAt, finishedAt, error?,
 *     stages: [{ id, label, status, detail, logs, startedAt, finishedAt, artifacts }],
 *   }
 *   stage.status: 'pending' | 'running' | 'ok' | 'blocked' | 'skipped' | 'failed'
 *   stage.report: 结构化阶段报告（Blender 的 layout 摘要）
 *   job.artifacts: { image, blend, fbx, glb, layout, ... }（真实路径，dry-run 时为 null）
 *   job.summary: { root, groups, objectCount, layoutAxis, ... }（Blender 装配结果）
 */

import { mkdirSync } from 'node:fs'
import { join } from 'node:path'

import { runBlenderStage } from './executors/blender.js'
import { runComfyStage } from './executors/comfy.js'
import { runUnityStage } from '../adapters/unity/unity.js'

const MAX_PROMPT_LENGTH = 4000
const MAX_STAGE_LOGS = 60

/** 流水线基础节点（阶段 7）：ComfyUI → Blender，终点是 Blender 导出的引擎无关骨架。 */
export const BASE_STAGES = [
  {
    id: 'comfy',
    label: 'ComfyUI 出图',
    needs: 'comfy',
    kind: 'image',
    description: '用 ComfyUI 生成参考图 / 贴图；dryRun:false 时会真实提交工作流。',
  },
  {
    id: 'blender',
    label: 'Blender 生成场景骨架',
    needs: 'blender',
    kind: 'mesh',
    description: '用 Blender headless 生成场景骨架（scenic 声明式场景），导出 .blend / .fbx / .glb 并写出 layout.json；dryRun:false 时真实启动 Blender。',
  },
]

/** Unity 装配适配器（可选，阶段 7 降级）：仅 enableUnityAdapter 时动态追加。 */
export const UNITY_ADAPTER_STAGE = {
  id: 'unity',
  label: 'Unity 生成场景',
  needs: 'unity',
  kind: 'scene',
  description: '按 layout.json 在 Unity 里装配 Root + 分组 + 物件 + 光照 + 相机并保存 .unity 场景；仅在配置 enableUnityAdapter=true 时启用。',
}

/**
 * 按配置解析本阶段要执行的节点：默认 ComfyUI → Blender（引擎无关骨架），
 * 开启 enableUnityAdapter 时才追加 Unity 装配节点。
 */
export function resolveStages(config) {
  return config?.enableUnityAdapter === true ? [...BASE_STAGES, UNITY_ADAPTER_STAGE] : BASE_STAGES
}

/** 每个节点对应的真实执行器。 */
export const STAGE_EXECUTORS = {
  comfy: runComfyStage,
  blender: runBlenderStage,
  unity: runUnityStage,
}

/** 状态 → 中文，供日志与工具渲染共用。 */
export const STAGE_STATUS_ZH = {
  pending: '等待',
  running: '执行中',
  ok: '正常',
  blocked: '被阻塞',
  skipped: '跳过',
  failed: '失败',
}

export const JOB_STATUS_ZH = {
  queued: '排队中',
  running: '执行中',
  done: '已完成',
  blocked: '被阻塞',
  failed: '失败',
}

export const DRY_RUN_ARTIFACT_NOTE = 'dry-run 占位，dryRun:false 才会产出真实文件'

/** stage.artifacts 的 kind → job.artifacts 的键。 */
const ARTIFACT_KIND_MAP = {
  image: 'image',
  blend: 'blend',
  mesh: 'fbx',
  glb: 'glb',
  layout: 'layout',
  scene: 'scene',
  prefab: 'prefab',
  textures: 'textures',
}

/** 把各节点的产物汇总成 { image, blend, fbx, glb, layout, scene, prefab }（没有的键为 null）。 */
export function flattenArtifacts(stages) {
  const result = {
    image: null,
    blend: null,
    fbx: null,
    glb: null,
    layout: null,
    scene: null,
    prefab: null,
    textures: null,
  }
  for (const stage of Array.isArray(stages) ? stages : []) {
    for (const artifact of Array.isArray(stage?.artifacts) ? stage.artifacts : []) {
      const key = ARTIFACT_KIND_MAP[artifact?.kind]
      if (key !== undefined && result[key] === null && typeof artifact.path === 'string' && artifact.path !== '') {
        result[key] = artifact.path
      }
    }
  }
  return result
}

/**
 * 汇总场景装配结果：优先用 Unity 的结构化报告，其次退回 Blender 的 layout 摘要。
 * dry-run / 未执行到 Unity 时返回 null。
 */
export function buildJobSummary(stages) {
  const list = Array.isArray(stages) ? stages : []
  const unity = list.find(stage => stage?.id === 'unity')
  const blenderStage = list.find(stage => stage?.id === 'blender')
  const blenderReport = blenderStage?.report ?? null
  if (unity && unity.report) {
    return {
      scenePath: unity.report.scenePath ?? null,
      objectCount: unity.report.objectCount ?? null,
      groups: Array.isArray(unity.report.groups) ? unity.report.groups : [],
      prefabPath: unity.report.prefabPath ?? null,
      root: unity.report.root ?? null,
      layoutPath: unity.report.layoutPath ?? null,
      layoutAxis: unity.report.layoutAxis ?? unity.report.axis ?? null,
      texture: unity.report.texture ?? null,
      materialMapping: unity.report.materialMapping ?? blenderReport?.materialMapping ?? null,
      geometryMapping: unity.report.geometryMapping ?? blenderReport?.geometryMapping ?? null,
    }
  }
  const blender = blenderStage
  if (blender && blender.report) {
    return {
      scenePath: null,
      objectCount: blender.report.objectCount ?? null,
      groups: Array.isArray(blender.report.groups) ? blender.report.groups : [],
      prefabPath: null,
      root: blender.report.root ?? null,
      layoutPath: blender.report.layoutPath ?? null,
      layoutAxis: blender.report.axis ?? null,
      texture: blender.report.texture ?? null,
      materialMapping: blender.report.materialMapping ?? null,
      geometryMapping: blender.report.geometryMapping ?? null,
    }
  }
  return null
}

function isoNow() {
  return new Date().toISOString()
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error)
}

/**
 * 流水线引擎。
 *
 * 只依赖 pipeline-service 的 checkAll() 与 getConfig()；
 * 真实执行细节在各 executor 里，调度与状态机保持稳定。
 */
export class PipelineEngine {
  /**
   * @param {import('./service.js').PipelineService} service - pipeline-service 实例。
   * @param {{ maxJobs?: number, onLog?: (message: string) => void }} [options] - maxJobs 只保留最近 N 个 job（默认 20）。
   */
  constructor(service, options = {}) {
    this.service = service
    this.maxJobs = Number.isInteger(options.maxJobs) && options.maxJobs > 0 ? options.maxJobs : 20
    this.onLog = typeof options.onLog === 'function' ? options.onLog : null
    /** @type {Map<string, object>} */
    this.jobs = new Map()
    this.lastJobId = null
    this.counter = 0
  }

  log(message) {
    if (this.onLog) {
      try {
        this.onLog(message)
      } catch {
        /* 日志失败不影响流水线 */
      }
    }
  }

  /** 给设置页 / 工具描述用的静态信息。 */
  describe() {
    return {
      dryRunOnly: false,
      realExecution: true,
      outputDir: this.service.getOutputDir ? this.service.getOutputDir() : '',
      stages: resolveStages(this.service.getConfig()).map(stage => ({
        id: stage.id,
        label: stage.label,
        needs: stage.needs,
        kind: stage.kind,
        description: stage.description,
      })),
    }
  }

  /** 最近一次运行的 job（没有则 null）。 */
  getLastJob() {
    return this.lastJobId === null ? null : this.getJob(this.lastJobId)
  }

  /** 按 id 取 job（深拷贝，避免调用方改到内部状态）。 */
  getJob(id) {
    const job = this.jobs.get(id)
    return job === undefined ? null : clone(job)
  }

  /** 最近的 job 列表，新的在前。 */
  listJobs() {
    return [...this.jobs.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map(job => clone(job))
  }

  /**
   * 运行一次流水线。
   *
   * @param {{ prompt?: unknown, dryRun?: unknown }} [input]
   * @returns {Promise<object>} job 快照（永远返回结构化结果，参数非法时 job.status === 'failed'）。
   */
  async run(input = {}) {
    const prompt = typeof input.prompt === 'string' ? input.prompt.trim() : ''
    const dryRun = input.dryRun !== false
    const stages = resolveStages(this.service.getConfig())
    const job = {
      id: `job-${Date.now().toString(36)}-${(this.counter += 1)}`,
      status: 'queued',
      prompt,
      dryRun,
      jobDir: '',
      createdAt: isoNow(),
      startedAt: '',
      finishedAt: '',
      stages: stages.map(stage => ({
        id: stage.id,
        label: stage.label,
        status: 'pending',
        detail: '等待前序节点',
        logs: [],
        startedAt: '',
        finishedAt: '',
        artifacts: [],
      })),
    }

    const fail = error => {
      job.status = 'failed'
      job.error = error
      job.finishedAt = isoNow()
      return this.remember(job)
    }

    if (prompt === '') return fail('prompt 不能为空：请描述要生成的场景')
    if (prompt.length > MAX_PROMPT_LENGTH) {
      return fail(`prompt 过长（${prompt.length} 字符，上限 ${MAX_PROMPT_LENGTH}）`)
    }

    try {
      const { environment } = await this.service.checkAll()
      job.environment = environment
      job.status = 'running'
      job.startedAt = isoNow()

      if (!dryRun) {
        const outputDir = this.service.getOutputDir ? this.service.getOutputDir() : ''
        if (!outputDir) return fail('没有可用的输出目录：请配置 outputDir')
        job.jobDir = join(outputDir, 'jobs', job.id)
        mkdirSync(job.jobDir, { recursive: true })
        this.log(`[pipeline ${job.id}] 真实执行，产物目录：${job.jobDir}`)
      }

      let blockedBy = null
      /** 已完成节点的真实产物，供后续节点使用。 */
      const previousArtifacts = []

      for (let index = 0; index < job.stages.length; index += 1) {
        const stage = job.stages[index]
        const definition = stages[index]
        stage.startedAt = isoNow()
        stage.status = 'running'
        stage.detail = dryRun ? '检查环境…' : '执行中…'

        if (blockedBy !== null) {
          stage.status = 'skipped'
          stage.detail = `前序节点「${blockedBy}」未完成，跳过`
          stage.logs.push(`阶段 ${definition.id} 跳过：${stage.detail}`)
          if (stage.logs.length > MAX_STAGE_LOGS) stage.logs.shift()
          stage.finishedAt = isoNow()
          continue
        }

        const dependency = environment[definition.needs]
        if (dependency.status !== 'ok') {
          stage.status = 'blocked'
          stage.detail = `依赖未就绪（${dependency.status}）：${dependency.detail}`
          // 阻塞也要留下可读日志：工具返回值里的 logs 就是失败原因的第一现场。
          stage.logs.push(`阶段 ${definition.id} 阻塞：${stage.detail}`)
          if (stage.logs.length > MAX_STAGE_LOGS) stage.logs.shift()
          stage.finishedAt = isoNow()
          blockedBy = definition.label
          continue
        }

        if (dryRun) {
          stage.status = 'ok'
          stage.detail = `dry-run：前置检查通过${dependency.path ? `（${dependency.path}）` : ''}，未实际执行`
          stage.artifacts = [{ kind: definition.kind, path: '', note: DRY_RUN_ARTIFACT_NOTE }]
          stage.finishedAt = isoNow()
          continue
        }

        const executor = STAGE_EXECUTORS[definition.id]
        if (typeof executor !== 'function') {
          stage.status = 'failed'
          stage.detail = `没有 ${definition.id} executor`
          stage.finishedAt = isoNow()
          blockedBy = definition.label
          continue
        }

        this.log(`[pipeline ${job.id}] ${definition.id} 开始`)
        try {
          const result = await executor({
            service: this.service,
            jobDir: job.jobDir,
            prompt: job.prompt,
            artifacts: previousArtifacts.slice(),
            onLog: message => {
              stage.logs.push(message)
              if (stage.logs.length > MAX_STAGE_LOGS) stage.logs.shift()
              this.log(`[pipeline ${job.id}] ${definition.id}: ${message}`)
            },
          })
          stage.status = 'ok'
          stage.detail = result?.detail || '完成'
          stage.artifacts = Array.isArray(result?.artifacts) ? result.artifacts : []
          stage.report = result?.report ?? null
          previousArtifacts.push(...stage.artifacts)
          this.log(`[pipeline ${job.id}] ${definition.id} 完成`)
        } catch (error) {
          stage.status = 'failed'
          stage.detail = errorMessage(error)
          stage.logs.push(`阶段 ${definition.id} 失败：${stage.detail}`)
          if (stage.logs.length > MAX_STAGE_LOGS) stage.logs.shift()
          stage.finishedAt = isoNow()
          blockedBy = definition.label
          this.log(`[pipeline ${job.id}] ${definition.id} 失败：${stage.detail}`)
        }
        stage.finishedAt = isoNow()
      }

      const allOk = job.stages.every(stage => stage.status === 'ok')
      job.status = allOk
        ? 'done'
        : job.stages.some(stage => stage.status === 'blocked')
          ? 'blocked'
          : 'failed'
      job.artifacts = flattenArtifacts(job.stages)
      job.summary = buildJobSummary(job.stages)
      if (!allOk) {
        const firstBad = job.stages.find(
          stage => stage.status === 'blocked' || stage.status === 'failed',
        )
        job.error = firstBad ? `${firstBad.label}：${firstBad.detail}` : '流水线未完成'
        job.failedStage = firstBad ? firstBad.id : null
        job.failedLogs = firstBad && Array.isArray(firstBad.logs) ? firstBad.logs.slice(-8) : []
      }
      job.finishedAt = isoNow()
      return this.remember(job)
    } catch (error) {
      return fail(`流水线执行异常：${errorMessage(error)}`)
    }
  }

  /** 存 job 并按 maxJobs 淘汰最旧的。 */
  remember(job) {
    this.jobs.set(job.id, job)
    this.lastJobId = job.id
    while (this.jobs.size > this.maxJobs) {
      const oldestKey = this.jobs.keys().next().value
      this.jobs.delete(oldestKey)
    }
    return clone(job)
  }
}
