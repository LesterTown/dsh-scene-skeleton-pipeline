/**
 * 插件本地配置存储（阶段 2 的阶段性问题：--patch 开发覆盖层下 configEditor 不可写）。
 *
 * Loader 的 configEditor 只能把配置写回「profile 自己的树」；用 `--patch <file>`
 * 作为命令行覆盖层挂载时，这一行配置被覆盖层拥有，configEditor 会拒绝写入
 * （"Configuration ... is overridden by a home patch or command-line overlay"）。
 *
 * 所以设置面板的保存走两条路：
 *   1. 宿主 configEditor（插件正常安装进 profile 时可用，写入 profile patch 层）；
 *   2. 插件自己的存储文件：`$DSH_HOME/scene-skeleton-pipeline/config.json`
 *      （原子写；--patch 开发模式下也一定能落盘，重启宿主后仍然生效）。
 *
 * 读取优先级：存储文件 > Config schema / apply 收到的 config（后者通常来自
 * profile 的 cordis.yml 或覆盖层）。文件里出现过的键即视为「用户显式保存过」。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/**
 * 参与持久化的配置键（顺序即设置面板里输入框的顺序）。
 * 阶段 4 新增：comfyWorkflowPath / comfyCheckpoint / comfyNegativePrompt / unityExe / outputDir。
 * 阶段 6 新增：blenderSceneMode（scenic|legacy）/ scenicWidth / scenicDepth / scenicWallHeight。
 * 阶段 7 新增：enableUnityAdapter（布尔，Unity 装配降级为可选适配器）/ sceneSource / layoutObjects。
 * 阶段 8 新增：layoutAxis（z-up|y-up，layout.json 的坐标系，默认 z-up）。
 * 块 B 新增：layoutValidation（JSON 对象，物理校验容差与场景边界）。
 */
export const CONFIG_KEYS = [
  'blenderExe',
  'comfyUrl',
  'comfyWorkflowPath',
  'comfyCheckpoint',
  'comfyNegativePrompt',
  'unityProjectPath',
  'unityExe',
  'outputDir',
  'blenderSceneMode',
  'scenicWidth',
  'scenicDepth',
  'scenicWallHeight',
  'enableUnityAdapter',
  'sceneSource',
  'layoutObjects',
  'layoutAxis',
  'layoutValidation',
  'assetLibraryPath',
  'assetModelPath',
  'enableTextureGeneration',
  'textureResolution',
  'textureObjects',
  'texturePromptPrefix',
]

/** 布尔型配置键（读写时不按字符串处理）。 */
export const CONFIG_BOOL_KEYS = ['enableUnityAdapter', 'enableTextureGeneration']

/** 以 JSON 对象形式存储的键（layoutValidation）。 */
export const CONFIG_JSON_KEYS = ['layoutValidation']

/** DSH_HOME：与宿主一致，优先环境变量，其次 ~/.dsh。 */
export function dshHome() {
  const fromEnv = typeof process.env.DSH_HOME === 'string' ? process.env.DSH_HOME.trim() : ''
  return fromEnv !== '' ? fromEnv : path.join(os.homedir(), '.dsh')
}

/** 插件数据目录：$DSH_HOME/scene-skeleton-pipeline/ */
export function pluginDataDir(home = dshHome()) {
  return path.join(home, 'scene-skeleton-pipeline')
}

/** 配置文件路径：$DSH_HOME/scene-skeleton-pipeline/config.json */
export function configFilePath(home = dshHome()) {
  return path.join(pluginDataDir(home), 'config.json')
}

/** 流水线产物根目录：$DSH_HOME/scene-skeleton-pipeline/outputs */
export function outputDirPath(home = dshHome()) {
  return path.join(pluginDataDir(home), 'outputs')
}

/**
 * 读取已保存的配置；文件不存在或损坏时返回空对象（不抛异常）。
 * @returns {Partial<Record<string, string>>}
 */
export function readStoredConfig(file = configFilePath()) {
  try {
    const text = fs.readFileSync(file, 'utf8')
    const parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    const out = {}
    for (const key of CONFIG_KEYS) {
      if (CONFIG_BOOL_KEYS.includes(key)) {
        if (typeof parsed[key] === 'boolean') out[key] = parsed[key]
        else if (parsed[key] === 'true') out[key] = true
        else if (parsed[key] === 'false') out[key] = false
      } else if (CONFIG_JSON_KEYS.includes(key)) {
        const value = parsed[key]
        if (value && typeof value === 'object' && !Array.isArray(value)) out[key] = value
        else if (typeof value === 'string') {
          try {
            const decoded = JSON.parse(value)
            if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) out[key] = decoded
          } catch {
            // 忽略损坏的 JSON 值
          }
        }
      } else if (typeof parsed[key] === 'string') {
        out[key] = parsed[key]
      }
    }
    return out
  } catch {
    return {}
  }
}

/**
 * 原子写入配置：先写同目录临时文件再 rename，避免半截文件。
 * @param {object} config 要保存的配置（通常为合并后的完整对象）
 * @param {string} [file]
 */
export function writeStoredConfig(config, file = configFilePath()) {
  const payload = {}
  for (const key of CONFIG_KEYS) {
    if (CONFIG_BOOL_KEYS.includes(key)) {
      payload[key] = typeof config?.[key] === 'boolean' ? config[key] : false
    } else if (CONFIG_JSON_KEYS.includes(key)) {
      payload[key] = config?.[key] && typeof config[key] === 'object' ? config[key] : {}
    } else {
      payload[key] = typeof config?.[key] === 'string' ? config[key] : ''
    }
  }
  const dir = path.dirname(file)
  fs.mkdirSync(dir, { recursive: true })
  const tmp = path.join(dir, `.config.json.${process.pid}.${Date.now()}.tmp`)
  fs.writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', 'utf8')
  fs.renameSync(tmp, file)
  return payload
}
