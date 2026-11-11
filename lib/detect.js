/**
 * 三项环境检测（Blender / ComfyUI / Unity）。
 *
 * 原则：只做“探测”，绝不启动任何软件。
 *   - Blender：只检查可执行文件存在且有执行权限；
 *   - ComfyUI：只发 HTTP GET；
 *   - Unity：只读 ProjectSettings/ProjectVersion.txt。
 *
 * 每项检测都返回 { status: 'ok' | 'missing' | 'error', detail: string, path?: string }。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/** ComfyUI 健康检查超时（毫秒）。 */
export const COMFY_TIMEOUT_MS = 3000

/** 把 `~/foo` 展开成绝对路径；其余原样返回。 */
export function expandHome(input) {
  if (typeof input !== 'string') return ''
  const trimmed = input.trim()
  if (trimmed === '~') return os.homedir()
  if (trimmed.startsWith('~/') || trimmed.startsWith('~\\')) {
    return path.join(os.homedir(), trimmed.slice(2))
  }
  return trimmed
}

/** 是否为「存在 + 普通文件 + 可执行」的路径（跟随软链）。 */
export function isExecutableFile(candidate) {
  if (typeof candidate !== 'string' || candidate === '') return false
  try {
    const stat = fs.statSync(candidate)
    if (!stat.isFile()) return false
    fs.accessSync(candidate, fs.constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** 列出某个目录下匹配前缀的条目（用于 Blender 版本目录探测）。 */
function listDir(dir) {
  try {
    return fs.readdirSync(dir)
  } catch {
    return []
  }
}

/**
 * 按平台生成 Blender 常见安装位置的候选路径。
 * 只是“已知位置清单”，不做 PATH 搜索：PATH 搜索会执行系统命令，本阶段不做。
 */
export function blenderCandidatePaths(platform = os.platform()) {
  const candidates = []
  if (platform === 'win32') {
    const roots = [
      process.env['PROGRAMFILES'] || 'C:\\Program Files',
      process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)',
    ]
    for (const root of roots) {
      const foundation = path.join(root, 'Blender Foundation')
      for (const entry of listDir(foundation)) {
        if (!/^Blender/i.test(entry)) continue
        candidates.push(path.join(foundation, entry, 'blender.exe'))
      }
      // 有些安装直接落在 Blender Foundation 下，没有版本目录。
      candidates.push(path.join(foundation, 'blender.exe'))
    }
    return candidates
  }
  if (platform === 'darwin') {
    candidates.push('/Applications/Blender.app/Contents/MacOS/Blender')
    for (const entry of listDir('/Applications')) {
      if (!/^Blender.*\.app$/i.test(entry)) continue
      candidates.push(path.join('/Applications', entry, 'Contents', 'MacOS', 'Blender'))
    }
    candidates.push(path.join(os.homedir(), 'Applications/Blender.app/Contents/MacOS/Blender'))
    return candidates
  }
  // linux / 其他 unix
  const prefix = process.env['PREFIX'] || '/usr'
  candidates.push(
    '/usr/bin/blender',
    '/usr/local/bin/blender',
    '/snap/bin/blender',
    '/opt/blender/blender',
    path.join(prefix, 'bin/blender'),
  )
  return candidates
}

/**
 * Blender 检测。
 *
 * 优先级：配置的 blenderExe > 环境变量 DSH_BLENDER_EXE > 平台常见安装路径。
 * 配置了 blenderExe 时不再回退探测——用户显式指定了就用它，找不到就报 missing，
 * 避免“用户以为在用 A，实际却在用 B”。
 */
export function checkBlender(config) {
  const configured = expandHome(config?.blenderExe ?? '')
  if (configured !== '') {
    if (isExecutableFile(configured)) {
      return {
        status: 'ok',
        detail: '已找到配置的 Blender 可执行文件',
        path: configured,
      }
    }
    return {
      status: 'missing',
      detail: `配置的 Blender 路径不存在或不可执行：${configured}；请在设置里填写 blender 可执行文件路径`,
      path: configured,
    }
  }

  const fromEnv = expandHome(process.env.DSH_BLENDER_EXE ?? '')
  if (fromEnv !== '') {
    if (isExecutableFile(fromEnv)) {
      return {
        status: 'ok',
        detail: '已找到 Blender 可执行文件（来源：环境变量 DSH_BLENDER_EXE）',
        path: fromEnv,
      }
    }
    return {
      status: 'missing',
      detail: `环境变量 DSH_BLENDER_EXE 指向的路径不存在或不可执行：${fromEnv}；请在设置里填写 blender 可执行文件路径`,
      path: fromEnv,
    }
  }

  const candidates = blenderCandidatePaths()
  for (const candidate of candidates) {
    if (isExecutableFile(candidate)) {
      return {
        status: 'ok',
        detail: '已找到 Blender 可执行文件（来源：常见安装路径探测）',
        path: candidate,
      }
    }
  }
  return {
    status: 'missing',
    detail: '未找到 Blender；请在设置里填写 blender 可执行文件路径（或设置环境变量 DSH_BLENDER_EXE）',
  }
}

/** 从 URL 里取端口，取不到就用 8188（ComfyUI 默认端口）。 */
function portOf(url) {
  try {
    const parsed = new URL(url)
    return parsed.port || (parsed.protocol === 'https:' ? '443' : '80')
  } catch {
    return '8188'
  }
}

/** 把 fetch 抛出的异常翻译成一句人话（detail 里要给用户看）。 */
function describeFetchError(error) {
  if (!error || typeof error !== 'object') return String(error ?? '未知错误')
  const cause = 'cause' in error ? error.cause : undefined
  const code =
    cause && typeof cause === 'object' && 'code' in cause && typeof cause.code === 'string'
      ? cause.code
      : ''
  if (error.name === 'TimeoutError' || code === 'UND_ERR_CONNECT_TIMEOUT' || code === 'ETIMEDOUT') {
    return `请求超时（${COMFY_TIMEOUT_MS} 毫秒）`
  }
  if (code === 'ECONNREFUSED') return '连接被拒绝（ECONNREFUSED），该端口没有服务在监听'
  if (code === 'ENOTFOUND') return '域名解析失败（ENOTFOUND）'
  if (code === 'EACCES') return '没有访问权限（EACCES）'
  const message = error instanceof Error ? error.message : String(error)
  return code ? `${message}（${code}）` : message
}

/** GET 一个地址，返回 { reachable, status, reason }；不抛异常。 */
async function probe(url) {
  try {
    const response = await fetch(url, {
      method: 'GET',
      redirect: 'manual',
      signal: AbortSignal.timeout(COMFY_TIMEOUT_MS),
    })
    // 消费掉 body，避免连接悬挂。
    try {
      await response.arrayBuffer()
    } catch {
      /* 忽略 body 读取失败 */
    }
    return { reachable: true, status: response.status, reason: '' }
  } catch (error) {
    return { reachable: false, status: 0, reason: describeFetchError(error) }
  }
}

/**
 * ComfyUI 检测。
 *
 * GET {comfyUrl}/health 返回 200 视为 ok；老版本没有 /health 时回退 GET {comfyUrl}/queue。
 * 连接失败 / 超时 -> missing（提示用户启动 ComfyUI）；能连上但两个端点都非 200 -> error。
 */
export async function checkComfy(config) {
  const raw = expandHome(config?.comfyUrl ?? '') || 'http://127.0.0.1:8188'
  const base = raw.replace(/\/+$/, '')
  const port = portOf(base)
  if (!/^https?:\/\//i.test(base)) {
    return {
      status: 'error',
      detail: `ComfyUI 地址格式不正确：${raw}；应形如 http://127.0.0.1:8188`,
      path: raw,
    }
  }

  const health = await probe(`${base}/health`)
  if (health.reachable && health.status === 200) {
    return {
      status: 'ok',
      detail: `ComfyUI 健康检查通过（GET ${base}/health 返回 200）`,
      path: base,
    }
  }

  const queue = await probe(`${base}/queue`)
  if (queue.reachable && queue.status === 200) {
    return {
      status: 'ok',
      detail: `ComfyUI 可访问（/health 不可用，已回退 GET ${base}/queue 返回 200）`,
      path: base,
    }
  }

  if (!health.reachable && !queue.reachable) {
    const reason = health.reason || queue.reason || '连接失败或超时'
    return {
      status: 'missing',
      detail: `无法连接 ComfyUI（${base}）：${reason}；请确认 ComfyUI 已启动并监听 ${port} 端口`,
      path: base,
    }
  }

  const healthText = health.reachable ? `HTTP ${health.status}` : '连接失败'
  const queueText = queue.reachable ? `HTTP ${queue.status}` : '连接失败'
  return {
    status: 'error',
    detail: `ComfyUI 有响应但健康检查未通过（${base}）：/health=${healthText}，/queue=${queueText}；请确认 ComfyUI 已启动并监听 ${port} 端口`,
    path: base,
  }
}

/** 从 ProjectVersion.txt 里读 Unity 版本（读不到就返回空串）。 */
function readUnityVersion(versionFilePath) {
  try {
    const text = fs.readFileSync(versionFilePath, 'utf8')
    const match = /^m_EditorVersion:\s*(.+)$/m.exec(text)
    return match ? match[1].trim() : ''
  } catch {
    return ''
  }
}

/**
 * Unity 检测。
 *
 * 只认配置里的项目根目录：{unityProjectPath}/ProjectSettings/ProjectVersion.txt 存在即 ok。
 */
export function checkUnity(config) {
  const configured = expandHome(config?.unityProjectPath ?? '')
  if (configured === '') {
    return {
      status: 'missing',
      detail: '请在设置中指定 Unity 项目根目录',
    }
  }
  const versionFile = path.join(configured, 'ProjectSettings', 'ProjectVersion.txt')
  try {
    const stat = fs.statSync(versionFile)
    if (!stat.isFile()) {
      return {
        status: 'missing',
        detail: `Unity 项目里没有 ProjectSettings/ProjectVersion.txt（${versionFile}）；请在设置中指定 Unity 项目根目录`,
        path: configured,
      }
    }
    const version = readUnityVersion(versionFile)
    return {
      status: 'ok',
      detail: version ? `已找到 Unity 项目（Editor 版本 ${version}）` : '已找到 Unity 项目',
      path: configured,
    }
  } catch (error) {
    const code = error && typeof error === 'object' && 'code' in error ? error.code : ''
    if (code === 'ENOENT') {
      return {
        status: 'missing',
        detail: `未找到 Unity 项目：${configured} 下没有 ProjectSettings/ProjectVersion.txt；请在设置中指定 Unity 项目根目录`,
        path: configured,
      }
    }
    return {
      status: 'error',
      detail: `检查 Unity 项目失败（${configured}）：${error instanceof Error ? error.message : String(error)}`,
      path: configured,
    }
  }
}
