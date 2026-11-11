/**
 * ComfyUI executor（阶段 4）：把工作流真正提交给 ComfyUI，轮询结果并下载产物。
 *
 * 流程：
 *   1. 读取工作流 JSON（配置 comfyWorkflowPath 优先，否则用内置 txt2img 模板）；
 *   2. 把 prompt / negative prompt / checkpoint / seed 注入对应节点；
 *   3. POST {comfyUrl}/prompt 提交，拿到 prompt_id；
 *   4. 轮询 GET {comfyUrl}/history/{prompt_id}，直到任务完成或超时；
 *   5. 对每个输出图片调用 GET {comfyUrl}/view 下载到 job 目录。
 *
 * 只依赖 Node 自带 fetch，不 import 任何 @deepseek-ai/* 包。
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const COMFY_POLL_INTERVAL_MS = 1000
export const COMFY_TIMEOUT_MS = 240000

const DEFAULT_WORKFLOW_URL = new URL('../workflows/txt2img.json', import.meta.url)
const DEFAULT_NEGATIVE_PROMPT = 'blurry, low quality, watermark, text, deformed'

function joinUrl(base, path) {
  return `${String(base).replace(/\/+$/, '')}${path}`
}

function fail(message) {
  return new Error(`ComfyUI：${message}`)
}

async function readJsonResponse(res, url) {
  const text = await res.text()
  let data = null
  if (text !== '') {
    try {
      data = JSON.parse(text)
    } catch {
      data = null
    }
  }
  if (!res.ok) {
    const hint = data && typeof data === 'object' ? JSON.stringify(data).slice(0, 600) : text.slice(0, 600)
    throw fail(`请求 ${url} 失败（HTTP ${res.status}）：${hint || '无响应内容'}`)
  }
  return data
}

/** 读取工作流：配置了 comfyWorkflowPath 就用用户的 API 格式工作流，否则用内置模板。 */
export function loadWorkflow(config) {
  const customPath = typeof config?.comfyWorkflowPath === 'string' ? config.comfyWorkflowPath.trim() : ''
  const source = customPath === '' ? DEFAULT_WORKFLOW_URL : customPath
  let parsed
  try {
    parsed = JSON.parse(readFileSync(source, 'utf8'))
  } catch (error) {
    throw fail(
      `工作流 JSON 读取失败（${String(source)}）：${error instanceof Error ? error.message : String(error)}`,
    )
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw fail('工作流 JSON 必须是「节点 id → 节点对象」的 API 格式对象')
  }
  return { workflow: parsed, source: customPath === '' ? '内置 txt2img 模板' : customPath }
}

function nodesOf(workflow) {
  return Object.entries(workflow)
    .filter(([, node]) => node && typeof node === 'object' && typeof node.class_type === 'string')
    .sort(([a], [b]) => a.localeCompare(b, 'en', { numeric: true }))
}

/** 从 /object_info 里找可用的 checkpoint（配置优先）。 */
export async function discoverCheckpoint(base, configured) {
  const configuredName = typeof configured === 'string' ? configured.trim() : ''
  if (configuredName !== '') return configuredName
  const url = joinUrl(base, '/object_info/CheckpointLoaderSimple')
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) })
  const data = await readJsonResponse(res, url)
  const node = data?.CheckpointLoaderSimple
  const spec = node?.input?.required?.ckpt_name
  const list = Array.isArray(spec) ? spec[0] : spec?.options
  const names = Array.isArray(list) ? list.filter(item => typeof item === 'string') : []
  if (names.length === 0) {
    throw fail('没有可用的 checkpoint：请在 ComfyUI 的 models/checkpoints 里放一个模型，或在插件配置里填写 comfyCheckpoint')
  }
  return names[0]
}

/**
 * 把 prompt / negative / checkpoint / seed 注入工作流。
 * 返回注入后的深拷贝（不修改传入对象）。
 */
export function injectWorkflow(workflow, { prompt, negativePrompt, checkpoint, seed }) {
  const next = JSON.parse(JSON.stringify(workflow))
  const nodes = nodesOf(next)
  let positiveFound = false
  let negativeFound = false
  let checkpointFound = false

  for (const [, node] of nodes) {
    if (node.class_type === 'CLIPTextEncode') {
      const title = typeof node._meta?.title === 'string' ? node._meta.title : ''
      const isNegative = /negativ|负向|反向/i.test(title)
      if (isNegative) {
        node.inputs = { ...node.inputs, text: negativePrompt }
        negativeFound = true
      } else if (!positiveFound) {
        node.inputs = { ...node.inputs, text: prompt }
        positiveFound = true
      }
    }
    if (node.class_type === 'CheckpointLoaderSimple' && node.inputs && 'ckpt_name' in node.inputs) {
      node.inputs.ckpt_name = checkpoint
      checkpointFound = true
    }
    if (node.class_type === 'KSampler' && node.inputs && 'seed' in node.inputs) {
      node.inputs.seed = seed
    }
  }

  if (!positiveFound) {
    throw fail('工作流里没有找到 CLIPTextEncode（正向提示词）节点，请检查工作流 JSON')
  }
  if (!checkpointFound) {
    throw fail('工作流里没有找到 CheckpointLoaderSimple 节点，请检查工作流 JSON')
  }
  return next
}

/**
 * 执行 ComfyUI 阶段。
 *
 * @param {{ service: {getConfig: () => object}, jobDir: string, prompt: string, onLog?: (message: string) => void }} input
 * @returns {Promise<{detail: string, artifacts: Array<object>}>}
 */
export async function runComfyStage({ service, jobDir, prompt, onLog }) {
  const config = service.getConfig()
  const base = String(config.comfyUrl || '').trim()
  if (base === '') throw fail('comfyUrl 未配置')
  const log = message => {
    if (typeof onLog === 'function') onLog(message)
  }

  const { workflow, source } = loadWorkflow(config)
  log(`读取工作流：${source}`)
  const checkpoint = await discoverCheckpoint(base, config.comfyCheckpoint)
  log(`使用 checkpoint：${checkpoint}`)
  const negativePrompt =
    typeof config.comfyNegativePrompt === 'string' && config.comfyNegativePrompt.trim() !== ''
      ? config.comfyNegativePrompt.trim()
      : DEFAULT_NEGATIVE_PROMPT

  const injected = injectWorkflow(workflow, {
    prompt,
    negativePrompt,
    checkpoint,
    seed: Math.floor(Math.random() * 1_000_000_000),
  })

  const submitUrl = joinUrl(base, '/prompt')
  const submitRes = await fetch(submitUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ prompt: injected, client_id: 'dsh-scene-skeleton-pipeline' }),
    signal: AbortSignal.timeout(30000),
  })
  const submitted = await readJsonResponse(submitRes, submitUrl)
  const promptId = typeof submitted?.prompt_id === 'string' ? submitted.prompt_id : ''
  if (promptId === '') throw fail('提交工作流后没有拿到 prompt_id')
  log(`已提交：prompt_id=${promptId}`)

  const deadline = Date.now() + COMFY_TIMEOUT_MS
  let entry = null
  while (Date.now() < deadline) {
    const historyUrl = joinUrl(base, `/history/${encodeURIComponent(promptId)}`)
    let history = null
    try {
      const historyRes = await fetch(historyUrl, { signal: AbortSignal.timeout(10000) })
      history = await readJsonResponse(historyRes, historyUrl)
    } catch (error) {
      // 轮询期间的网络抖动不直接失败，继续重试到超时。
      log(`轮询失败：${error instanceof Error ? error.message : String(error)}`)
      await new Promise(resolve => setTimeout(resolve, COMFY_POLL_INTERVAL_MS))
      continue
    }
    const record = history?.[promptId]
    if (record) {
      const statusStr = record.status?.status_str
      if (statusStr === 'error') {
        const messages = Array.isArray(record.status?.messages) ? record.status.messages : []
        throw fail(`工作流执行失败：${JSON.stringify(messages).slice(0, 800)}`)
      }
      if (record.status?.completed === true && statusStr !== 'error') {
        entry = record
        break
      }
    }
    await new Promise(resolve => setTimeout(resolve, COMFY_POLL_INTERVAL_MS))
  }
  if (entry === null) {
    throw fail(`等待出图超时（${Math.round(COMFY_TIMEOUT_MS / 1000)} 秒）`)
  }

  const images = []
  for (const node of Object.values(entry.outputs || {})) {
    for (const image of node?.images || []) {
      if (image && typeof image.filename === 'string' && image.filename !== '') images.push(image)
    }
  }
  if (images.length === 0) throw fail('工作流执行完成，但没有输出图片（请检查是否有 SaveImage 节点）')

  const comfyDir = join(jobDir, 'comfy')
  mkdirSync(comfyDir, { recursive: true })
  const artifacts = []
  for (const image of images) {
    const viewUrl = joinUrl(
      base,
      `/view?filename=${encodeURIComponent(image.filename)}&subfolder=${encodeURIComponent(image.subfolder || '')}&type=${encodeURIComponent(image.type || 'output')}`,
    )
    const res = await fetch(viewUrl, { signal: AbortSignal.timeout(30000) })
    if (!res.ok) throw fail(`下载图片 ${image.filename} 失败（HTTP ${res.status}）`)
    const buffer = Buffer.from(await res.arrayBuffer())
    const path = join(comfyDir, image.filename)
    writeFileSync(path, buffer)
    artifacts.push({
      kind: 'image',
      path,
      filename: image.filename,
      bytes: buffer.length,
      checkpoint,
      promptId,
    })
    log(`下载图片：${image.filename}（${buffer.length} 字节）`)
  }

  return {
    detail: `ComfyUI 出图完成：${artifacts.length} 张（${checkpoint}，prompt_id=${promptId}）`,
    artifacts,
  }
}
