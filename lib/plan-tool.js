/**
 * plan_scene_layout：调模型把「文字描述」规划成精确布局 plan（JSON）。
 *
 * 这是 sceneSource='llm' 的入口：模型只负责出布局数据（id/type/position/size），
 * 几何由 Blender 侧按类型程序化生成，布局再经 validate_layout 校验后才装配。
 *
 * 设计参考 SceneGenAgent 的结构化布局思路（先出对象清单与坐标，再渲染），
 * 以及 blender-orchestrator 的「尺寸 + 碰撞约束」做法（尺寸范围、禁止重叠/悬浮）。
 *
 * 工具输出（JSON schema 见 PLAN_OUTPUT_SCHEMA）：
 *   ok=true  → plan 已通过校验（可直接写进 layoutObjects）
 *   ok=false → errors 列出具体原因、rawText 是模型原文，调用方可让模型重试
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

import {
  ASSET_LIBRARY,
  DEFAULT_PLAN_BOUNDS,
  PLAN_GROUP_BY_TYPE,
  PLAN_TYPES,
  normalizePlan,
  planSummary,
  validatePlanDetailed,
} from './layout.js'

export const PLAN_OUTPUT_SCHEMA = {
  type: 'object',
  description: '布局规划结果：ok 表示 plan 是否通过校验',
  properties: {
    ok: { type: 'boolean', description: 'plan 是否通过校验' },
    plan: {
      type: 'object',
      description: '通过校验的布局计划：sceneName / bounds / objects（每项含 id/type/position/size）',
      properties: {
        sceneName: { type: 'string' },
        bounds: {
          type: 'object',
          properties: { width: { type: 'number' }, depth: { type: 'number' } },
        },
        objects: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              type: { type: 'string', enum: PLAN_TYPES },
              position: { type: 'array', items: { type: 'number' } },
              size: { type: 'array', items: { type: 'number' } },
              rotation: { type: 'array', items: { type: 'number' } },
              group: {
                type: 'string',
                enum: [...new Set(ASSET_LIBRARY.assets.map(entry => entry.category))],
              },
            },
            required: ['id', 'type', 'position', 'size'],
            additionalProperties: true,
          },
        },
      },
      required: ['objects'],
      additionalProperties: true,
    },
    errors: { type: 'array', items: { type: 'string' }, description: '校验失败的具体原因（中文）' },
    attempts: { type: 'number', description: '实际尝试次数（含首次；≤3）' },
    validation: {
      type: 'object',
      description: '最后一次校验的结构化结果：{ok, errors:[{rule,message,objects}]}',
      properties: {
        ok: { type: 'boolean' },
        errors: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              rule: { type: 'string' },
              message: { type: 'string' },
              objects: { type: 'array', items: { type: 'string' } },
            },
            additionalProperties: true,
          },
        },
      },
      additionalProperties: true,
    },
    savedPath: { type: 'string', description: '给了 savePath 时写盘的绝对路径' },
    model: {
      type: 'object',
      properties: { provider: { type: 'string' }, model: { type: 'string' } },
      required: ['provider', 'model'],
    },
    rawText: { type: 'string', description: '模型原始输出（失败时便于排查/重试）' },
  },
  required: ['ok', 'errors'],
  additionalProperties: true,
}

/** 资产库 → 给模型看的 type 清单（名称、分组、尺寸范围、默认尺寸、可放置面）。 */
export function buildTypeCatalog() {
  return ASSET_LIBRARY.assets.map(entry => {
    const { height, footprint } = entry.sizeRange
    const defaults = entry.defaultSize.map(value => Number(value)).join('×')
    const places = entry.placement.join('/')
    return `  - ${entry.type}（${entry.label}，${entry.category}）：高 ${height[0]}–${height[1]}m、` +
      `平面 ${footprint[0]}–${footprint[1]}m、默认尺寸 ${defaults}、可放置 ${places}`
  }).join('\n')
}

const SYSTEM_PROMPT = `你是场景布局规划器。给定用户的场景描述，输出一份精确的布局计划 JSON。

只输出 JSON，不要任何解释文字。格式：
{
  "sceneName": "英文短名",
  "bounds": {"width": 24, "depth": 20},
  "objects": [
    {"id": "column_01", "type": "column", "position": [x, 0, z], "size": [sx, sy, sz]}
  ]
}

规则：
- 坐标系：Unity Y-up，单位米；原点在场景中心，x 向右、z 向前。
- position 是物体底面中心，y 必须为 0（贴地）；size 是完整尺寸 [宽, 高, 深]。
- 所有对象必须落在 bounds 内：|x| + sx/2 ≤ width/2，|z| + sz/2 ≤ depth/2。
- 对象之间不能重叠（平面投影），彼此至少留 0.3 米间距。
- id 唯一、snake_case，例如 column_01 / tree_02 / wall_01。
- type 只能从下面的资产库清单里选，**不能自创 type**（分组由 type 自动决定，不需要写 group）：
${buildTypeCatalog()}
- 数量：严格按描述生成——描述里点到的对象全部生成，**不要额外添加未提到的对象**；只有描述非常笼统（如「一座庭院」）时才补到 6–20 个。
- 布局要有构图：例如中央喷泉或主建筑、四周环绕柱子或树、留出通道。
- 只输出 JSON 本身。`

/** 最多尝试次数（首次 + 2 次重试）。 */
export const MAX_PLAN_ATTEMPTS = 3

function buildUserPrompt(description, width, depth) {
  return `场景描述：${description}\n场景范围：宽 ${width} 米、深 ${depth} 米。请输出布局计划 JSON。`
}

/** 第二次及以后重试时，把上一轮校验错误反馈给模型。 */
function buildRetryPrompt(description, width, depth, errors) {
  const lines = errors.map(error => `- ${error.message}`)
  return `${buildUserPrompt(description, width, depth)}

注意：上一次输出未通过校验，请修正以下问题后**重新输出完整 JSON**（不要只输出改动部分）：
${lines.join('\n')}`
}

/** 从模型输出里提取 JSON（容忍 ```json 围栏与前后说明文字）。 */
export function extractJson(text) {
  const raw = typeof text === 'string' ? text : ''
  const candidates = []
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i)
  if (fenced) candidates.push(fenced[1])
  candidates.push(raw)
  for (const candidate of candidates) {
    const start = candidate.indexOf('{')
    if (start < 0) continue
    let depth = 0
    let inString = false
    let escaped = false
    for (let index = start; index < candidate.length; index += 1) {
      const char = candidate[index]
      if (inString) {
        if (escaped) escaped = false
        else if (char === '\\') escaped = true
        else if (char === '"') inString = false
        continue
      }
      if (char === '"') {
        inString = true
        continue
      }
      if (char === '{') depth += 1
      if (char === '}') {
        depth -= 1
        if (depth === 0) {
          try {
            return JSON.parse(candidate.slice(start, index + 1))
          } catch {
            break
          }
        }
      }
    }
  }
  return null
}

function resolveSavePath(savePath) {
  if (typeof savePath !== 'string' || savePath.trim() === '') return null
  const raw = savePath.trim()
  return raw.startsWith('~') ? join(homedir(), raw.slice(1)) : raw
}

/** 渲染给模型看的摘要文本。 */
export function renderPlanResult(value) {
  if (!value || value.ok !== true) {
    const errors = Array.isArray(value?.errors) && value.errors.length > 0 ? value.errors : ['未知原因']
    return `布局规划失败：\n- ${errors.join('\n- ')}`
  }
  const summary = planSummary(value.plan)
  const lines = [
    `布局规划成功：${summary.objectCount} 个对象，场景 ${summary.sceneName}`,
    `范围：${summary.bounds.width}×${summary.bounds.depth} 米，分组 ${summary.groups.join(' / ')}`,
    '对象：',
  ]
  for (const object of value.plan.objects.slice(0, 30)) {
    const [x, y, z] = object.position
    const [sx, sy, sz] = object.size
    lines.push(`- ${object.id}（${object.type}）位置 (${x}, ${y}, ${z}) 尺寸 (${sx}×${sy}×${sz})`)
  }
  if (value.plan.objects.length > 30) lines.push(`… 其余 ${value.plan.objects.length - 30} 个对象省略`)
  if (value.savedPath) lines.push(`已写入：${value.savedPath}`)
  return lines.join('\n')
}

/**
 * 创建 plan_scene_layout 工具定义。
 *
 * @param {{ ctx: object, service: { getConfig: () => object } }} input
 * @returns {object} ToolDefinition（纯对象，直接交给 ctx.tools.register）
 */
export function createPlanSceneLayoutTool({ ctx, service }) {
  return {
    name: 'plan_scene_layout',
    description:
      '把文字场景描述规划成精确布局 JSON（plan）：每个对象含 id / type / position（Unity Y-up，底面中心）/ size（完整尺寸）。' +
      '结果经结构 + 物理校验（尺寸范围 / 边界 / 地面穿透 / 悬浮 / 碰撞 / 支撑）；不通过时自动把错误反馈给模型重试，最多 3 次尝试。' +
      '可直接用于 sceneSource=llm 的流水线（写进 layoutObjects）。只做规划，不启动 Blender。',
    parameters: {
      type: 'object',
      properties: {
        sceneDescription: {
          type: 'string',
          description: '场景的文字描述，例如「一座中式庭院，中央有喷泉，四周环绕石柱和松树」',
        },
        savePath: {
          type: 'string',
          description: '可选：把生成的 plan JSON 写到这个路径（相对路径或 ~ 开头），便于之后填进 layoutObjects',
        },
        width: {
          type: 'number',
          description: '可选：场景宽度（米），默认取插件配置 scenicWidth',
        },
        depth: {
          type: 'number',
          description: '可选：场景深度（米），默认取插件配置 scenicDepth',
        },
      },
      required: ['sceneDescription'],
      additionalProperties: false,
    },
    output: {
      schema: PLAN_OUTPUT_SCHEMA,
      render: (args, value) => [{ type: 'text', text: renderPlanResult(value) }],
    },
    async execute(args) {
      const description = typeof args?.sceneDescription === 'string' ? args.sceneDescription.trim() : ''
      if (description === '') throw new Error('sceneDescription 不能为空：请描述要生成的场景')

      const llm = ctx?.get?.('llm') ?? ctx?.llm
      if (!llm || typeof llm.stream !== 'function') {
        throw new Error('当前宿主没有可用的 llm 服务，无法规划布局（请在 DSH 会话里使用该工具）')
      }
      const selection = ctx?.get?.('agentDefaultModel')?.currentSelection?.() ?? null
      const provider = typeof selection?.provider === 'string' ? selection.provider : ''
      const model = typeof selection?.model === 'string' ? selection.model : ''
      if (provider === '' || model === '') {
        throw new Error('没有配置默认模型（agentDefaultModel.currentSelection 为空），请先在设置里选择模型')
      }

      const config = service.getConfig()
      const width = Number.isFinite(args?.width) && args.width > 0 ? args.width : config.scenicWidth
      const depth = Number.isFinite(args?.depth) && args.depth > 0 ? args.depth : config.scenicDepth
      const modelInfo = { provider, model }

      const validationOptions = config.layoutValidation
      const maxAttempts = MAX_PLAN_ATTEMPTS
      let validation = { ok: false, errors: [{ rule: 'schema', message: '尚未生成', objects: [] }] }
      let lastText = ''
      let plan = null

      for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        const userText =
          attempt === 1
            ? buildUserPrompt(description, width, depth)
            : buildRetryPrompt(description, width, depth, validation.errors)
        let text = ''
        try {
          const stream = llm.stream({
            provider,
            model,
            system: SYSTEM_PROMPT,
            messages: [{ role: 'user', content: [{ type: 'text', text: userText }] }],
            temperature: 0.3,
            maxTokens: 8000,
          })
          for await (const chunk of stream) {
            if (chunk && chunk.type === 'text-delta' && typeof chunk.text === 'string') {
              text += chunk.text
            } else if (chunk && chunk.type === 'block-start' && chunk.block?.type === 'text') {
              // 有些 provider 用 block-start 承载文本块，这里兼容一下
              text += chunk.block.text ?? ''
            }
          }
        } catch (error) {
          return {
            ok: false,
            errors: [`模型调用失败（第 ${attempt} 次）：${error instanceof Error ? error.message : String(error)}`],
            attempts: attempt,
            model: modelInfo,
          }
        }
        lastText = text

        const parsed = extractJson(text)
        if (!parsed) {
          validation = {
            ok: false,
            errors: [{ rule: 'schema', message: '模型输出里没有找到合法的 JSON（需要 {sceneName, bounds, objects} 结构）', objects: [] }],
          }
          continue
        }

        const candidate = normalizePlan(parsed)
        candidate.bounds = {
          width: Number.isFinite(parsed?.bounds?.width) && parsed.bounds.width > 0 ? parsed.bounds.width : width,
          depth: Number.isFinite(parsed?.bounds?.depth) && parsed.bounds.depth > 0 ? parsed.bounds.depth : depth,
        }
        validation = validatePlanDetailed(candidate, validationOptions)
        if (validation.ok) {
          plan = candidate
          const result = { ok: true, plan, errors: [], attempts: attempt, validation, model: modelInfo }
          const target = resolveSavePath(args?.savePath)
          if (target !== null) {
            mkdirSync(dirname(target), { recursive: true })
            writeFileSync(target, `${JSON.stringify(plan, null, 2)}\n`, 'utf8')
            result.savedPath = target
          }
          return result
        }
      }

      return {
        ok: false,
        errors: validation.errors.map(error => error.message),
        attempts: maxAttempts,
        validation,
        model: modelInfo,
        rawText: lastText.slice(0, 4000),
      }
    },
  }
}

export { DEFAULT_PLAN_BOUNDS }
