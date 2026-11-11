/**
 * Blender executor（阶段 6）：真正启动 Blender headless，生成场景骨架并写出 layout.json。
 *
 * 两种模式（配置 blenderSceneMode）：
 *   scenic（默认）：用 scenic-bpy 声明式 spec（lib/scripts/scenes/courtyard.py）编译出场景，
 *     在 Blender 内建好 Empty 层级（root + 语义分组）、光照 / 世界背景 / 相机，导出
 *     .blend（完整场景）+ .fbx（保留 Empty 层级，供 Unity 装配）+ .glb（引擎无关备份）
 *     + layout.json（语义分组 Terrain / Buildings / Props）。
 *     调用：blender --background --factory-startup --python lib/scripts/run_scenic.py
 *           -- <spec.py> <out.blend> <out.glb> <out.fbx> <out/layout.json> '<params-json>'
 *     scenic-bpy 需装进 Blender 自带 Python（pip install --user scenic-bpy，见 requirements-scenic.txt）。
 *     注：Unity 2022.3 没有内置 glTF 导入器，装配用 .fbx；.glb 作为引擎就绪产物一并保留。
 *   legacy：旧的 build_scene.py（固定体块 + 参考图平面，.blend/.fbx + layout.json）。
 *     调用：blender --background --factory-startup --python lib/scripts/build_scene.py -- <spec.json>
 *
 * 只检查可执行文件存在，真正执行是阶段 4 才允许的（用户明确要求接入真实软件）。
 */

import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { checkBlender } from '../detect.js'
import { layoutSummary, normalizeLayout, normalizePlan, validateLayout, validatePlan, validatePlanDetailed } from '../layout.js'
import { runProcess } from './process.js'

export const BLENDER_TIMEOUT_MS = 180000
// 开启贴图时每个对象要单独渲染+推理，整体预算放宽到 30 分钟（对象数还有 12 个上限）。
const TEXTURE_RUN_TIMEOUT_MS = 1_800_000
const LEGACY_SCRIPT_URL = new URL('../scripts/build_scene.py', import.meta.url)
const SCENIC_RUNNER_URL = new URL('../scripts/run_scenic.py', import.meta.url)
const SCENIC_COURTYARD_URL = new URL('../scripts/scenes/courtyard.py', import.meta.url)
const PBR_WORKFLOW_URL = new URL('../workflows/pbr-superpbr.json', import.meta.url)
const PBR_LITE_WORKFLOW_URL = new URL('../workflows/pbr-superpbr-lite.json', import.meta.url)

function tail(text, limit) {
  const value = typeof text === 'string' ? text.trim() : ''
  return value.length <= limit ? value : `…${value.slice(value.length - limit)}`
}

function parseResultLine(stdout) {
  const lines = String(stdout || '').split(/\r?\n/)
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim()
    if (line.startsWith('DSH_BLENDER_RESULT:')) {
      try {
        return JSON.parse(line.slice('DSH_BLENDER_RESULT:'.length))
      } catch {
        return null
      }
    }
  }
  return null
}

function assertFile(path, label) {
  if (!existsSync(path)) throw new Error(`Blender 未生成${label}：${path}`)
  const size = statSync(path).size
  if (!Number.isFinite(size) || size <= 0) throw new Error(`Blender 生成的${label}为空文件：${path}`)
  return size
}

/** prompt → 稳定 seed（scenic spec 用）。 */
function hashSeed(prompt) {
  const text = typeof prompt === 'string' ? prompt : ''
  if (text.trim() === '') return 1
  let hash = 2166136261
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0) % 100000 + 1
}

/** 读 layout.json 并校验（scenic 与 legacy 共用同一契约）。 */
function readLayout(layoutPath) {  const layoutBytes = assertFile(layoutPath, 'layout.json 布局文件')
  let layout
  try {
    layout = JSON.parse(readFileSync(layoutPath, 'utf8'))
  } catch (error) {
    throw new Error(`Blender 写出的 layout.json 解析失败：${error instanceof Error ? error.message : String(error)}`)
  }
  const layoutErrors = validateLayout(layout)
  if (layoutErrors.length > 0) {
    throw new Error(`Blender 写出的 layout.json 不合法：${layoutErrors.slice(0, 6).join('；')}`)
  }
  const normalized = normalizeLayout(layout)
  const summary = layoutSummary(normalized)
  if (summary.objectCount === 0) {
    throw new Error('Blender 写出的 layout.json 没有任何可装配对象')
  }
  return { normalized, summary, bytes: layoutBytes, axis: normalized.axis }
}

/**
 * 从配置 layoutObjects（plan JSON 文件路径，或内联 JSON 文本）读取并校验 plan。
 * sceneSource='llm' 时使用；校验失败抛出带具体原因的异常（不静默通过）。
 */
function resolvePlanFromConfig(config, log) {
  const raw = typeof config.layoutObjects === 'string' ? config.layoutObjects.trim() : ''
  if (raw === '') {
    throw new Error(
      "sceneSource='llm' 但没有配置 layoutObjects（在设置里填 plan JSON 文件路径或内联 JSON，或先用 plan_scene_layout 工具生成）",
    )
  }
  let plan
  if (raw.startsWith('{')) {
    try {
      plan = JSON.parse(raw)
    } catch (error) {
      throw new Error(`layoutObjects 不是合法 JSON：${error instanceof Error ? error.message : String(error)}`)
    }
    log('[scenic] 使用设置里的内联 plan JSON')
  } else {
    const expanded = raw.startsWith('~') ? join(homedir(), raw.slice(1)) : raw
    if (!existsSync(expanded)) throw new Error(`layoutObjects 指向的文件不存在：${expanded}`)
    try {
      plan = JSON.parse(readFileSync(expanded, 'utf8'))
    } catch (error) {
      throw new Error(`读取 plan 失败：${expanded}：${error instanceof Error ? error.message : String(error)}`)
    }
    log(`[scenic] 读取 plan 文件：${expanded}`)
  }
  const normalized = normalizePlan(plan)
  const validation = validatePlanDetailed(normalized, config.layoutValidation)
  if (!validation.ok) {
    throw new Error(`布局校验失败：\n- ${validation.errors.map(error => error.message).join('\n- ')}`)
  }
  return normalized
}

async function runLegacy({ blender, jobDir, prompt, images, log }) {
  const dir = join(jobDir, 'blender')
  mkdirSync(dir, { recursive: true })
  const specPath = join(dir, 'spec.json')
  const blendPath = join(dir, 'scene_skeleton.blend')
  const fbxPath = join(dir, 'scene_skeleton.fbx')
  const layoutPath = join(dir, 'layout.json')

  const spec = {
    title: typeof prompt === 'string' && prompt !== '' ? prompt.slice(0, 60) : 'scene-skeleton',
    prompt: typeof prompt === 'string' ? prompt : '',
    images,
    output: { blend: blendPath, fbx: fbxPath, layout: layoutPath },
  }
  writeFileSync(specPath, JSON.stringify(spec, null, 2), 'utf8')
  log(`[legacy] 已写入 spec：${specPath}（参考图 ${images.length} 张）`)

  const result = await runProcess(
    blender.path,
    ['--background', '--factory-startup', '--python', fileURLToPath(LEGACY_SCRIPT_URL), '--', specPath],
    {
      timeoutMs: BLENDER_TIMEOUT_MS,
      onLine: line => {
        if (line.trim().startsWith('[dsh-blender]')) log(line.trim())
      },
    },
  )

  if (result.timedOut) throw new Error(`Blender 执行超时（${Math.round(BLENDER_TIMEOUT_MS / 1000)} 秒）`)
  if (result.code !== 0) {
    throw new Error(`Blender 执行失败（exit=${String(result.code)}）：${tail(result.stderr || result.stdout, 1200) || '没有输出'}`)
  }
  const parsed = parseResultLine(result.stdout)
  if (parsed === null) throw new Error(`Blender 没有返回结果标记：${tail(result.stdout, 800) || '没有输出'}`)

  const blendBytes = assertFile(blendPath, '.blend 场景文件')
  const fbxBytes = assertFile(fbxPath, '.fbx 骨架文件')
  const { summary, bytes: layoutBytes } = readLayout(layoutPath)
  log(`[legacy] layout.json：${summary.objectCount} 个对象，分组 ${summary.groups.join(' / ')}`)

  return {
    mode: 'legacy',
    mesh: { path: fbxPath, bytes: fbxBytes, format: 'fbx', meshes: parsed.meshes || [] },
    blend: { path: blendPath, bytes: blendBytes },
    layout: { path: layoutPath, bytes: layoutBytes },
    parsed,
    summary,
  }
}

async function runScenic({ blender, config, jobDir, prompt, log }) {
  const dir = join(jobDir, 'blender')
  mkdirSync(dir, { recursive: true })
  const blendPath = join(dir, 'scene.blend')
  const glbPath = join(dir, 'scene_skeleton.glb')
  const fbxPath = join(dir, 'scene_skeleton.fbx')
  const layoutPath = join(dir, 'layout.json')
  const seed = hashSeed(prompt)
  const sceneSource = config.sceneSource === 'llm' ? 'llm' : 'template'
  const params = {
    seed,
    width: Number.isFinite(config.scenicWidth) ? config.scenicWidth : 24,
    depth: Number.isFinite(config.scenicDepth) ? config.scenicDepth : 20,
    wall_height: Number.isFinite(config.scenicWallHeight) ? config.scenicWallHeight : 3.2,
    sceneSource,
    layoutAxis: config.layoutAxis === 'y-up' ? 'y-up' : 'z-up',
    layoutValidation: config.layoutValidation,
    materialMapping: typeof config.assetLibraryPath === 'string' && config.assetLibraryPath.trim() !== ''
      ? { assetLibraryPath: config.assetLibraryPath.trim() }
      : null,
    modelMapping: typeof config.assetModelPath === 'string' && config.assetModelPath.trim() !== ''
      ? { assetModelPath: config.assetModelPath.trim() }
      : null,
    texture: config.enableTextureGeneration === true
      ? {
          enabled: true,
          comfyUrl: config.comfyUrl,
          resolution: config.textureResolution,
          objects: config.textureObjects === 'all' ? 'all' : 'main',
          workflowPath: fileURLToPath(PBR_WORKFLOW_URL),
          workflowLitePath: fileURLToPath(PBR_LITE_WORKFLOW_URL),
          texturesDir: join(jobDir, 'textures'),
          timeoutSeconds: 180,
        }
      : null,
  }

  if (sceneSource === 'llm') {
    const plan = resolvePlanFromConfig(config, log)
    const planPath = join(dir, 'plan.json')
    writeFileSync(planPath, JSON.stringify(plan, null, 2), 'utf8')
    params.layoutObjects = planPath
    log(`[scenic] LLM 布局模式：${plan.objects.length} 个对象（plan：${planPath}）`)
  }

  const paramsJson = JSON.stringify(params)
  log(`[scenic] courtyard spec（seed=${seed}, width=${params.width}, depth=${params.depth}, wall_height=${params.wall_height}）`)

  const result = await runProcess(
    blender.path,
    [
      '--background',
      '--factory-startup',
      '--python',
      fileURLToPath(SCENIC_RUNNER_URL),
      '--',
      fileURLToPath(SCENIC_COURTYARD_URL),
      blendPath,
      glbPath,
      fbxPath,
      layoutPath,
      paramsJson,
    ],
    {
      timeoutMs: config.enableTextureGeneration === true ? TEXTURE_RUN_TIMEOUT_MS : BLENDER_TIMEOUT_MS,
      onLine: line => {
        const text = line.trim()
        if (text.startsWith('DSH_BLENDER_') || text.startsWith('[scenic]')) log(text)
      },
    },
  )

  if (result.timedOut) throw new Error(`Blender（scenic）执行超时（${Math.round(BLENDER_TIMEOUT_MS / 1000)} 秒）`)
  if (result.code !== 0) {
    throw new Error(`Blender（scenic）执行失败（exit=${String(result.code)}）：${tail(result.stderr || result.stdout, 1200) || '没有输出'}`)
  }
  const parsed = parseResultLine(result.stdout)
  if (parsed === null) throw new Error(`Blender（scenic）没有返回结果标记：${tail(result.stdout, 800) || '没有输出'}`)

  const blendBytes = assertFile(blendPath, '.blend 场景文件')
  const glbBytes = assertFile(glbPath, '.glb 骨架文件')
  const fbxBytes = assertFile(fbxPath, '.fbx 骨架文件')
  const { summary, bytes: layoutBytes, axis } = readLayout(layoutPath)
  log(`[scenic] layout.json：${summary.objectCount} 个对象，分组 ${summary.groups.join(' / ')}，坐标系 ${axis}（blend ${blendBytes} / glb ${glbBytes} / fbx ${fbxBytes} 字节）`)

  const textureInfo = parsed.texture ?? null
  return {
    mode: 'scenic',
    sceneSource,
    axis,
    mesh: { path: fbxPath, bytes: fbxBytes, format: 'fbx', meshes: parsed.meshes || [] },
    blend: { path: blendPath, bytes: blendBytes },
    glb: { path: glbPath, bytes: glbBytes },
    layout: { path: layoutPath, bytes: layoutBytes },
    texture: textureInfo,
    materialMapping: parsed.materialMapping ?? null,
    geometryMapping: parsed.geometryMapping ?? null,
    parsed,
    summary,
  }
}

/**
 * 执行 Blender 阶段（阶段 6：scenic 模式默认，legacy 可回退）。
 *
 * @param {{ service: {getConfig: () => object}, jobDir: string, prompt: string, artifacts?: Array<object>, onLog?: (message: string) => void }} input
 * @returns {Promise<{detail: string, artifacts: Array<object>, report: object}>}
 */
export async function runBlenderStage({ service, jobDir, prompt, artifacts, onLog }) {
  const config = service.getConfig()
  const log = message => {
    if (typeof onLog === 'function') onLog(message)
  }

  const blender = await checkBlender(config)
  if (blender.status !== 'ok' || typeof blender.path !== 'string' || blender.path === '') {
    throw new Error(`Blender 不可用（${blender.status}）：${blender.detail}`)
  }
  log(`使用 Blender：${blender.path}`)

  const mode = config.blenderSceneMode === 'legacy' ? 'legacy' : 'scenic'
  const images = (Array.isArray(artifacts) ? artifacts : [])
    .filter(item => item && item.kind === 'image' && typeof item.path === 'string' && item.path !== '')
    .map(item => item.path)

  const startedAt = Date.now()
  let outcome
  try {
    outcome =
      mode === 'legacy'
        ? await runLegacy({ blender, jobDir, prompt, images, log })
        : await runScenic({ blender, config, jobDir, prompt, log })
  } catch (error) {
    throw new Error(`Blender 启动失败：${error instanceof Error ? error.message : String(error)}`)
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  const { summary, parsed } = outcome
  const artifactsOut = []
  if (outcome.blend) {
    artifactsOut.push({ kind: 'blend', path: outcome.blend.path, bytes: outcome.blend.bytes })
  }
  if (outcome.glb) {
    artifactsOut.push({ kind: 'glb', path: outcome.glb.path, bytes: outcome.glb.bytes })
  }
  artifactsOut.push(
    {
      kind: 'mesh',
      path: outcome.mesh.path,
      bytes: outcome.mesh.bytes,
      format: outcome.mesh.format,
      meshes: outcome.mesh.meshes,
    },
    {
      kind: 'layout',
      path: outcome.layout.path,
      bytes: outcome.layout.bytes,
      sceneName: summary.sceneName,
      root: summary.root,
      groups: summary.groups,
      objectCount: summary.objectCount,
    },
  )

  // 关闭贴图时也返回 {enabled:false}，让 summary.texture 始终有确定结构（便于下游断言）。
  const textureInfo = outcome.texture ?? (config.enableTextureGeneration === true ? null : { enabled: false })
  if (textureInfo && typeof textureInfo.texturesDir === 'string' && textureInfo.texturesDir !== '') {
    artifactsOut.push({ kind: 'textures', path: textureInfo.texturesDir, files: textureInfo.objectCount ?? 0 })
  }

  const sceneSource = outcome.sceneSource === 'llm' ? 'llm' : 'template'
  const axis = outcome.axis ?? 'y-up'
  const modeText =
    mode === 'legacy' ? 'legacy 固定体块' : sceneSource === 'llm' ? 'scenic + LLM 精确布局' : 'scenic 声明式场景'
  const body =
    mode === 'scenic'
      ? `${summary.objectCount} 个装配对象（源场景 ${parsed.objects ?? '?'} 个节点），导出 .blend（${outcome.blend?.bytes ?? 0} 字节）/.fbx（${outcome.mesh.bytes} 字节）/.glb（${outcome.glb?.bytes ?? 0} 字节）`
      : `${(parsed.meshes || []).length} 个网格，导出 .blend/.fbx（${outcome.mesh.bytes} 字节）`
  return {
    detail:
      `Blender（${modeText}）生成场景骨架：${body}` +
      `与 layout.json（${summary.objectCount} 个对象，分组 ${summary.groups.join(' / ')}，坐标系 ${axis}）` +
      (textureInfo
        ? textureInfo.error
          ? `，贴图：${textureInfo.error}`
          : `，贴图：${textureInfo.objectCount} 个对象（${textureInfo.model}/${textureInfo.resolution}px）`
        : '') +
      `，耗时 ${elapsed} 秒`,
    artifacts: artifactsOut,
    report: {
      mode,
      sceneSource,
      axis,
      blendPath: outcome.blend?.path ?? null,
      layoutPath: outcome.layout.path,
      fbxPath: outcome.mesh.path,
      glb: outcome.glb ? outcome.glb.path : null,
      glbPath: outcome.glb ? outcome.glb.path : null,
      sceneName: summary.sceneName,
      root: summary.root,
      groups: summary.groups,
      groupsDetail: summary.groupsDetail,
      objectCount: summary.objectCount,
      texture: textureInfo,
      materialMapping: outcome.materialMapping ?? null,
      geometryMapping: outcome.geometryMapping ?? null,
    },
  }
}
