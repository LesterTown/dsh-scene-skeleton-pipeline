/**
 * 设置页的宿主半边：HTTP 路由 + 配置持久化。
 *
 * 路由挂在 webServer 上（与 dsh-cursor-dev 的 `/plugins/<pkg>/...` 同款写法）：
 *   GET  /plugins/dsh-scene-skeleton-pipeline/state          当前配置 + 三项检测结果 + 流水线状态
 *   POST /plugins/dsh-scene-skeleton-pipeline/check          重新检测
 *   POST /plugins/dsh-scene-skeleton-pipeline/config         保存配置并立即重新检测
 *   POST /plugins/dsh-scene-skeleton-pipeline/pipeline/run   跑一次流水线（dryRun:false 时真实执行）
 *   GET  /plugins/dsh-scene-skeleton-pipeline/pipeline/jobs  最近的流水线 job 列表
 *   GET  /plugins/dsh-scene-skeleton-pipeline/               一个极简 HTML 自检页（不依赖客户端插件）
 *
 * 配置持久化走宿主 configEditor：写入当前 profile 的 patch 层（不是整树回写），
 * 重启宿主后仍然生效；没有 configEditor 时降级为「只改内存」，并在响应里说明。
 */

import { CONFIG_BOOL_KEYS, CONFIG_JSON_KEYS, CONFIG_KEYS, writeStoredConfig } from './store.js'

const BASE = '/plugins/dsh-scene-skeleton-pipeline'
const MAX_BODY_BYTES = 64 * 1024

function sendJson(res, status, body) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(body, null, 2))
}

function sendHtml(res, status, html) {
  res.statusCode = status
  res.setHeader('content-type', 'text/html; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(html)
}

/** 读取并解析 JSON 请求体，带体积上限。 */
function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', chunk => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new Error('请求体过大'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8').trim()
      if (text === '') {
        resolve({})
        return
      }
      try {
        const value = JSON.parse(text)
        resolve(value && typeof value === 'object' ? value : {})
      } catch (error) {
        reject(new Error(`请求体不是合法 JSON：${error instanceof Error ? error.message : String(error)}`))
      }
    })
    req.on('error', error => reject(error))
  })
}

/**
 * 跨站防护：这些路由在宿主 `/api` 载体之外，简单起见只接受同源请求。
 * 非浏览器客户端（curl、验收脚本）通常不带 Origin，直接放行。
 */
function sameOrigin(req) {
  const origin = req.headers?.origin
  if (typeof origin !== 'string' || origin === '') return true
  try {
    return new URL(origin).host === String(req.headers?.host ?? '')
  } catch {
    return false
  }
}

function canPersist(ctx) {
  try {
    return typeof ctx.get?.('configEditor')?.edit === 'function' && ctx.fiber?.entry !== undefined
  } catch {
    return false
  }
}

/**
 * 把一组配置字段写入当前 profile 的 patch 层（插件安装进 profile 时的标准路径）。
 * @returns {Promise<{saved: boolean, saveError?: string}>}
 */
async function persistToProfilePatch(ctx, next) {
  const entry = ctx.fiber?.entry
  if (entry === undefined) {
    return { saved: false, saveError: '当前挂载行没有可写的 loader entry，配置只保存在内存中' }
  }
  const editor = ctx.get?.('configEditor')
  if (typeof editor?.edit !== 'function') {
    return { saved: false, saveError: '宿主没有 configEditor 服务，配置只保存在内存中' }
  }
  try {
    await editor.edit(entry, current => ({ ...(current && typeof current === 'object' ? current : {}), ...next }))
    return { saved: true }
  } catch (error) {
    return {
      saved: false,
      saveError: `写入 profile patch 失败：${error instanceof Error ? error.message : String(error)}`,
    }
  }
}

const PAGE_CSS = `
  body{margin:0;padding:24px;font:14px/1.65 -apple-system,"PingFang SC","Segoe UI",system-ui,sans-serif;
       background:#15151a;color:#e8e8ee}
  h1{font-size:16px;margin:0 0 4px}
  .sub{opacity:.65;font-size:12px;margin-bottom:18px}
  .grid{display:grid;gap:12px;max-width:760px}
  .card{border:1px solid rgba(127,127,127,.28);border-radius:10px;padding:12px 14px}
  .row{display:flex;align-items:center;gap:8px}
  .name{font-weight:600}
  .dot{width:8px;height:8px;border-radius:50%}
  .badge{font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid currentColor}
  .detail{opacity:.78;margin-top:6px;font-size:12.5px}
  .path{opacity:.55;font:11px/1.5 ui-monospace,SFMono-Regular,Consolas,monospace;margin-top:4px;word-break:break-all}
  .foot{opacity:.6;font-size:12px;margin-top:14px}
  code{font:12px/1.5 ui-monospace,SFMono-Regular,Consolas,monospace;background:rgba(127,127,127,.14);padding:1px 5px;border-radius:5px}
`

const STATUS_COLOR = { ok: '#3fbf7f', missing: '#e0a23a', error: '#e5636c' }
const STATUS_ZH = { ok: '正常', missing: '缺失', error: '错误' }
const ITEM_ZH = { blender: 'Blender', comfy: 'ComfyUI', unity: 'Unity' }

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch])
}

function renderPage(snapshot) {
  const { config, environment, checkedAt } = snapshot
  const cards = ['blender', 'comfy', 'unity']
    .map(key => {
      const item = environment?.[key] ?? { status: 'missing', detail: '尚未检测' }
      const color = STATUS_COLOR[item.status] ?? STATUS_COLOR.error
      return `<div class="card">
        <div class="row"><span class="dot" style="background:${color}"></span>
          <span class="name">${ITEM_ZH[key]}</span>
          <span class="badge" style="color:${color}">${STATUS_ZH[item.status] ?? escapeHtml(item.status)}</span></div>
        <div class="detail">${escapeHtml(item.detail ?? '')}</div>
        ${item.path ? `<div class="path">path: ${escapeHtml(item.path)}</div>` : ''}
      </div>`
    })
    .join('')
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <title>dsh-scene-skeleton-pipeline 环境检测</title><style>${PAGE_CSS}</style></head><body>
    <h1>场景骨架流水线 · 环境检测</h1>
    <div class="sub">环境检测不会启动软件；流水线 dryRun:false 才会真实启动 ComfyUI / Blender / Unity。</div>
    <div class="grid">${cards}</div>
    <div class="foot">
      最近检测：${escapeHtml(checkedAt ?? '尚未检测')}<br>
      Blender：<code>${escapeHtml(config?.blenderExe || '(自动探测)')}</code><br>
      ComfyUI：<code>${escapeHtml(config?.comfyUrl ?? '')}</code>
      ${config?.comfyCheckpoint ? `· checkpoint <code>${escapeHtml(config.comfyCheckpoint)}</code>` : ''}<br>
      ComfyUI 工作流：<code>${escapeHtml(config?.comfyWorkflowPath || '(内置 txt2img 模板)')}</code><br>
      Unity：<code>${escapeHtml(config?.unityProjectPath || '(未配置)')}</code>
      ${config?.unityExe ? `· <code>${escapeHtml(config.unityExe)}</code>` : ''}<br>
      产物目录：<code>${escapeHtml(snapshot.pipeline?.outputDir || '$DSH_HOME/scene-skeleton-pipeline/outputs')}</code><br>
      <br>JSON：<a style="color:#8ab4ff" href="${BASE}/state">${BASE}/state</a>
    </div></body></html>`
}

/**
 * 注册设置页所需的路由。
 * @param ctx - webServer 作用域（宿主 ctx）。
 * @param service - pipeline-service 实例。
 * @param engine - 流水线引擎（阶段 3 的 dry-run 调度器）。
 * @returns {Array<() => void>} 释放函数列表（供 ctx.effect 清理）。
 */
export function registerSettingsRoutes(ctx, service, engine) {
  const server = ctx.get?.('webServer')
  if (!server || typeof server.register !== 'function') {
    ctx.logger?.warn?.('[dsh-scene-skeleton-pipeline] webServer 不可用，设置页路由未注册')
    return []
  }

  const snapshot = extra => ({
    config: service.getConfig(),
    environment: service.getEnvironment(),
    checkedAt: service.checkedAt,
    configEditable: canPersist(ctx),
    configFile: service.getConfigFile(),
    pipeline: {
      dryRunOnly: false,
      realExecution: true,
      outputDir: engine?.describe?.().outputDir ?? '',
      stages: engine?.describe?.().stages ?? [],
      lastJob: engine?.getLastJob?.() ?? null,
    },
    ...extra,
  })

  const guard = (label, handler) => async (req, res) => {
    try {
      await handler(req, res)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      ctx.logger?.warn?.(`[dsh-scene-skeleton-pipeline] ${label} 失败：${message}`)
      try {
        sendJson(res, 500, { ok: false, error: message })
      } catch {
        /* 响应已发出 */
      }
    }
  }

  const disposers = []
  const register = (path, handler) => {
    try {
      disposers.push(server.register({ kind: 'exact', path: BASE + path, handler }))
    } catch (error) {
      ctx.logger?.warn?.(
        `[dsh-scene-skeleton-pipeline] 路由注册失败 ${BASE + path}：${
          error instanceof Error ? error.message : String(error)
        }`,
      )
    }
  }

  register(
    '/state',
    guard('GET /state', async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin request rejected' })
        return
      }
      // state 也顺手刷新一次，避免面板长时间显示旧结果。
      await service.checkAll()
      sendJson(res, 200, snapshot())
    }),
  )

  register(
    '/check',
    guard('POST /check', async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin request rejected' })
        return
      }
      if (String(req?.method ?? 'GET').toUpperCase() !== 'POST') {
        sendJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      await service.checkAll()
      sendJson(res, 200, snapshot())
    }),
  )

  register(
    '/config',
    guard('POST /config', async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin request rejected' })
        return
      }
      if (String(req?.method ?? 'GET').toUpperCase() !== 'POST') {
        sendJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      const body = await readJsonBody(req)
      const next = {}
      for (const key of CONFIG_KEYS) {
        const value = body[key]
        if (CONFIG_BOOL_KEYS.includes(key)) {
          // 布尔配置：接受 true/false 或 'true'/'false'（表单与脚本都可能传字符串）
          if (value === true || value === 'true') next[key] = 'true'
          else if (value === false || value === 'false') next[key] = 'false'
        } else if (CONFIG_JSON_KEYS.includes(key)) {
          // JSON 对象配置：接受对象或 JSON 字符串（面板可能以字符串提交）
          if (value && typeof value === 'object' && !Array.isArray(value)) next[key] = value
          else if (typeof value === 'string' && value.trim() !== '') {
            try {
              const decoded = JSON.parse(value)
              if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) next[key] = decoded
            } catch {
              // 非法 JSON 忽略，保留当前值
            }
          }
        } else if (typeof value === 'string') {
          next[key] = value.trim()
        }
      }
      // 先更新内存与检测结果，再持久化：持久化失败时面板仍然能看到新结果。
      await service.updateConfig({ ...service.getConfig(), ...next })

      // 1) 插件自己的存储文件（$DSH_HOME/scene-skeleton-pipeline/config.json）：
      //    这是 --patch 开发模式下的权威保存路径，重启宿主后仍然生效。
      const saveTargets = []
      const saveErrors = []
      try {
        // 存合并后的完整配置，避免存储文件只有部分键时语义漂移。
        writeStoredConfig(service.getConfig())
        saveTargets.push('file')
      } catch (error) {
        saveErrors.push(`写入 ${service.getConfigFile()} 失败：${error instanceof Error ? error.message : String(error)}`)
      }

      // 2) 宿主 configEditor（写入 profile patch 层）：插件正常安装进 profile 时可用；
      //    命令行 --patch 覆盖层拥有该行时会被宿主拒绝，属于预期情况，不视为失败。
      const patchResult = await persistToProfilePatch(ctx, next)
      if (patchResult.saved) saveTargets.push('profile-patch')
      else if (patchResult.saveError) saveErrors.push(patchResult.saveError)

      sendJson(res, 200, snapshot({
        saved: saveTargets.length > 0,
        saveTargets,
        saveError: saveTargets.length > 0 ? undefined : saveErrors.join('；'),
      }))
    }),
  )

  register(
    '/pipeline/run',
    guard('POST /pipeline/run', async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin request rejected' })
        return
      }
      if (String(req?.method ?? 'GET').toUpperCase() !== 'POST') {
        sendJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      if (engine === undefined || typeof engine.run !== 'function') {
        sendJson(res, 503, { ok: false, error: 'pipeline engine 不可用' })
        return
      }
      const body = await readJsonBody(req)
      const job = await engine.run({ prompt: body.prompt, dryRun: body.dryRun })
      sendJson(res, 200, { ok: job.status === 'done', job, snapshot: snapshot() })
    }),
  )

  register(
    '/pipeline/jobs',
    guard('GET /pipeline/jobs', async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin request rejected' })
        return
      }
      if (String(req?.method ?? 'GET').toUpperCase() !== 'GET') {
        sendJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      sendJson(res, 200, {
        ok: true,
        stages: engine?.describe?.().stages ?? [],
        jobs: engine?.listJobs?.() ?? [],
      })
    }),
  )

  register(
    '/',
    guard('GET /', async (req, res) => {
      if (String(req?.method ?? 'GET').toUpperCase() !== 'GET') {
        sendJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      await service.checkAll()
      sendHtml(res, 200, renderPage(snapshot()))
    }),
  )

  return disposers
}

export { BASE as SETTINGS_BASE }
