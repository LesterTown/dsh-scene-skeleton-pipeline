/**
 * verify-layout-axis.sh 的 Node 探针：验证 layoutAxis（z-up / y-up）的坐标语义。
 *
 * 覆盖：
 *   [1] sceneSource=template，z-up 与 y-up 各跑一次 Blender stage
 *   [2] layout.json 的 axis 字段、root/groups/objectCount 一致性
 *   [3] 相机：z-up 是 Blender 原生坐标，y-up 是 (x, z, -y) 转换值
 *   [4] 对象：z-up 与 y-up 位置互为 (x, y, z) ↔ (x, z, -y)
 *   [5] sceneSource=llm，z-up/y-up 同样成立
 *   [6] adapter 层转换：layoutZupToYup(z-up layout) 与 Blender 直接产出的 y-up layout 一致
 *   [7] summary.layoutAxis / 工具返回的 summary.layoutAxis
 *   [8] 非法 layoutAxis 被拒绝
 *
 * 用法：node layout-axis-probe.mjs <工作目录>
 * 输出：每行 PASS/FAIL，最后一行 `probe: PASS=n FAIL=m`。
 */
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import { runBlenderStage } from '../../lib/executors/blender.js'
import { runProcess } from '../../lib/executors/process.js'
import { buildJobSummary } from '../../lib/pipeline.js'
import { toToolResult } from '../../lib/pipeline-tool.js'
import { layoutZupToYup } from '../../adapters/unity/unity.js'

const work = process.argv[2] || mkdtempSync(join(tmpdir(), 'dsh-axis-probe.'))
mkdirSync(work, { recursive: true })

let pass = 0
let fail = 0
function check(name, ok, detail = '') {
  if (ok) {
    pass += 1
    console.log(`PASS  ${name}${detail ? `（${detail}）` : ''}`)
  } else {
    fail += 1
    console.log(`FAIL  ${name}${detail ? `（${detail}）` : ''}`)
  }
}

const round = (value, digits = 3) => Math.round(value * 10 ** digits) / 10 ** digits
const close = (a, b, tolerance = 0.01) => Math.abs(a - b) <= tolerance
const closeVec = (a, b, tolerance = 0.01) => Array.isArray(a) && a.length === 3 && a.every((v, i) => close(v, b[i], tolerance))
const sameSet = (a, b) => a.length === b.length && a.every(item => b.includes(item))

function baseConfig(extra) {
  return {
    blenderSceneMode: 'scenic',
    scenicWidth: 24,
    scenicDepth: 20,
    scenicWallHeight: 3.2,
    sceneSource: 'template',
    layoutAxis: 'z-up',
    ...extra,
  }
}

function serviceFor(config) {
  return { getConfig: () => config }
}

const blender = { path: process.env.DSH_BLENDER_EXE || '/Applications/Blender.app/Contents/MacOS/Blender' }
const prompt = 'a quiet courtyard with stone walls, isometric view'

async function runTemplate(axis) {
  const jobDir = join(work, `template-${axis}`)
  const outcome = await runBlenderStage({
    service: serviceFor(baseConfig({ layoutAxis: axis })),
    jobDir,
    prompt,
    artifacts: [],
    onLog: () => {},
  })
  const layout = JSON.parse(readFileSync(outcome.artifacts.find(item => item.kind === 'layout').path, 'utf8'))
  return { outcome, layout }
}

async function runLlm(axis) {
  const jobDir = join(work, `llm-${axis}`)
  const planPath = join(work, 'plan.json')
  const outcome = await runBlenderStage({
    service: serviceFor(baseConfig({ layoutAxis: axis, sceneSource: 'llm', layoutObjects: planPath })),
    jobDir,
    prompt,
    artifacts: [],
    onLog: () => {},
  })
  const layout = JSON.parse(readFileSync(outcome.artifacts.find(item => item.kind === 'layout').path, 'utf8'))
  return { outcome, layout }
}

function objectsByName(layout) {
  const map = {}
  for (const group of layout.groups) for (const object of group.objects) map[object.instanceName] = object
  return map
}

try {
  // 小 plan：喷泉居中 + 两根柱 + 一棵树（互不重叠、都在 24×20 内）
  writeFileSync(
    join(work, 'plan.json'),
    JSON.stringify(
      {
        sceneName: 'AxisTest',
        bounds: { width: 24, depth: 20 },
        objects: [
          { id: 'fountain_01', type: 'fountain', position: [0, 0, 0], size: [4, 0.8, 4] },
          { id: 'column_01', type: 'column', position: [-6, 0, -5], size: [0.8, 3.5, 0.8] },
          { id: 'column_02', type: 'column', position: [6, 0, -5], size: [0.8, 3.5, 0.8] },
          { id: 'tree_01', type: 'tree', position: [0, 0, 6], size: [3, 5, 3] },
        ],
      },
      null,
      2,
    ),
    'utf8',
  )

  // ---- [1]/[2]/[3]/[4] template 模式 ----
  const z = await runTemplate('z-up')
  const y = await runTemplate('y-up')

  check('template: z-up layout.axis', z.layout.axis === 'z-up', `axis=${z.layout.axis}`)
  check('template: y-up layout.axis', y.layout.axis === 'y-up', `axis=${y.layout.axis}`)
  check('template: root 一致', z.layout.root === y.layout.root, z.layout.root)
  const zGroups = z.layout.groups.map(group => group.name)
  const yGroups = y.layout.groups.map(group => group.name)
  check('template: groups 一致', sameSet(zGroups, yGroups), zGroups.join('/'))
  const zCount = z.layout.groups.reduce((total, group) => total + group.objects.length, 0)
  const yCount = y.layout.groups.reduce((total, group) => total + group.objects.length, 0)
  check('template: objectCount 一致', zCount === yCount, `${zCount} vs ${yCount}`)
  const kinds = new Set(z.outcome.artifacts.map(item => item.kind))
  check(
    'template: 真实产物齐全（blend/fbx/glb/layout）',
    ['blend', 'mesh', 'glb', 'layout'].every(kind => kinds.has(kind)),
    [...kinds].join('/'),
  )

  // 相机：z-up 是 Blender 原生；y-up 是 (x, z, -y)
  const zCam = z.layout.camera.position
  const yCam = y.layout.camera.position
  check('template: z-up 相机位置 ≠ y-up 相机位置（语义不同）', !closeVec(zCam, yCam))
  check(
    'template: 相机坐标互为 (x, y, z) ↔ (x, z, -y)',
    closeVec(zCam, [yCam[0], -yCam[2], yCam[1]]),
    `${JSON.stringify(zCam)} ↔ ${JSON.stringify(yCam)}`,
  )
  check('template: lookAt 同理', closeVec(z.layout.camera.lookAt, [y.layout.camera.lookAt[0], -y.layout.camera.lookAt[2], y.layout.camera.lookAt[1]]))

  // 对象坐标关系
  const zObjects = objectsByName(z.layout)
  const yObjects = objectsByName(y.layout)
  const shared = Object.keys(zObjects).filter(name => yObjects[name])
  const mismatched = shared.filter(name => {
    const zp = zObjects[name].position
    const yp = yObjects[name].position
    return !closeVec(zp, [yp[0], -yp[2], yp[1]])
  })
  check('template: 全部对象坐标互为 (x, y, z) ↔ (x, z, -y)', mismatched.length === 0, `${shared.length} 个对象，异常 ${mismatched.length}`)

  // ---- [5] llm 模式 ----
  const lz = await runLlm('z-up')
  const ly = await runLlm('y-up')
  check('llm: z-up layout.axis', lz.layout.axis === 'z-up', `axis=${lz.layout.axis}`)
  check('llm: y-up layout.axis', ly.layout.axis === 'y-up', `axis=${ly.layout.axis}`)
  const lzObjects = objectsByName(lz.layout)
  const lyObjects = objectsByName(ly.layout)
  const planObjects = [
    ['fountain_01', [0, 0, 0]],
    ['column_01', [-6, 0, -5]],
    ['column_02', [6, 0, -5]],
    ['tree_01', [0, 0, 6]],
  ]
  const planOk = planObjects.every(([name, position]) => {
    const zp = lzObjects[name]?.position
    const yp = lyObjects[name]?.position
    // plan 是 Unity Y-up；z-up layout = Blender 原生 (x, -z, y)，y-up layout = plan 原值
    return (
      zp &&
      yp &&
      closeVec(zp, [position[0], -position[2], position[1]]) &&
      closeVec(yp, position) &&
      closeVec(zp, [yp[0], -yp[2], yp[1]])
    )
  })
  check('llm: plan 坐标 → z-up（Blender 原生）/ y-up（plan 原值）都正确', planOk)
  check(
    'llm: root/groups 一致',
    lz.layout.root === ly.layout.root && sameSet(lz.layout.groups.map(group => group.name), ly.layout.groups.map(group => group.name)),
  )

  // ---- [6] adapter 转换与 Blender 直接产出的 y-up 一致 ----
  const converted = layoutZupToYup(z.layout)
  const convertedObjects = objectsByName(converted)
  const convertedMismatch = shared.filter(name => !closeVec(convertedObjects[name].position, yObjects[name].position))
  check('adapter: layoutZupToYup 位置与 Blender 直出 y-up 一致', convertedMismatch.length === 0, `异常 ${convertedMismatch.length}`)
  check(
    'adapter: 相机与光照转换一致',
    closeVec(converted.camera.position, yCam) && closeVec(converted.lighting.directional.rotation, y.layout.lighting.directional.rotation),
  )
  check('adapter: 转换后 axis=y-up', converted.axis === 'y-up')

  // ---- [7] summary.layoutAxis ----
  const summary = buildJobSummary([
    { id: 'comfy', status: 'ok', artifacts: [], report: null },
    {
      id: 'blender',
      status: 'ok',
      artifacts: z.outcome.artifacts,
      report: {
        mode: 'scenic',
        axis: z.layout.axis,
        root: z.layout.root,
        groups: zGroups,
        objectCount: zCount,
        layoutPath: z.outcome.report.layoutPath,
      },
    },
  ])
  check('summary: buildJobSummary 带 layoutAxis', summary?.layoutAxis === 'z-up', `layoutAxis=${summary?.layoutAxis}`)
  const toolResult = toToolResult({ id: 'job-test', status: 'done', stages: [], artifacts: {}, summary, failedStage: null, failedLogs: [] })
  check('summary: run_scene_pipeline 工具结果带 layoutAxis', toolResult.summary.layoutAxis === 'z-up')

  // ---- [8] 非法 layoutAxis 被 Blender 拒绝（绕过 JS 层归一，直接跑 run_scenic.py） ----
  const invalid = await runProcess(
    blender.path,
    [
      '--background',
      '--factory-startup',
      '--python',
      fileURLToPath(new URL('../../lib/scripts/run_scenic.py', import.meta.url)),
      '--',
      fileURLToPath(new URL('../../lib/scripts/scenes/courtyard.py', import.meta.url)),
      join(work, 'invalid', 'scene.blend'),
      join(work, 'invalid', 'scene.glb'),
      join(work, 'invalid', 'scene.fbx'),
      join(work, 'invalid', 'layout.json'),
      JSON.stringify({ seed: 1, layoutAxis: 'x-up' }),
    ],
    { timeoutMs: 180000 },
  )
  const invalidOutput = `${invalid.stdout}\n${invalid.stderr}`
  const invalidLayoutWritten = existsSync(join(work, 'invalid', 'layout.json'))
  check(
    '非法 layoutAxis（x-up）被 Blender 拒绝',
    /未知的 layoutAxis/.test(invalidOutput) && !invalidLayoutWritten,
    `exit=${invalid.code}，layout 已写出=${invalidLayoutWritten}`,
  )
} finally {
  if (!process.argv[2]) rmSync(work, { recursive: true, force: true })
}

console.log(`probe: PASS=${pass} FAIL=${fail}`)
process.exit(fail === 0 ? 0 : 1)
