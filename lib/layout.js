/**
 * 布局 JSON（layout.json）契约 —— 阶段 5。
 *
 * Blender 阶段在导出 .fbx 的同时写出一份 layout.json，Unity 阶段按它装配场景：
 * 建根节点 → 按 groups 建分组空节点 → 逐 objects[] 放置网格实例 → 光照 → 相机，
 * 可选把整棵树存成 prefab。坐标已经是 **Unity 空间（Y 轴向上、米制）**，
 * Blender 侧负责把 Z-up 转换好，Unity 侧直接赋值即可。
 *
 * 结构（首版契约，不要加交互/导航/碰撞字段）：
 *
 * {
 *   "sceneName": "SceneSkeleton",                       // 场景名，也是 prefab 文件名
 *   "root": "SceneSkeleton_Root",                       // 根节点名
 *   "groups": [                                         // 分组（顺序即 Unity 层级顺序）
 *     {
 *       "name": "Terrain",                              // Terrain / Props / Reference
 *       "objects": [
 *         {
 *           "asset": "scene_skeleton.fbx",              // 工程内资源：相对 Assets/ 或文件名
 *           "instanceName": "Ground",                   // 实例名，也是 fbx 内部节点名
 *           "position": [0, 0, 0],                      // 米制，Unity 世界坐标
 *           "rotation": [0, 0, 0],                      // Unity Euler 角度（ZXY 顺序）
 *           "scale": [1, 1, 1]                          // 实例额外缩放（相对资产自身变换，按乘法应用；
 *                                                       //   Blender 已把物体 scale 烘进几何，生成值恒为 1）
 *         }
 *       ]
 *     }
 *   ],
 *   "lighting": {
 *     "ambient":     { "intensity": 0.4, "color": [1, 1, 1] },     // 环境光（Unity flat ambient）
 *     "directional": { "intensity": 1.0, "rotation": [50, -30, 0], // 方向光 Euler 角度
 *                      "color": [1, 1, 1] },
 *     "skybox": "default" | null                                   // "default"=Unity 默认天空盒，null=不设
 *   },
 *   "camera": { "position": [0, 5, -10], "lookAt": [0, 0, 0] },    // Main Camera 位置与朝向
 *   "prefab": { "enabled": false, "path": "Assets/Prefabs/" }      // enabled 时存 <path>/<sceneName>.prefab
 * }
 *
 * 约束：
 * - groups[].name 非空；同一个 layout 里 instanceName 唯一（Unity 侧按名字从 fbx 里取节点）。
 * - position/rotation/scale/color 必须是长度 3 的数字数组。
 * - 解析/校验失败不应静默：unity.js 会在启动 Unity 之前先校验，并给出可定位的错误。
 */

import { readFileSync } from 'node:fs'

export const LAYOUT_SCENE_NAME = 'SceneSkeleton'
export const LAYOUT_ROOT = 'SceneSkeleton_Root'
export const LAYOUT_GROUP_NAMES = ['Terrain', 'Props', 'Reference']

/** layout.json 的坐标系枚举：z-up = Blender 原生；y-up = Unity 转换值。 */
export const LAYOUT_AXES = ['z-up', 'y-up']

const DEFAULT_LIGHTING = {
  ambient: { intensity: 0.4, color: [1, 1, 1] },
  directional: { intensity: 1.0, rotation: [50, -30, 0], color: [1, 1, 1] },
  skybox: 'default',
}

const DEFAULT_CAMERA = { position: [0, 5, -10], lookAt: [0, 0, 0] }

function isVec3(value) {
  return Array.isArray(value) && value.length === 3 && value.every(item => typeof item === 'number' && Number.isFinite(item))
}

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value)
}

/** 与 Python 侧 _fmt 对齐：最多 3 位小数、去掉末尾 0。 */
function fmt(value) {
  return String(Number(Number(value).toFixed(3)))
}

function sourceName(object) {
  return object && typeof object === 'object' && typeof object.instanceName === 'string' && object.instanceName !== ''
    ? object.instanceName
    : ''
}

/**
 * 校验 layout 结构，返回错误列表（空数组表示通过）。
 *
 * @param {unknown} layout
 * @returns {string[]} 人类可读的错误列表
 */
export function validateLayout(layout) {
  const errors = []
  if (layout === null || typeof layout !== 'object' || Array.isArray(layout)) {
    return ['layout 必须是对象']
  }
  if (typeof layout.root !== 'string' || layout.root.trim() === '') errors.push('root 必须是非空字符串')
  if (layout.axis !== undefined && !LAYOUT_AXES.includes(layout.axis)) {
    errors.push(`axis 必须是 ${LAYOUT_AXES.join(' / ')} 之一`)
  }
  if (layout.sceneName !== undefined && (typeof layout.sceneName !== 'string' || layout.sceneName.trim() === '')) {
    errors.push('sceneName 必须是非空字符串')
  }
  if (!Array.isArray(layout.groups) || layout.groups.length === 0) {
    errors.push('groups 必须是非空数组')
    return errors
  }

  const seen = new Set()
  layout.groups.forEach((group, groupIndex) => {
    const where = `groups[${groupIndex}]`
    if (group === null || typeof group !== 'object') {
      errors.push(`${where} 必须是对象`)
      return
    }
    if (typeof group.name !== 'string' || group.name.trim() === '') errors.push(`${where}.name 必须是非空字符串`)
    if (!Array.isArray(group.objects)) {
      errors.push(`${where}.objects 必须是数组`)
      return
    }
    group.objects.forEach((object, objectIndex) => {
      const at = `${where}.objects[${objectIndex}]`
      if (object === null || typeof object !== 'object') {
        errors.push(`${at} 必须是对象`)
        return
      }
      const name = sourceName(object)
      if (name === '') errors.push(`${at}.instanceName 必须是非空字符串`)
      else if (seen.has(name)) errors.push(`${at}.instanceName 重复：${name}`)
      else seen.add(name)
      if (typeof object.asset !== 'string' || object.asset.trim() === '') errors.push(`${at}.asset 必须是非空字符串`)
      if (!isVec3(object.position)) errors.push(`${at}.position 必须是长度 3 的数字数组`)
      if (object.rotation !== undefined && !isVec3(object.rotation)) errors.push(`${at}.rotation 必须是长度 3 的数字数组`)
      if (object.scale !== undefined && !isVec3(object.scale)) errors.push(`${at}.scale 必须是长度 3 的数字数组`)
    })
  })

  const lighting = layout.lighting
  if (lighting !== undefined && lighting !== null) {
    if (typeof lighting !== 'object') {
      errors.push('lighting 必须是对象')
    } else {
      if (lighting.ambient !== undefined) {
        if (lighting.ambient === null || typeof lighting.ambient !== 'object') errors.push('lighting.ambient 必须是对象')
        else if (!isVec3(lighting.ambient.color)) errors.push('lighting.ambient.color 必须是长度 3 的数字数组')
      }
      if (lighting.directional !== undefined) {
        if (lighting.directional === null || typeof lighting.directional !== 'object') {
          errors.push('lighting.directional 必须是对象')
        } else {
          if (!isVec3(lighting.directional.rotation)) errors.push('lighting.directional.rotation 必须是长度 3 的数字数组')
          if (!isVec3(lighting.directional.color)) errors.push('lighting.directional.color 必须是长度 3 的数字数组')
        }
      }
      if (lighting.skybox !== undefined && lighting.skybox !== null && lighting.skybox !== 'default') {
        errors.push('lighting.skybox 只能是 "default" 或 null')
      }
    }
  }

  if (layout.camera !== undefined && layout.camera !== null) {
    if (typeof layout.camera !== 'object') errors.push('camera 必须是对象')
    else {
      if (!isVec3(layout.camera.position)) errors.push('camera.position 必须是长度 3 的数字数组')
      if (!isVec3(layout.camera.lookAt)) errors.push('camera.lookAt 必须是长度 3 的数字数组')
    }
  }

  if (layout.prefab !== undefined && layout.prefab !== null) {
    if (typeof layout.prefab !== 'object') errors.push('prefab 必须是对象')
    else {
      if (layout.prefab.enabled !== undefined && typeof layout.prefab.enabled !== 'boolean') {
        errors.push('prefab.enabled 必须是布尔值')
      }
      if (layout.prefab.path !== undefined && typeof layout.prefab.path !== 'string') {
        errors.push('prefab.path 必须是字符串')
      }
    }
  }

  return errors
}

/**
 * 把 layout 规范化成 Unity 侧可用的形状：补默认值、取整校验过的数组。
 * 调用前应先用 validateLayout 校验。
 *
 * @param {object} layout
 * @returns {object} 规范化后的 layout（深拷贝）
 */
export function normalizeLayout(layout) {
  const errors = validateLayout(layout)
  if (errors.length > 0) {
    throw new Error(`layout.json 不合法：${errors.slice(0, 6).join('；')}`)
  }
  const lighting = layout.lighting ?? DEFAULT_LIGHTING
  const ambient = lighting.ambient ?? DEFAULT_LIGHTING.ambient
  const directional = lighting.directional ?? DEFAULT_LIGHTING.directional
  const camera = layout.camera ?? DEFAULT_CAMERA
  const prefab = layout.prefab ?? { enabled: false, path: 'Assets/Prefabs/' }

  const groups = layout.groups.map(group => ({
    name: group.name,
    objects: group.objects.map(object => ({
      asset: object.asset,
      instanceName: object.instanceName,
      position: object.position.slice(),
      rotation: (object.rotation ?? [0, 0, 0]).slice(),
      scale: (object.scale ?? [1, 1, 1]).slice(),
    })),
  }))

  return {
    sceneName: typeof layout.sceneName === 'string' && layout.sceneName.trim() !== '' ? layout.sceneName : 'SceneSkeleton',
    root: layout.root,
    // 旧版 layout.json 没有 axis 字段（历史产物都是 Unity Y-up），缺失时按 y-up 处理
    axis: layout.axis === 'z-up' ? 'z-up' : 'y-up',
    groups,
    lighting: {
      ambient: { intensity: typeof ambient.intensity === 'number' ? ambient.intensity : 0.4, color: ambient.color.slice() },
      directional: {
        intensity: typeof directional.intensity === 'number' ? directional.intensity : 1,
        rotation: directional.rotation.slice(),
        color: directional.color.slice(),
      },
      skybox: lighting.skybox === undefined ? 'default' : lighting.skybox,
    },
    camera: { position: camera.position.slice(), lookAt: camera.lookAt.slice() },
    prefab: { enabled: prefab.enabled === true, path: typeof prefab.path === 'string' && prefab.path !== '' ? prefab.path : 'Assets/Prefabs/' },
  }
}

/**
 * 从 layout 统计装配概览，供 pipeline / 工具 / 面板展示。
 *
 * @param {object} layout
 * @returns {{ sceneName: string, root: string, objectCount: number, groups: string[], groupsDetail: Array<{name: string, objects: string[]}> }}
 */
export function layoutSummary(layout) {
  const groupsDetail = (layout.groups ?? []).map(group => ({
    name: group.name,
    objects: (group.objects ?? []).map(object => object.instanceName),
  }))
  return {
    sceneName: layout.sceneName ?? LAYOUT_SCENE_NAME,
    root: layout.root ?? LAYOUT_ROOT,
    objectCount: groupsDetail.reduce((total, group) => total + group.objects.length, 0),
    groups: groupsDetail.map(group => group.name),
    groupsDetail,
  }
}

// ---------------------------------------------------------------------------
// 精确布局计划（plan）：sceneSource='llm' 时由模型生成、经校验后交给 Blender。
//
// plan 与 layout.json 使用同一套坐标语义：Unity Y-up、单位米。
// position 是物体的**底面中心**（y=0 贴地），size 是完整尺寸（sx, sy, sz）。
//
// 形状：
// {
//   "sceneName": "LLMScene",            // 可选
//   "bounds": { "width": 24, "depth": 20 },  // 可选，原点居中
//   "objects": [
//     { "id": "column_01", "type": "column",
//       "position": [0, 0, 0], "size": [0.6, 3, 0.6],
//       "rotation": [0, 0, 0], "group": "Buildings" }
//   ]
// }
// ---------------------------------------------------------------------------

/**
 * 语义资产库（唯一事实源）：lib/asset-library.json。
 * type 白名单 / 分组 / 尺寸范围 / 默认尺寸 / 几何定义都从它派生，新增 type 不需要改这个文件。
 */
export const ASSET_LIBRARY = JSON.parse(
  readFileSync(new URL('./asset-library.json', import.meta.url), 'utf8'),
)

/** type → 资产库条目（含 category / sizeRange / defaultSize / geometry / placement）。 */
export const ASSET_BY_TYPE = Object.fromEntries(ASSET_LIBRARY.assets.map(entry => [entry.type, entry]))

export const PLAN_TYPES = ASSET_LIBRARY.assets.map(entry => entry.type)

export const PLAN_GROUP_BY_TYPE = Object.fromEntries(
  ASSET_LIBRARY.assets.map(entry => [entry.type, entry.category]),
)

/** 各类型的尺寸范围：height = size[1]；footprint = max(size[0], size[2])；min = 每个分量的下限。 */
export const PLAN_SIZE_RANGES = Object.fromEntries(
  ASSET_LIBRARY.assets.map(entry => [
    entry.type,
    {
      height: [...entry.sizeRange.height],
      footprint: [...entry.sizeRange.footprint],
      min: entry.sizeRange.min,
    },
  ]),
)

export const PLAN_MAX_OBJECTS = 120
export const PLAN_OVERLAP_TOLERANCE = 0.02
export const PLAN_GROUND_TOLERANCE = 0.01
export const DEFAULT_PLAN_BOUNDS = { width: 24, depth: 20 }

/** 类型允许的摆放面（来自资产库 placement）。 */
export const PLAN_PLACEMENT_BY_TYPE = Object.fromEntries(
  ASSET_LIBRARY.assets.map(entry => [entry.type, Array.isArray(entry.placement) ? entry.placement : ['ground']]),
)

/** 物理校验默认参数（可由 layoutValidation 配置覆盖）。 */
export const DEFAULT_LAYOUT_VALIDATION = {
  maxCollisionOverlap: 0.1,
  maxFloatHeight: 0.3,
  groundTolerance: 0.05,
  sceneBounds: [-50, 50],
}

/** 允许脱离地面摆放的 placement 取值。 */
export const EXEMPT_PLACEMENTS = ['wall', 'ceiling']

/**
 * 把配置里的 layoutValidation 合并到默认参数上。
 *
 * @param {object} [rawOptions]
 * @returns {{maxCollisionOverlap:number,maxFloatHeight:number,groundTolerance:number,sceneBounds:number[]}}
 */
export function mergeValidationOptions(rawOptions) {
  const merged = { ...DEFAULT_LAYOUT_VALIDATION, sceneBounds: [...DEFAULT_LAYOUT_VALIDATION.sceneBounds] }
  if (!rawOptions || typeof rawOptions !== 'object') {
    return merged
  }
  for (const key of ['maxCollisionOverlap', 'maxFloatHeight', 'groundTolerance']) {
    const value = rawOptions[key]
    if (isFiniteNumber(value) && value >= 0) {
      merged[key] = value
    }
  }
  const sceneBounds = rawOptions.sceneBounds
  if (
    Array.isArray(sceneBounds) &&
    sceneBounds.length === 2 &&
    sceneBounds.every(isFiniteNumber) &&
    sceneBounds[0] < sceneBounds[1]
  ) {
    merged.sceneBounds = [sceneBounds[0], sceneBounds[1]]
  }
  return merged
}

/**
 * 校验布局计划（结构 + 物理合理性），返回结构化结果。
 *
 * 物理规则（AABB 级，不做物理模拟）：
 * - bounds：世界包围盒不得超出 sceneBounds；
 * - ground：底部不得沉入地面（groundTolerance）；
 * - float：底部不得高于 maxFloatHeight，placement 含 wall/ceiling 的豁免；
 * - collision：三轴重叠都超过 maxCollisionOverlap 判为碰撞；
 * - support：placement 含 on_surface 的悬空对象必须有支撑面。
 *
 * @param {object} plan
 * @param {object} [rawOptions] layoutValidation 配置
 * @returns {{ok:boolean, errors:Array<{rule:string,message:string,objects:string[]}>}}
 */
export function validatePlanDetailed(plan, rawOptions) {
  const options = mergeValidationOptions(rawOptions)
  const { maxCollisionOverlap, maxFloatHeight, groundTolerance } = options
  const [sceneMin, sceneMax] = options.sceneBounds
  const errors = []
  const add = (rule, message, objects = []) => errors.push({ rule, message, objects })

  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) {
    add('schema', 'plan 必须是一个 JSON 对象')
    return { ok: false, errors }
  }

  const bounds = plan.bounds ?? DEFAULT_PLAN_BOUNDS
  if (plan.bounds !== undefined) {
    if (!plan.bounds || typeof plan.bounds !== 'object') {
      add('schema', 'bounds 必须是 {width, depth} 对象')
    } else {
      for (const key of ['width', 'depth']) {
        const value = plan.bounds[key]
        if (!isFiniteNumber(value) || value < 1 || value > 200) {
          add('schema', `bounds.${key} 必须是 1–200 之间的数字`)
        }
      }
    }
  }

  if (plan.sceneName !== undefined && (typeof plan.sceneName !== 'string' || plan.sceneName.trim() === '')) {
    add('schema', 'sceneName 必须是非空字符串')
  }

  if (!Array.isArray(plan.objects) || plan.objects.length === 0) {
    add('schema', 'objects 必须是非空数组')
    return { ok: false, errors }
  }
  if (plan.objects.length > PLAN_MAX_OBJECTS) {
    add('schema', `objects 数量不能超过 ${PLAN_MAX_OBJECTS}（当前 ${plan.objects.length}）`)
  }

  const seenIds = new Set()
  const boxes = []
  const allowedGroups = [...new Set(ASSET_LIBRARY.assets.map(entry => entry.category))]

  plan.objects.forEach((object, index) => {
    if (!object || typeof object !== 'object') {
      add('schema', `objects[${index}] 必须是对象`)
      return
    }
    const label = typeof object.id === 'string' && object.id !== '' ? object.id : `objects[${index}]`
    if (typeof object.id !== 'string' || object.id.trim() === '') {
      add('schema', `objects[${index}].id 必须是非空字符串`)
    } else if (/\s/.test(object.id) || object.id.length > 64) {
      add('schema', `${label}.id 不能包含空白字符且长度不超过 64`, [label])
    } else if (seenIds.has(object.id)) {
      add('schema', `${label}.id 重复`, [label])
    } else {
      seenIds.add(object.id)
    }

    if (!PLAN_TYPES.includes(object.type)) {
      add('schema', `${label}.type 必须是 ${PLAN_TYPES.join('/')} 之一（当前 ${String(object.type)}）`, [label])
      return
    }
    const ranges = PLAN_SIZE_RANGES[object.type]

    if (!isVec3(object.position)) {
      add('schema', `${label}.position 必须是 3 个数字`, [label])
      return
    }
    if (!isVec3(object.size)) {
      add('schema', `${label}.size 必须是 3 个数字`, [label])
      return
    }
    if (object.rotation !== undefined && !isVec3(object.rotation)) {
      add('schema', `${label}.rotation 必须是 3 个数字`, [label])
    }
    if (object.group !== undefined && !allowedGroups.includes(object.group)) {
      add('schema', `${label}.group 只能是 ${allowedGroups.join(' / ')}`, [label])
    } else if (object.group !== undefined && object.group !== PLAN_GROUP_BY_TYPE[object.type]) {
      add(
        'schema',
        `${label}.group 与 type 不匹配：${object.type} 应属于 ${PLAN_GROUP_BY_TYPE[object.type]}（当前 ${object.group}）`,
        [label],
      )
    }

    const [sx, sy, sz] = object.size
    const [px, py, pz] = object.position
    for (const [axis, value] of [['size.x', sx], ['size.y', sy], ['size.z', sz]]) {
      if (value < ranges.min) {
        add('size', `${label}.${axis} 不能小于 ${ranges.min}（当前 ${fmt(value)}）`, [label])
      }
    }
    if (sy < ranges.height[0] || sy > ranges.height[1]) {
      add(
        'size',
        `${label} 高度 ${fmt(sy)} 超出 ${object.type} 的范围 ${ranges.height[0]}–${ranges.height[1]}m`,
        [label],
      )
    }
    const footprint = Math.max(sx, sz)
    if (footprint < ranges.footprint[0] || footprint > ranges.footprint[1]) {
      add(
        'size',
        `${label} 平面尺寸 ${fmt(footprint)} 超出 ${object.type} 的范围 ${ranges.footprint[0]}–${ranges.footprint[1]}m`,
        [label],
      )
    }

    const box = {
      x1: px - sx / 2,
      x2: px + sx / 2,
      y1: py,
      y2: py + sy,
      z1: pz - sz / 2,
      z2: pz + sz / 2,
    }
    boxes.push({
      label,
      placement: PLAN_PLACEMENT_BY_TYPE[object.type] ?? ['ground'],
      box,
      hasSchemaError: errors.some(error => error.objects.includes(label)),
    })
  })

  // ---- 物理合理性：边界 / 穿透 / 悬浮 / 支撑 ----
  const allBoxes = boxes.map(entry => entry.box)
  const findSupport = (box, candidates) => {
    const area = Math.max(0, (box.x2 - box.x1) * (box.z2 - box.z1))
    if (area <= 0) {
      return null
    }
    for (const other of candidates) {
      if (other === box) {
        continue
      }
      if (other.y2 > box.y1 + Math.max(groundTolerance, 0.1) || other.y1 >= box.y1) {
        continue
      }
      if (Math.abs(other.y2 - box.y1) > Math.max(groundTolerance, 0.1)) {
        continue
      }
      const overlapX = Math.min(box.x2, other.x2) - Math.max(box.x1, other.x1)
      const overlapZ = Math.min(box.z2, other.z2) - Math.max(box.z1, other.z1)
      if (overlapX <= 0 || overlapZ <= 0) {
        continue
      }
      if (overlapX * overlapZ >= 0.5 * area) {
        return other
      }
    }
    return null
  }

  for (const entry of boxes) {
    const { label, box, placement } = entry
    if (entry.hasSchemaError) {
      continue
    }
    const bottom = box.y1

    if (bottom < -groundTolerance) {
      add('ground', `${label} 沉入地面 ${fmt(-bottom)}m（底部 y=${fmt(bottom)}）`, [label])
      continue
    }

    if (box.x1 < sceneMin - 1e-6 || box.x2 > sceneMax + 1e-6) {
      add(
        'bounds',
        `${label} 的包围盒超出场景边界 [${fmt(sceneMin)}, ${fmt(sceneMax)}]（x 范围 ${fmt(box.x1)}–${fmt(box.x2)}）`,
        [label],
      )
    }
    if (box.z1 < sceneMin - 1e-6 || box.z2 > sceneMax + 1e-6) {
      add(
        'bounds',
        `${label} 的包围盒超出场景边界 [${fmt(sceneMin)}, ${fmt(sceneMax)}]（z 范围 ${fmt(box.z1)}–${fmt(box.z2)}）`,
        [label],
      )
    }

    if (bottom > maxFloatHeight) {
      if (placement.includes('on_surface')) {
        if (!findSupport(box, allBoxes)) {
          add(
            'support',
            `${label} 声明为 on_surface，但下方无有效支撑面（底部 y=${fmt(bottom)}，需要顶面接近且水平覆盖 ≥50%）`,
            [label],
          )
        }
      } else if (!placement.some(item => EXEMPT_PLACEMENTS.includes(item))) {
        add('float', `${label} 悬浮 ${fmt(bottom)}m，placement=${placement.join('/')} 不允许地面放置`, [label])
      }
    }
  }

  // ---- 碰撞：三轴都重叠超过容差 ----
  for (let i = 0; i < boxes.length; i += 1) {
    for (let j = i + 1; j < boxes.length; j += 1) {
      const a = boxes[i]
      const b = boxes[j]
      if (a.hasSchemaError || b.hasSchemaError) {
        continue
      }
      const overlapX = Math.min(a.box.x2, b.box.x2) - Math.max(a.box.x1, b.box.x1)
      const overlapY = Math.min(a.box.y2, b.box.y2) - Math.max(a.box.y1, b.box.y1)
      const overlapZ = Math.min(a.box.z2, b.box.z2) - Math.max(a.box.z1, b.box.z1)
      if (overlapX > maxCollisionOverlap && overlapY > maxCollisionOverlap && overlapZ > maxCollisionOverlap) {
        add(
          'collision',
          `${a.label} 与 ${b.label} 碰撞，三轴重叠 ${fmt(overlapX)}×${fmt(overlapY)}×${fmt(overlapZ)}m，重叠体积约 ${fmt(overlapX * overlapY * overlapZ)}m³`,
          [a.label, b.label],
        )
      }
    }
  }

  return { ok: errors.length === 0, errors }
}

/**
 * 兼容接口：返回中文错误消息列表（空表示通过）。
 *
 * @param {object} plan
 * @param {object} [rawOptions]
 * @returns {string[]}
 */
export function validatePlan(plan, rawOptions) {
  return validatePlanDetailed(plan, rawOptions).errors.map(error => error.message)
}

export function normalizePlan(plan) {
  const bounds = plan && typeof plan.bounds === 'object' && plan.bounds ? plan.bounds : DEFAULT_PLAN_BOUNDS
  const width = isFiniteNumber(bounds.width) ? bounds.width : DEFAULT_PLAN_BOUNDS.width
  const depth = isFiniteNumber(bounds.depth) ? bounds.depth : DEFAULT_PLAN_BOUNDS.depth
  const objects = Array.isArray(plan?.objects) ? plan.objects : []
  const typeCounters = new Map()
  return {
    sceneName: typeof plan?.sceneName === 'string' && plan.sceneName.trim() !== '' ? plan.sceneName.trim() : 'LLMScene',
    bounds: { width, depth },
    objects: objects
      .filter(object => object && typeof object === 'object')
      .map(object => {
        const type = String(object.type ?? '')
        // id 缺失时按 {type}_{序号} 生成，保证装配后的 instanceName 规范可读
        const count = (typeCounters.get(type) ?? 0) + 1
        typeCounters.set(type, count)
        const id = String(object.id ?? '').trim() || `${type || 'object'}_${String(count).padStart(2, '0')}`
        return {
          id,
          type,
          position: isVec3(object.position) ? object.position.slice() : [0, 0, 0],
          size: isVec3(object.size) ? object.size.slice() : [1, 1, 1],
          rotation: isVec3(object.rotation) ? object.rotation.slice() : [0, 0, 0],
          group: object.group ?? PLAN_GROUP_BY_TYPE[type] ?? 'Props',
        }
      }),
  }
}

/**
 * 从 plan 统计概览。
 *
 * @param {object} plan
 * @returns {{ sceneName: string, bounds: {width: number, depth: number}, objectCount: number, groups: string[] }}
 */
export function planSummary(plan) {
  const normalized = normalizePlan(plan)
  const groups = [...new Set(normalized.objects.map(object => object.group))]
  return {
    sceneName: normalized.sceneName,
    bounds: normalized.bounds,
    objectCount: normalized.objects.length,
    groups,
  }
}
