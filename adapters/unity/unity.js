/**
 * Unity executor（阶段 5）：按布局 JSON 把场景骨架装配进 Unity 项目并生成 .unity 场景。
 *
 * 调用方式（batchmode）：
 *   Unity -batchmode -quit -nographics -projectPath <项目> \
 *         -executeMethod SceneSkeletonPipelineEditor.Build -logFile <日志>
 *
 * 依赖：目标工程包含 ProjectSettings/ProjectVersion.txt；本机装了对应版本的 Unity 编辑器。
 * 插件会幂等写入 Assets/Editor/SceneSkeletonPipelineEditor.cs、Assets/SceneSkeletonPipeline/ 下的
 * fbx / layout.json / input.json，并读取 Unity 写回的 unity-result.json 结构化报告。
 *
 * layout.json 契约见 ../layout.js 顶部注释；本文件在启动 Unity 之前先校验布局，
 * 避免把坏 JSON 带进一个要跑几十秒的 batchmode 进程。
 */

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { layoutSummary, normalizeLayout, validateLayout } from '../../lib/layout.js'
import { runProcess } from '../../lib/executors/process.js'

export const UNITY_TIMEOUT_MS = 420000
const EDITOR_SCRIPT_URL = new URL('./SceneSkeletonPipelineEditor.cs', import.meta.url)

function tail(text, limit) {
  const value = typeof text === 'string' ? text.trim() : ''
  return value.length <= limit ? value : `…${value.slice(value.length - limit)}`
}

function parseVersionFile(projectPath) {
  const file = join(projectPath, 'ProjectSettings', 'ProjectVersion.txt')
  if (!existsSync(file)) return null
  try {
    const text = readFileSync(file, 'utf8')
    const match = text.match(/m_EditorVersion:\s*(\S+)/)
    return match ? match[1] : null
  } catch {
    return null
  }
}

function listInstalledEditors() {
  const base = '/Applications/Unity/Hub/Editor'
  if (!existsSync(base)) return []
  try {
    return readdirSync(base)
      .filter(name => existsSync(join(base, name, 'Unity.app', 'Contents', 'MacOS', 'Unity')))
      .sort()
      .map(name => join(base, name, 'Unity.app', 'Contents', 'MacOS', 'Unity'))
  } catch {
    return []
  }
}

/** 解析 Unity 可执行文件：配置优先，其次按工程版本匹配，最后取最新安装版本。 */
export function resolveUnityExe(config, projectPath) {
  const configured = typeof config?.unityExe === 'string' ? config.unityExe.trim() : ''
  if (configured !== '') {
    return { exe: configured, source: '配置 unityExe' }
  }
  const version = projectPath ? parseVersionFile(projectPath) : null
  const editors = listInstalledEditors()
  if (editors.length === 0) return { exe: '', source: '未找到 /Applications/Unity/Hub/Editor 下的编辑器' }
  if (version) {
    const match = editors.find(exe => exe.includes(`/${version}/`))
    if (match) return { exe: match, source: `按工程版本 ${version} 匹配` }
  }
  const fallback = editors[editors.length - 1]
  return { exe: fallback, source: version ? `工程版本 ${version} 未安装，使用 ${fallback}` : `使用 ${fallback}` }
}

const DEG = Math.PI / 180
/** Blender 坐标轴基（Z-up → Unity Y-up 的基变换矩阵）。 */
const UNITY_BASIS = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]

function mul3(a, b) {
  return a.map(row => [0, 1, 2].map(j => row.reduce((sum, value, k) => sum + value * b[k][j], 0)))
}

function transpose3(a) {
  return a[0].map((_, i) => a.map(row => row[i]))
}

function rotX(deg) {
  const c = Math.cos(deg * DEG)
  const s = Math.sin(deg * DEG)
  return [[1, 0, 0], [0, c, -s], [0, s, c]]
}

function rotY(deg) {
  const c = Math.cos(deg * DEG)
  const s = Math.sin(deg * DEG)
  return [[c, 0, s], [0, 1, 0], [-s, 0, c]]
}

function rotZ(deg) {
  const c = Math.cos(deg * DEG)
  const s = Math.sin(deg * DEG)
  return [[c, -s, 0], [s, c, 0], [0, 0, 1]]
}

/** Blender Euler XYZ（度）→ 旋转矩阵（Blender 约定 R = Rz·Ry·Rx）。 */
function eulerXYZToMatrix(degrees) {
  return mul3(rotZ(degrees[2]), mul3(rotY(degrees[1]), rotX(degrees[0])))
}

/** 3×3 旋转矩阵 → Unity Euler ZXY（度，与 Quaternion.Euler 的分解一致）。 */
function decomposeZXY(matrix) {
  const x = Math.asin(Math.max(-1, Math.min(1, -matrix[1][2])))
  const z = Math.atan2(matrix[1][0], matrix[1][1])
  const y = Math.atan2(matrix[0][2], matrix[2][2])
  return [x / DEG, y / DEG, z / DEG]
}

/** Blender 欧拉角 → Unity 欧拉角：M = B·R·Bᵀ 后按 ZXY 分解。 */
function blenderEulerToUnityEuler(degrees) {
  const rotation = eulerXYZToMatrix(degrees)
  const converted = mul3(UNITY_BASIS, mul3(rotation, transpose3(UNITY_BASIS)))
  return decomposeZXY(converted).map(value => Math.round(value * 1e4) / 1e4)
}

/** Blender 点 → Unity 点（y-up = (x, z, -y)）。 */
function blenderPointToUnity(point) {
  return [round4(point[0]), round4(point[2]), round4(-point[1])]
}

/** Blender 太阳光欧拉角 → Unity 方向光 (pitch, yaw, 0)。 */
function blenderEulerToUnityDirectional(degrees) {
  const rotation = eulerXYZToMatrix(degrees)
  const direction = [-rotation[0][2], -rotation[1][2], -rotation[2][2]]
  const length = Math.hypot(direction[0], direction[1], direction[2]) || 1
  const u = [direction[0] / length, direction[2] / length, -direction[1] / length]
  const pitch = Math.asin(Math.max(-1, Math.min(1, -u[1]))) / DEG
  const yaw = Math.atan2(u[0], u[2]) / DEG
  return [round4(pitch), round4(yaw), 0]
}

function round4(value) {
  return Math.round(value * 1e4) / 1e4
}

/**
 * 把 layout 从 Blender 原生 Z-up 转换成 Unity Y-up（adapter 层职责）。
 * 核心流水线产物（layout.json 原文件、.blend/.fbx）保持 Blender 原生，不做改动。
 *
 * @param {object} layout 已 normalizeLayout 的布局
 * @returns {object} axis='y-up' 的布局副本
 */
export function layoutZupToYup(layout) {
  return {
    ...layout,
    axis: 'y-up',
    groups: layout.groups.map(group => ({
      ...group,
      objects: group.objects.map(object => ({
        ...object,
        position: blenderPointToUnity(object.position),
        rotation: blenderEulerToUnityEuler(object.rotation ?? [0, 0, 0]),
      })),
    })),
    lighting: {
      ...layout.lighting,
      directional: {
        ...layout.lighting.directional,
        rotation: blenderEulerToUnityDirectional(layout.lighting.directional.rotation),
      },
    },
    camera: {
      ...layout.camera,
      position: blenderPointToUnity(layout.camera.position),
      lookAt: blenderPointToUnity(layout.camera.lookAt),
    },
  }
}

function assertProject(projectPath) {
  if (typeof projectPath !== 'string' || projectPath.trim() === '') {
    throw new Error('未配置 Unity 项目路径（unityProjectPath）')
  }
  const versionFile = join(projectPath, 'ProjectSettings', 'ProjectVersion.txt')
  if (!existsSync(versionFile)) {
    throw new Error(`Unity 项目无效：缺少 ${versionFile}`)
  }
  return versionFile
}

/**
 * 执行 Unity 阶段（阶段 5：按 layout.json 装配层级 + 光照 + 相机，可选 prefab）。
 *
 * @param {{ service: {getConfig: () => object, getOutputDir?: () => string}, jobDir: string, prompt: string, artifacts?: Array<object>, onLog?: (message: string) => void }} input
 * @returns {Promise<{detail: string, artifacts: Array<object>, report: object}>}
 */
export async function runUnityStage({ service, jobDir, prompt, artifacts, onLog }) {
  const config = service.getConfig()
  const log = message => {
    if (typeof onLog === 'function') onLog(message)
  }
  const items = Array.isArray(artifacts) ? artifacts : []

  const projectPath = typeof config.unityProjectPath === 'string' ? config.unityProjectPath.trim() : ''
  const versionFile = assertProject(projectPath)
  const version = parseVersionFile(projectPath) || '未知版本'
  log(`Unity 工程：${projectPath}（${version}）`)

  const meshArtifact = items.find(item => item && item.kind === 'mesh' && typeof item.path === 'string' && item.path !== '')
  if (!meshArtifact) throw new Error('没有可导入的网格产物：Blender 阶段没有产出 .glb/.fbx')

  const layoutArtifact = items.find(item => item && item.kind === 'layout' && typeof item.path === 'string' && item.path !== '')
  if (!layoutArtifact) {
    throw new Error('没有布局产物：Blender 阶段没有产出 layout.json（阶段 5 需要按布局装配场景）')
  }

  let rawLayout
  try {
    rawLayout = JSON.parse(readFileSync(layoutArtifact.path, 'utf8'))
  } catch (error) {
    throw new Error(`layout.json 解析失败：${error instanceof Error ? error.message : String(error)}`)
  }
  const layoutErrors = validateLayout(rawLayout)
  if (layoutErrors.length > 0) {
    throw new Error(`layout.json 不合法：${layoutErrors.slice(0, 6).join('；')}`)
  }
  const layout = normalizeLayout(rawLayout)
  const unityLayout = layout.axis === 'z-up' ? layoutZupToYup(layout) : layout
  const expected = layoutSummary(layout)
  log(
    `布局：${layoutArtifact.path}（${expected.objectCount} 个对象，分组 ${expected.groups.join(' / ')}，坐标系 ${layout.axis}）`,
  )
  if (layout.axis === 'z-up') log('layout 坐标系：z-up → adapter 层已转换为 Unity Y-up（原文件保持不变）')

  const { exe, source } = resolveUnityExe(config, projectPath)
  if (exe === '' || !existsSync(exe)) {
    throw new Error(`找不到 Unity 可执行文件（${source}），请在设置里填写 unityExe`)
  }
  log(`使用 Unity：${exe}（${source}）`)

  // 1) 把网格资产（.glb/.fbx）/ layout 复制进工程，并写入 Editor 脚本与输入清单。
  const assetsDir = join(projectPath, 'Assets', 'SceneSkeletonPipeline')
  const editorDir = join(projectPath, 'Assets', 'Editor')
  mkdirSync(assetsDir, { recursive: true })
  mkdirSync(editorDir, { recursive: true })
  const meshFormat = meshArtifact.format === 'glb' ? 'glb' : 'fbx'
  const meshName = `scene_skeleton.${meshFormat}`
  const meshTarget = join(assetsDir, meshName)
  copyFileSync(meshArtifact.path, meshTarget)
  log(`已复制 ${meshFormat}：${meshTarget}（${statSync(meshTarget).size} 字节）`)

  const layoutTarget = join(assetsDir, 'layout.json')
  writeFileSync(layoutTarget, JSON.stringify(unityLayout, null, 2) + '\n', 'utf8')
  log(`已写入 layout（axis=${unityLayout.axis}）：${layoutTarget}`)

  const editorScript = fileURLToPath(EDITOR_SCRIPT_URL)
  const editorScriptTarget = join(editorDir, 'SceneSkeletonPipelineEditor.cs')
  copyFileSync(editorScript, editorScriptTarget)
  log(`已写入 Editor 脚本：${editorScriptTarget}`)

  const sceneRelative = 'Assets/Scenes/SceneSkeleton.unity'
  const unityDir = join(jobDir, 'unity')
  mkdirSync(unityDir, { recursive: true })
  const resultPath = join(unityDir, 'unity-result.json')
  const inputPath = join(assetsDir, 'input.json')
  writeFileSync(
    inputPath,
    JSON.stringify(
      {
        layoutPath: layoutTarget,
        resultPath,
        assetPath: `Assets/SceneSkeletonPipeline/${meshName}`,
        fbxPath: 'Assets/SceneSkeletonPipeline/scene_skeleton.fbx',
        scenePath: sceneRelative,
        title: typeof prompt === 'string' && prompt !== '' ? prompt.slice(0, 60) : 'SceneSkeleton',
      },
      null,
      2,
    ),
    'utf8',
  )
  // 清掉上一次的结果，避免读到陈旧报告。
  rmSync(resultPath, { force: true })

  // 2) batchmode 装配场景。
  const logPath = join(unityDir, 'unity.log')
  const startedAt = Date.now()
  let result
  try {
    result = await runProcess(
      exe,
      [
        '-batchmode',
        '-quit',
        '-nographics',
        '-projectPath',
        projectPath,
        '-executeMethod',
        'SceneSkeletonPipelineEditor.Build',
        '-logFile',
        logPath,
      ],
      {
        timeoutMs: UNITY_TIMEOUT_MS,
        onLine: line => {
          const trimmed = line.trim()
          if (trimmed.startsWith('DSH_UNITY_SCENE') || trimmed.startsWith('DSH_UNITY_RESULT')) log(trimmed)
        },
        cwd: projectPath,
      },
    )
  } catch (error) {
    throw new Error(`Unity 启动失败：${error instanceof Error ? error.message : String(error)}`)
  }

  if (result.timedOut) {
    throw new Error(`Unity 执行超时（${Math.round(UNITY_TIMEOUT_MS / 1000)} 秒），日志：${logPath}`)
  }

  let unityLog = ''
  if (existsSync(logPath)) {
    try {
      unityLog = readFileSync(logPath, 'utf8')
    } catch {
      unityLog = ''
    }
  }
  const successLine = unityLog.split(/\r?\n/).find(line => line.includes('DSH_UNITY_SCENE_OK:'))
  const errorLine = unityLog.split(/\r?\n/).find(line => line.includes('DSH_UNITY_SCENE_ERROR:'))

  let report = null
  if (existsSync(resultPath)) {
    try {
      report = JSON.parse(readFileSync(resultPath, 'utf8'))
    } catch (error) {
      log(`unity-result.json 解析失败：${error instanceof Error ? error.message : String(error)}`)
      report = null
    }
  }

  if (result.code !== 0 || successLine === undefined || report === null || report.success !== true) {
    const detail =
      (report && typeof report.logs === 'object' && report.logs !== null ? report.logs.join(' / ') : '') ||
      errorLine ||
      tail(unityLog || result.stderr || result.stdout, 1500)
    throw new Error(`Unity 装配场景失败（exit=${String(result.code)}）：${detail || '日志为空'}`)
  }

  const scenePath = join(projectPath, sceneRelative)
  if (!existsSync(scenePath)) throw new Error(`Unity 日志显示成功，但没有找到场景文件：${scenePath}`)
  const sceneBytes = statSync(scenePath).size
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)

  const groups = Array.isArray(report.groups) ? report.groups.filter(item => typeof item === 'string') : []
  const objectCount = Number.isInteger(report.objectCount) ? report.objectCount : expected.objectCount
  const prefabPath = typeof report.prefabPath === 'string' && report.prefabPath !== '' ? report.prefabPath : null
  if (objectCount !== expected.objectCount) {
    log(`注意：layout 期望 ${expected.objectCount} 个对象，Unity 实际装配 ${objectCount} 个`)
  }

  const unityReport = {
    success: true,
    scenePath: sceneRelative,
    root: typeof report.root === 'string' && report.root !== '' ? report.root : 'SceneSkeleton_Root',
    groups,
    objectCount,
    prefabPath,
    layoutPath: layoutArtifact.path,
    layoutGroups: expected.groups,
    layoutAxis: layout.axis,
    unityAxis: unityLayout.axis,
    expectedObjectCount: expected.objectCount,
    unityResultPath: resultPath,
    unityProject: projectPath,
    unityVersion: version,
    log: logPath,
  }

  const artifactsOut = [
    {
      kind: 'scene',
      path: scenePath,
      bytes: sceneBytes,
      project: projectPath,
      unityVersion: version,
      log: logPath,
      layout: layoutArtifact.path,
    },
  ]
  if (prefabPath !== null) {
    const prefabAbsolute = join(projectPath, prefabPath)
    artifactsOut.push({
      kind: 'prefab',
      path: prefabAbsolute,
      exists: existsSync(prefabAbsolute),
      relative: prefabPath,
    })
  }

  log(`装配完成：root=${unityReport.root}，groups=${groups.join('/')}，objects=${objectCount}`)

  return {
    detail:
      `Unity 装配场景：${sceneRelative}（${sceneBytes} 字节，工程版本 ${version}，` +
      `根节点 ${unityReport.root}，${groups.length} 个分组 / ${objectCount} 个对象，耗时 ${elapsed} 秒）`,
    artifacts: artifactsOut,
    report: unityReport,
  }
}
