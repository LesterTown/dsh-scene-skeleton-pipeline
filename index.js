/**
 * dsh-scene-skeleton-pipeline — Host 半边入口。
 *
 * 定位：工作流编排插件（ComfyUI → Blender → Unity 场景骨架）。
 * 当前阶段（阶段 2）：配置 schema + pipeline-service + 三项环境检测 + check_environment 工具 +
 * 设置页面板。不启动 Blender / ComfyUI，不调 MCP 桥接，不写流水线引擎。
 *
 * 加载方式（本地开发）：
 *   在仓库根目录用 --patch 覆盖层挂载，见 scratch-plugin/cordis.yml：
 *     dsh --profile web --patch ./scratch-plugin/cordis.yml --no-open --port 0
 */

import z from '@deepseek-ai/schemastery'

import { PipelineService } from './lib/service.js'
import { PipelineEngine } from './lib/pipeline.js'
import { createCheckEnvironmentTool } from './lib/tool.js'
import { createRunPipelineTool } from './lib/pipeline-tool.js'
import { createPlanSceneLayoutTool } from './lib/plan-tool.js'
import { registerSettingsRoutes } from './lib/settings.js'

export const name = 'dsh-scene-skeleton-pipeline'

/** 需要宿主提供的服务：工具注册表（check_environment 工具）。 */
export const inject = ['tools']

/**
 * 插件配置。
 *
 * DSH Loader 按该 schema 校验并补默认值；设置面板保存时走宿主 configEditor，
 * 写入当前 profile 的 patch 层，重启宿主后仍然生效。
 */
export const Config = z.object({
  blenderExe: z
    .string()
    .default('')
    .description('Blender 可执行文件路径；留空则自动探测常见安装位置'),
  comfyUrl: z
    .string()
    .default('http://127.0.0.1:8188')
    .description('ComfyUI 服务地址（默认 http://127.0.0.1:8188）'),
  comfyWorkflowPath: z
    .string()
    .default('')
    .description('ComfyUI API 格式工作流 JSON 路径；留空则使用内置 txt2img 模板'),
  comfyCheckpoint: z
    .string()
    .default('')
    .description('ComfyUI checkpoint 名称；留空则自动取服务端第一个可用模型'),
  comfyNegativePrompt: z
    .string()
    .default('')
    .description('ComfyUI 负向提示词；留空使用内置默认值'),
  unityProjectPath: z
    .string()
    .default('')
    .description('Unity 项目根目录；需包含 ProjectSettings/ProjectVersion.txt'),
  unityExe: z
    .string()
    .default('')
    .description('Unity 可执行文件路径；留空则按工程版本自动探测 /Applications/Unity/Hub/Editor'),
  outputDir: z
    .string()
    .default('')
    .description('流水线产物根目录；留空则使用 $DSH_HOME/scene-skeleton-pipeline/outputs'),
  blenderSceneMode: z
    .string()
    .default('scenic')
    .description('Blender 场景生成模式：scenic（声明式场景，默认）或 legacy（旧固定体块）'),
  scenicWidth: z
    .number()
    .default(24)
    .description('scenic 庭院场景宽度（米）'),
  scenicDepth: z
    .number()
    .default(20)
    .description('scenic 庭院场景深度（米）'),
  scenicWallHeight: z
    .number()
    .default(3.2)
    .description('scenic 庭院场景墙体高度（米）'),
  enableUnityAdapter: z
    .boolean()
    .default(false)
    .description('是否启用 Unity 装配适配器（默认关闭；流水线终点是 Blender，Unity 降级为可选适配器）'),
  sceneSource: z
    .string()
    .default('template')
    .description('Blender 场景来源：template（scenic 模板，默认）或 llm（按 layoutObjects 的精确布局摆放物件）'),
  layoutObjects: z
    .string()
    .default('')
    .description('精确布局 plan 的 JSON 文件路径或内联 JSON；sceneSource=llm 时必填（可用 plan_scene_layout 工具生成）'),
  layoutAxis: z
    .union([z.const('z-up'), z.const('y-up')])
    .default('z-up')
    .description('layout.json 的坐标系：z-up（Blender 原生，默认）或 y-up（Unity 转换值）'),
  layoutValidation: z
    .object({
      maxCollisionOverlap: z.number().default(0.1),
      maxFloatHeight: z.number().default(0.3),
      groundTolerance: z.number().default(0.05),
      sceneBounds: z.array(z.number()).default([-50, 50]),
    })
    .default({})
    .description('布局物理校验参数：碰撞容差 / 悬浮容差 / 地面容差 / 场景边界（米）'),
  assetLibraryPath: z
    .string()
    .default('')
    .description('材质贴图根目录（可选）：配置后 lib/asset-library.json 里 materials 的 albedo/normal/roughness/metallic 路径相对它解析，缺失回退纯色'),
  assetModelPath: z
    .string()
    .default('')
    .description('真实模型根目录（可选）：配置后 lib/asset-library.json 里 assets 的 modelPath 相对它解析，存在则导入 .glb/.gltf 真实模型并贴地+等比缩放，否则回退程序化图元'),
  enableTextureGeneration: z
    .boolean()
    .default(false)
    .description('是否启用 SuperPBR 贴图生成（默认关闭；需要 ComfyUI 侧装好 SuperPBR + MoGe 节点与模型）'),
  textureResolution: z
    .number()
    .default(512)
    .description('贴图生成分辨率（像素，默认 512）'),
  textureObjects: z
    .union([z.const('main'), z.const('all')])
    .default('main')
    .description('贴图对象范围：main=地形与主要建筑（column/wall/archway/gatehouse），all=全部对象'),
  texturePromptPrefix: z
    .string()
    .default('')
    .description('贴图提示词前缀（预留：SuperPBR 不使用提示词，留给后续 CHORD 类模型）'),
})

/**
 * Cordis 插件入口。
 *
 * @param ctx - Cordis context。
 * @param config - 由 Config schema 校验/补默认值后的配置。
 */
export function apply(ctx, config) {
  const service = new PipelineService(ctx, config)
  // 流水线引擎（阶段 3）：dry-run 调度三节点，真实执行留给后续阶段。
  const engine = new PipelineEngine(service)
  // 后续阶段/其他插件可以通过 ctx.get('scenePipeline').pipeline 取到引擎。
  service.pipeline = engine

  // 用户要求：启动时终端能看到加载日志，确认 apply 被执行。
  console.log('[dsh-scene-skeleton-pipeline] loaded')
  try {
    ctx?.logger?.info?.('[dsh-scene-skeleton-pipeline] loaded')
  } catch {
    /* 日志失败不影响插件挂载 */
  }

  // 类形态服务注册：设置页、工具、后续流水线都通过 ctx.get('scenePipeline') 取用。
  ctx.provide('scenePipeline', service)
  console.log(
    '[dsh-scene-skeleton-pipeline] service registered: scenePipeline (comfyUrl=' +
      service.getConfig().comfyUrl +
      ')',
  )

  // 注册 check_environment 工具（纯对象定义，不依赖 @deepseek-ai/dsh-tools）。
  const registry = ctx.get?.('tools') ?? ctx.tools
  if (registry && typeof registry.register === 'function') {
    try {
      const disposeTool = registry.register(createCheckEnvironmentTool(service))
      if (typeof disposeTool === 'function') {
        ctx.effect(() => () => {
          try {
            disposeTool()
          } catch {
            /* 卸载失败不影响宿主退出 */
          }
        }, 'dsh-scene-skeleton-pipeline: check_environment tool')
      }
      console.log('[dsh-scene-skeleton-pipeline] tool registered: check_environment')
    } catch (error) {
      ctx.logger?.warn?.(
        `[dsh-scene-skeleton-pipeline] check_environment 注册失败：${
          error instanceof Error ? error.message : String(error)
        }`,
      )
    }
  } else {
    ctx.logger?.warn?.('[dsh-scene-skeleton-pipeline] 没有 tools 注册表，check_environment 未注册')
  }

  // 注册 run_scene_pipeline 工具（阶段 3：dry-run 调度）。
  if (registry && typeof registry.register === 'function') {
    try {
      const disposeRunTool = registry.register(createRunPipelineTool(engine))
      if (typeof disposeRunTool === 'function') {
        ctx.effect(() => () => {
          try {
            disposeRunTool()
          } catch {
            /* 卸载失败不影响宿主退出 */
          }
        }, 'dsh-scene-skeleton-pipeline: run_scene_pipeline tool')
      }
      console.log(
        '[dsh-scene-skeleton-pipeline] pipeline engine ready: ' +
          engine
            .describe()
            .stages.map(stage => stage.id)
            .join(' -> '),
      )
      console.log('[dsh-scene-skeleton-pipeline] pipeline tool registered: run_scene_pipeline')
    } catch (error) {
      ctx.logger?.warn?.(
        `[dsh-scene-skeleton-pipeline] run_scene_pipeline 注册失败：${
          error instanceof Error ? error.message : String(error)
        }`,
      )
    }
  }

  // 注册 plan_scene_layout 工具（阶段 7：文字 → 精确布局 JSON，供 sceneSource='llm' 使用）。
  if (registry && typeof registry.register === 'function') {
    try {
      const disposePlanTool = registry.register(createPlanSceneLayoutTool({ ctx, service }))
      if (typeof disposePlanTool === 'function') {
        ctx.effect(() => () => {
          try {
            disposePlanTool()
          } catch {
            /* 卸载失败不影响宿主退出 */
          }
        }, 'dsh-scene-skeleton-pipeline: plan_scene_layout tool')
      }
      console.log('[dsh-scene-skeleton-pipeline] plan tool registered: plan_scene_layout')
    } catch (error) {
      ctx.logger?.warn?.(
        `[dsh-scene-skeleton-pipeline] plan_scene_layout 注册失败：${
          error instanceof Error ? error.message : String(error)
        }`,
      )
    }
  }

  // 设置页的宿主半边：/plugins/dsh-scene-skeleton-pipeline/{state,check,config,/}
  // 必须用 ctx.inject(['webServer']) 等 webServer 就绪：宿主启动顺序里本插件先于
  // web server 的异步 listen 完成，直接 ctx.get('webServer') 会拿到 undefined。
  ctx.inject(['webServer'], webCtx => {
    try {
      const disposers = registerSettingsRoutes(webCtx, service, engine)
      for (const dispose of disposers) {
        if (typeof dispose === 'function') {
          webCtx.effect(() => () => {
            try {
              dispose()
            } catch {
              /* 卸载失败不影响宿主退出 */
            }
          }, 'dsh-scene-skeleton-pipeline: settings route')
        }
      }
      if (disposers.length > 0) {
        console.log(
          '[dsh-scene-skeleton-pipeline] settings routes registered: /plugins/dsh-scene-skeleton-pipeline/{state,check,config,pipeline/run,pipeline/jobs,/}',
        )
      }
    } catch (error) {
      console.log(
        '[dsh-scene-skeleton-pipeline] settings routes failed: ' +
          (error instanceof Error ? error.message : String(error)),
      )
    }
  })

  // 启动时先跑一次检测，把结果写进日志（验收脚本靠这一行断言）。
  void service.checkAll().then(
    result => {
      console.log(
        '[dsh-scene-skeleton-pipeline] environment ' + JSON.stringify(result.environment),
      )
    },
    error => {
      console.log(
        '[dsh-scene-skeleton-pipeline] environment-error ' +
          (error instanceof Error ? error.message : String(error)),
      )
    },
  )

  ctx.effect(() => () => {
    console.log('[dsh-scene-skeleton-pipeline] unloaded')
  })
}
