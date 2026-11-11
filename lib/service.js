/**
 * pipeline-service：工作流编排服务的壳（阶段 2 只做环境检测聚合）。
 *
 * 注册方式是类形态：apply 里 `ctx.provide('scenePipeline', new PipelineService(...))`，
 * 消费方用 `ctx.get('scenePipeline')` 取用。
 *
 * 后续阶段会在这里加：ComfyUI 工作流提交、Blender 调用、Unity 场景生成等；
 * 本阶段公开接口刻意保持最小：getEnvironment() / getConfig() / updateConfig() / checkAll()。
 */

import { checkBlender, checkComfy, checkUnity } from './detect.js'
import { DEFAULT_LAYOUT_VALIDATION, mergeValidationOptions } from './layout.js'
import { configFilePath, outputDirPath, readStoredConfig } from './store.js'

const DEFAULT_CONFIG = {
  blenderExe: '',
  comfyUrl: 'http://127.0.0.1:8188',
  comfyWorkflowPath: '',
  comfyCheckpoint: '',
  comfyNegativePrompt: '',
  unityProjectPath: '',
  unityExe: '',
  outputDir: '',
  blenderSceneMode: 'scenic',
  scenicWidth: 24,
  scenicDepth: 20,
  scenicWallHeight: 3.2,
  enableUnityAdapter: false,
  sceneSource: 'template',
  layoutObjects: '',
  layoutAxis: 'z-up',
  layoutValidation: DEFAULT_LAYOUT_VALIDATION,
  assetLibraryPath: '',
  assetModelPath: '',
  enableTextureGeneration: false,
  textureResolution: 512,
  textureObjects: 'main',
  texturePromptPrefix: '',
}

/** 把（可能不完整的）配置规整成完整对象。 */
export function normalizeConfig(config) {
  const raw = config && typeof config === 'object' ? config : {}
  const pick = key => (typeof raw[key] === 'string' ? raw[key].trim() : DEFAULT_CONFIG[key])
  const pickNumber = key => {
    const value = raw[key]
    const parsed = typeof value === 'number' ? value : Number.parseFloat(value)
    return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_CONFIG[key]
  }
  return {
    blenderExe: pick('blenderExe'),
    comfyUrl: pick('comfyUrl') || DEFAULT_CONFIG.comfyUrl,
    comfyWorkflowPath: pick('comfyWorkflowPath'),
    comfyCheckpoint: pick('comfyCheckpoint'),
    comfyNegativePrompt: pick('comfyNegativePrompt'),
    unityProjectPath: pick('unityProjectPath'),
    unityExe: pick('unityExe'),
    outputDir: pick('outputDir'),
    blenderSceneMode: raw.blenderSceneMode === 'legacy' ? 'legacy' : 'scenic',
    scenicWidth: pickNumber('scenicWidth'),
    scenicDepth: pickNumber('scenicDepth'),
    scenicWallHeight: pickNumber('scenicWallHeight'),
    enableUnityAdapter: raw.enableUnityAdapter === true || raw.enableUnityAdapter === 'true',
    sceneSource: raw.sceneSource === 'llm' ? 'llm' : 'template',
    layoutObjects: pick('layoutObjects'),
    layoutAxis: raw.layoutAxis === 'y-up' ? 'y-up' : 'z-up',
    layoutValidation: mergeValidationOptions(raw.layoutValidation),
    assetLibraryPath: pick('assetLibraryPath'),
    assetModelPath: pick('assetModelPath'),
    enableTextureGeneration: raw.enableTextureGeneration === true || raw.enableTextureGeneration === 'true',
    textureResolution: pickNumber('textureResolution'),
    textureObjects: raw.textureObjects === 'all' ? 'all' : 'main',
    texturePromptPrefix: pick('texturePromptPrefix'),
  }
}

/** 检测结果的初始占位值。 */
function pending() {
  return { status: 'missing', detail: '尚未检测，运行 check_environment 获取最新状态' }
}

/** 让单项检测的异常也变成结构化结果，而不是让 checkAll() 整体失败。 */
async function guard(name, run) {
  try {
    const result = await run()
    if (!result || typeof result !== 'object' || typeof result.status !== 'string') {
      return { status: 'error', detail: `${name} 检测返回了非法结果` }
    }
    return result
  } catch (error) {
    return {
      status: 'error',
      detail: `${name} 检测失败：${error instanceof Error ? error.message : String(error)}`,
    }
  }
}

export class PipelineService {
  constructor(ctx, config) {
    this.ctx = ctx
    // 读取优先级：插件自己的存储文件（设置面板保存的）> apply 收到的 config。
    // 见 lib/store.js 顶部注释：--patch 开发覆盖层下 configEditor 不可写，
    // 所以设置面板的保存以存储文件为准。
    this.storedConfig = readStoredConfig()
    this.config = normalizeConfig({ ...normalizeConfig(config), ...this.storedConfig })
    this.environment = { blender: pending(), comfy: pending(), unity: pending() }
    this.checkedAt = null
  }

  /** 当前环境快照（供工具 / 设置页 / 后续流水线读取）。 */
  getEnvironment() {
    return this.environment
  }

  /** 当前生效配置（已补默认值）。 */
  getConfig() {
    return this.config
  }

  /** 配置文件路径（设置面板用来提示“存到哪了”）。 */
  getConfigFile() {
    return configFilePath()
  }

  /** 流水线产物根目录：配置的 outputDir 优先，否则 $DSH_HOME/scene-skeleton-pipeline/outputs。 */
  getOutputDir() {
    const configured = this.config?.outputDir
    return typeof configured === 'string' && configured !== '' ? configured : outputDirPath()
  }

  /** 设置面板保存后调用：立刻用新配置重跑一次检测。 */
  async updateConfig(next) {
    this.config = normalizeConfig(next)
    return this.checkAll()
  }

  /**
   * 聚合执行三项检测并更新 this.environment，返回结构化结果：
   *   { checkedAt, environment: { blender, comfy, unity } }
   */
  async checkAll() {
    const config = this.config
    const [blender, comfy, unity] = await Promise.all([
      guard('Blender', () => checkBlender(config)),
      guard('ComfyUI', () => checkComfy(config)),
      guard('Unity', () => checkUnity(config)),
    ])
    this.environment = { blender, comfy, unity }
    this.checkedAt = new Date().toISOString()
    return { checkedAt: this.checkedAt, environment: this.environment }
  }
}
