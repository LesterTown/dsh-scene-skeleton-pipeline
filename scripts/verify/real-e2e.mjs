/**
 * 真实端到端验收脚本（阶段 5）：不经过 Web 宿主，直接经 run_scene_pipeline 工具跑
 * ComfyUI 出图 → Blender 生成场景骨架 + layout.json → Unity batchmode 按布局装配场景。
 *
 * 产出：<outputDir>/last-job.json（引擎 job）与 last-tool-result.json（工具返回值，
 * 含 summary / artifacts），供 verify-step* / verify-unity-adapter 断言。
 *
 * 用法：
 *   [DSH_UNITY_ADAPTER=1] node scripts/verify/real-e2e.mjs [unityProjectPath] [outputDir] [prompt] [blenderSceneMode]
 *
 * blenderSceneMode：'scenic'（默认，scenic-bpy 声明式场景）或 'legacy'（旧固定体块）。
 *
 * Unity 装配需要显式设置 DSH_UNITY_ADAPTER=1（可选 Unity 适配器）；不设置时流水线终点是
 * Blender，只产出 scene.blend/.fbx/.glb + layout.json（引擎无关核心链路）。
 *
 * 前提：本机 ComfyUI 已在 http://127.0.0.1:8188 运行。
 */
import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { PipelineService } from '../../lib/service.js'
import { PipelineEngine } from '../../lib/pipeline.js'
import { createRunPipelineTool } from '../../lib/pipeline-tool.js'

const unityProjectPath = process.argv[2] || ''
const outputDir = process.argv[3] || '/tmp/dsh-scene-e2e'
const prompt =
  process.argv[4] ||
  'a small stone shrine in a forest clearing, moss covered, isometric concept art'
const blenderSceneMode = process.argv[5] || 'scenic'
const enableUnityAdapter = process.env.DSH_UNITY_ADAPTER === '1'

if (enableUnityAdapter && !unityProjectPath) {
  console.error('设置 DSH_UNITY_ADAPTER=1 时必须提供 unityProjectPath')
  process.exit(2)
}

const service = new PipelineService(null, {
  comfyUrl: 'http://127.0.0.1:8188',
  comfyCheckpoint: 'DreamShaper_8_pruned.safetensors',
  unityProjectPath,
  outputDir,
  blenderSceneMode,
  enableUnityAdapter,
  // 可选 SuperPBR 贴图（默认关闭；验证脚本用环境变量开启）
  enableTextureGeneration: process.env.DSH_ENABLE_TEXTURE === '1',
  textureResolution: Number.parseInt(process.env.DSH_TEXTURE_RESOLUTION || '512', 10) || 512,
  textureObjects: process.env.DSH_TEXTURE_OBJECTS === 'all' ? 'all' : 'main',
  // 场景来源（llm 精确布局 / template 模板）
  sceneSource: process.env.DSH_SCENE_SOURCE === 'llm' ? 'llm' : 'template',
  layoutObjects: process.env.DSH_LAYOUT_OBJECTS || '',
  // 可选材质映射（贴图根目录；空=纯色 fallback）
  assetLibraryPath: process.env.DSH_ASSET_LIBRARY || '',
  // 可选几何模型映射（真实 .glb/.gltf 根目录；空=全部程序化图元）
  assetModelPath: process.env.DSH_ASSET_MODEL || '',
})
const engine = new PipelineEngine(service, { maxJobs: 5 })

const environment = await service.checkAll()
console.log('environment:', JSON.stringify(environment.environment, null, 2))
const required = enableUnityAdapter ? ['blender', 'comfy', 'unity'] : ['blender', 'comfy']
const notOk = Object.entries(environment.environment)
  .filter(([name]) => required.includes(name))
  .filter(([, item]) => item.status !== 'ok')
if (notOk.length > 0) {
  console.error('环境未就绪:', notOk.map(([name, item]) => `${name}=${item.status} (${item.detail})`).join('; '))
  process.exit(1)
}

console.log('开始真实执行…（经由 run_scene_pipeline 工具）')
const started = Date.now()
const tool = createRunPipelineTool(engine)
const toolResult = await tool.execute({ prompt, dryRun: false })
const job = engine.getLastJob()
console.log('job status:', job.status, '耗时', Math.round((Date.now() - started) / 1000), '秒')
for (const stage of job.stages) {
  console.log(`\n[${stage.id}] ${stage.status} — ${stage.detail ?? ''}`)
  for (const line of stage.logs ?? []) console.log('   ', line)
  for (const artifact of stage.artifacts ?? []) console.log('    artifact:', artifact.kind, artifact.path)
}
console.log('\nartifacts:', JSON.stringify(job.artifacts ?? {}, null, 2))
console.log('summary:', JSON.stringify(job.summary ?? null, null, 2))
if (job.status !== 'done') {
  console.log('failedStage:', job.failedStage ?? '(none)')
  for (const line of (job.failedLogs ?? []).slice(-8)) console.log('  ', line)
}
console.log('job dir:', job.jobDir ?? '(none)')
mkdirSync(outputDir, { recursive: true })
writeFileSync(join(outputDir, 'last-job.json'), JSON.stringify(job, null, 2))
writeFileSync(join(outputDir, 'last-tool-result.json'), JSON.stringify(toolResult, null, 2))
console.log('job json:', join(outputDir, 'last-job.json'))
console.log('tool result json:', join(outputDir, 'last-tool-result.json'))
process.exit(toolResult.ok === true ? 0 : 1)
