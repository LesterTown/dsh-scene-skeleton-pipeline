# dsh-scene-skeleton-pipeline

**DSH 编排插件：一段文字 → ComfyUI 出概念图 → Blender 生成引擎无关的场景骨架（`scene.blend` / `.fbx` / `.glb` + `layout.json`），可选 Unity 装配适配器。**

它产出的是**可继续编辑的灰盒场景**（层级 + 光照 + 相机 + 参数化物件），不是可玩关卡生成器：
不做碰撞体/刚体物理（只做 AABB 级静态合理性校验）、不做导航/触发器/交互逻辑、不从概念图反推几何、
不做图生 3D（见[路线图](#路线图)）。

> **合规声明**：本项目仅用于**单机/离线游戏开发**场景的场景骨架生成，不涉及在线游戏自动化，
> 不读取/修改任何游戏进程的内存，不绕过任何游戏或平台的反作弊/自动化限制。
> 产出物是标准的 `.blend` / `.fbx` / `.glb` / `.json` 文件，由你在自己的引擎里使用。

## 它能做什么 / 不做什么

| 做 | 不做 |
| --- | --- |
| 环境探测：Blender / ComfyUI / Unity 三项（只探测，不启动软件） | 不接管 ComfyUI 生命周期（不负责安装/启动/停止，需你自己先跑起来） |
| ComfyUI 出图：内置 txt2img 工作流，或你提供的 **API 格式**工作流 JSON | 不支持 ComfyUI 的 UI 格式工作流（只认 `POST /prompt` 的 API 格式） |
| Blender headless 生成场景骨架：`scenic`（默认）用 scenic-bpy 声明式 spec 生成参数化庭院（地形/柱墙/拱门/树/长椅/灯柱，语义分组 Terrain/Buildings/Props）；`legacy` 生成固定体块 + 参考图平面 | 不做从概念图提取几何；产出是**灰盒**，需要你替换美术资产 |
| 按文字精确布点：`plan_scene_layout` 让模型生成带 `position` / `size` 的布局 plan，Blender 按坐标和尺寸摆放；plan 经结构 + 物理合理性校验（边界/穿透/悬浮/碰撞/支撑），失败反馈给模型重试最多 3 次 | 不保证 LLM 每次都能给出合理布局（有校验和重试，但成功率非 100%） |
| 引擎无关导出：`scene.blend` + `scene.fbx` + `scene.glb` + `layout.json`（层级/光照/相机/物件变换） | 默认是纯色灰盒材质，不做材质细化（详见「做」列下一行） |
| 可选 PBR 贴图（默认关闭）：`enableTextureGeneration=true` 时用 SuperPBR 给对象生成 albedo/normal/roughness/metallic，替换纯色材质 | 不做图集合并/纹理超分/手工级 UV；每个对象单独材质 |
| 可选 Unity 适配器：batchmode 按 `layout.json` 自动装配（root + 分组 + 实例化 + 光照 + 相机 + 可选 prefab） | 不做 Unity 之外的 adapter 代码（UE / Godot 目前只给导入说明） |
| 结构化返回：`artifacts`（image/blend/fbx/glb/layout/scene/prefab）+ `summary`（scenePath/objectCount/groups/root/layoutPath/layoutAxis）+ 失败时的 `failedStage` / `logs` | 不做碰撞体/刚体物理、不做导航校验，不保证白盒可行走 |

## 目录结构

```
dsh-scene-skeleton-pipeline/
├── index.js               Host 入口：Config schema、apply、service / 工具 / 设置页路由挂载
├── client.js              Client 入口：设置页面板（settings.section 槽位，手写、无构建）
├── lib/
│   ├── service.js         PipelineService：environment 三项 + checkAll()
│   ├── detect.js          三项检测：Blender / ComfyUI / Unity（只探测，不启动）
│   ├── tool.js            check_environment 工具
│   ├── pipeline.js        PipelineEngine：节点编排 + dry-run / 真实执行 + artifacts/summary 汇总
│   ├── pipeline-tool.js   run_scene_pipeline 工具
│   ├── plan-tool.js       plan_scene_layout 工具（调宿主 llm 生成布局 plan）
│   ├── layout.js          layout.json 契约 + plan 契约（校验 / 归一化 / 摘要）
│   ├── executors/         comfy.js / blender.js / process.js
│   ├── workflows/         txt2img.json（内置 ComfyUI API 格式工作流）
│   ├── scripts/           build_scene.py（legacy）/ run_scenic.py（scenic 运行器）/ layout_validate.py
│   │   └── scenes/        courtyard.py（scenic-bpy 声明式庭院 spec）
│   ├── settings.js        设置页宿主路由（/plugins/dsh-scene-skeleton-pipeline/*）
│   └── store.js           配置持久化：$DSH_HOME/scene-skeleton-pipeline/config.json
├── adapters/unity/        可选 Unity 适配器：unity.js + SceneSkeletonPipelineEditor.cs + verify-unity-adapter.sh
├── examples/              ptc-run-scene.ts（PTC / run_code 用法示例）
├── scripts/verify/        all.sh 回归入口 + 各阶段 verify 脚本 + real-e2e.mjs
├── requirements-scenic.txt
├── cordis.patch.yml       bundle patch 层（安装进 profile 时挂载）
├── LICENSE                MIT
└── package.json
```

## 环境要求

| 依赖 | 要求 | 备注 |
| --- | --- | --- |
| Node | ≥ 20（插件用 ESM、`AbortSignal.timeout`） | DSH 自带运行时也可 |
| DSH | 支持 bundle 的版本（`dsh.bundle.patch` + `dsh.client`） | 实测 0.2.1-rc.5 |
| ComfyUI | **自行启动**并监听 `http://127.0.0.1:8188`；至少一个 checkpoint 可加载 | 实测 ComfyUI 0.43.0：无 `/health` 时检测自动回退 `/queue` |
| Blender | 4.x（`--background --factory-startup --python`）；`scenic` 模式另需 scenic-bpy | 实测 Blender 4.5.9 LTS |
| Unity（可选） | 仅 `enableUnityAdapter=true` 时需要：2022.3 LTS+，batchmode 可用且许可证已激活 | 实测 2022.3.62f3c1；核心链路不需要 Unity |
| 磁盘 | 约 **25 GB**（ComfyUI + checkpoint + Blender + 可选 Unity 工程/缓存，按实际模型而定）；开启 PBR 贴图再加约 **6.4 GB**（SuperMat 3.5 GB + MoGe 2.5 GB + VAE 0.3 GB） | 不含素材与引擎安装 |
| PBR 贴图（可选） | 仅 `enableTextureGeneration=true` 时需要：ComfyUI-SuperPBR 节点 + SuperMat/MoGe/VAE 模型 | 见下方「PBR 贴图依赖」；8 GB 显存够用但较慢，建议 ≥ 12 GB |

scenic-bpy（默认场景模式依赖，装进 Blender 自带 Python）：

```bash
"/Applications/Blender.app/Contents/Resources/4.5/python/bin/python3.11" -m pip install --user "scenic-bpy>=1.19.0"
# 检查：
"/Applications/Blender.app/Contents/MacOS/Blender" --background --python-expr "import scenic; print(scenic.__version__)"
```

macOS 上 pip 会装到 `~/.local/lib/python3.11/site-packages`（Blender.app 内部不可写，属正常）；
`run_scenic.py` 启动时会把该目录加进 `sys.path`。国内网络可用 `-i https://pypi.tuna.tsinghua.edu.cn/simple`。
只用 `legacy` 模式可以不装。

### PBR 贴图依赖（可选增强，默认关闭）

只有把 `enableTextureGeneration` 打开时才需要；不做贴图时整条链路完全不受影响。

```bash
# 1) SuperPBR 节点（装进 ComfyUI 的 custom_nodes 后重启 ComfyUI）
git clone --depth 1 https://github.com/Hullabalo/ComfyUI-SuperPBR.git \
  ~/ComfyUI-Shared/custom_nodes/ComfyUI-SuperPBR

# 2) 模型（放到 ComfyUI 的 --base-directory 下；国内可用 hf-mirror.com 镜像）
#    supermat.pth  → models/diffusion_models/
#    moge_3_vitg_fp16.safetensors → models/geometry_estimation/
#    vae-ft-mse-840000-ema-pruned.safetensors → models/vae/
```

MoGe 节点（`LoadMoGeModel` / `MoGeInference` / `MoGeRender`）由 ComfyUI 原生提供（0.39+）。
重启后用下面的命令检查节点是否齐全：

```bash
curl -s http://127.0.0.1:8188/object_info/SuperPBRDecompose | head -c 200
curl -s http://127.0.0.1:8188/object_info/MoGeInference | head -c 200
```

缺节点或缺模型时，贴图阶段会返回 `SKIP: SuperPBR/MoGe 节点不可用（缺少 …）` 并跳过，
**不会**让主流水线失败。

> **不要并行跑验证脚本**：`scripts/verify/*` 会启停宿主并写 `.dsh-dev` 配置，同一时间只跑一个；
> 并行会导致端口/配置竞争，出现莫名其妙的断言失败。真实执行也请避免同时用 Unity 编辑器打开同一工程。

## 快速开始

### 1) 安装

```bash
# 从本地目录安装进 profile（pnpm 以 link: 方式安装，并自动登记 dsh.profile.bundles）
dsh plugin --profile web add /absolute/path/to/dsh-scene-skeleton-pipeline
dsh web
```

安装后 profile 的 `package.json` 会多出依赖，`dsh.profile.bundles` 里出现 `dsh-scene-skeleton-pipeline`，
DSH 按包的 `dsh.bundle.patch` 自动挂载，无需手改 YAML。加载成功的日志里能看到：

```
[dsh-scene-skeleton-pipeline] loaded
[dsh-scene-skeleton-pipeline] service registered: scenePipeline (comfyUrl=http://127.0.0.1:8188)
[dsh-scene-skeleton-pipeline] tool registered: check_environment
[dsh-scene-skeleton-pipeline] settings routes registered: ...
[dsh-scene-skeleton-pipeline] pipeline engine ready: comfy -> blender
[dsh-scene-skeleton-pipeline] pipeline tool registered: run_scene_pipeline
[dsh-scene-skeleton-pipeline] plan tool registered: plan_scene_layout
```

### 2) 最小配置（设置 → 场景骨架流水线）

核心链路只需要三项：`comfyUrl`（默认 `http://127.0.0.1:8188`）、`blenderExe`（留空自动探测）、
`outputDir`（留空用 `$DSH_HOME/scene-skeleton-pipeline/outputs`）。要启用 Unity 装配再填
`unityProjectPath` 并把 `enableUnityAdapter` 打开。完整字段见[配置项](#配置项)。

### 3) 跑一次 dry-run（不启动任何软件）

面板点「运行 dry-run」，或让模型调用：

```
run_scene_pipeline({ prompt: "一座带台阶的日式庭院，四角有石柱", dryRun: true })
```

只做依赖检查与节点编排：环境不满足时节点 `blocked`、后续 `skipped`，产物是占位。

### 4) 跑一次真实执行

面板点「真实执行」→「确认真实执行（会启动软件）」，或：

```
run_scene_pipeline({ prompt: "一座带台阶的日式庭院，四角有石柱", dryRun: false })
```

会真实启动 ComfyUI（约 1–1.5 分钟）、Blender headless（约 2–5 秒），启用 Unity 适配器时再跑
Unity batchmode（约 10–15 秒起）。

### 5) 产物在哪

`<outputDir>/jobs/<jobId>/` 下：`comfy/`（出图）、`blender/`（`scene.blend` / `scene_skeleton.fbx` /
`scene_skeleton.glb` / `layout.json`）；启用贴图时还有 `textures/`（每个对象一张渲染输入图 +
`{id}_albedo/normal/roughness/metallic/ao/height.png`）；启用 Unity 时还有 `unity/`（`unity.log` + `unity-result.json`）。
返回值的 `artifacts` 里是每个产物的绝对路径（键：`image` / `blend` / `fbx` / `glb` / `layout` / `textures` / `scene` / `prefab`）。

### 6) 打开验收

- **Blender**：直接打开 `blender/scene.blend`，能看到 `SceneSkeleton_Root` / `Terrain` / `Buildings` / `Props`
  层级、方向光与相机。
- **Unity（可选）**：打开工程里的 `Assets/Scenes/SceneSkeleton.unity`（`summary.scenePath`）。
- **其他引擎**：导入 `scene.fbx` 或 `scene.glb`，再按 `layout.json` 摆位（见[导入到你的引擎](#导入到你的引擎)）。

## 配置项

| 字段 | 说明 |
| --- | --- |
| `blenderExe` | Blender 可执行文件（空 = 自动探测；macOS 默认 `/Applications/Blender.app/Contents/MacOS/Blender`） |
| `comfyUrl` | ComfyUI 地址（默认 `http://127.0.0.1:8188`） |
| `comfyWorkflowPath` | ComfyUI **API 格式**工作流 JSON（空 = 内置 txt2img 模板） |
| `comfyCheckpoint` | checkpoint 文件名（空 = 自动取 `/object_info` 里的第一个） |
| `comfyNegativePrompt` | 负向提示词（空 = 内置默认） |
| `unityProjectPath` | Unity 工程根目录（需含 `ProjectSettings/ProjectVersion.txt`；仅适配器需要） |
| `unityExe` | Unity 可执行文件（空 = 按工程 `m_EditorVersion` 自动探测） |
| `outputDir` | 产物目录（空 = `$DSH_HOME/scene-skeleton-pipeline/outputs`） |
| `blenderSceneMode` | `scenic`（默认，声明式）或 `legacy`（旧固定体块 + 参考图平面） |
| `scenicWidth` / `scenicDepth` / `scenicWallHeight` | scenic 庭院参数（默认 24 / 20 / 3.2 米） |
| `enableUnityAdapter` | 是否追加 Unity 装配节点（默认 `false`） |
| `sceneSource` | `template`（默认，用 scenic spec 的固定布局）或 `llm`（按 `layoutObjects` 的 plan 精确摆放） |
| `layoutObjects` | `sceneSource='llm'` 的布局来源：plan JSON 文件路径，或直接内联 JSON 字符串 |
| `layoutAxis` | `layout.json` 坐标系：`z-up`（默认，Blender 原生）或 `y-up`（Unity 转换值） |
| `layoutValidation` | 精确布局的物理合理性容差（JSON 对象，面板可改）：`maxCollisionOverlap`（默认 0.1 m）、`maxFloatHeight`（0.3 m）、`groundTolerance`（0.05 m）、`sceneBounds`（[-50, 50]） |
| `assetLibraryPath` | 材质贴图根目录（可选）：`lib/asset-library.json` 里每个材质 key 的 `albedoPath` 等相对它解析；留空 = 纯色 fallback（见「材质映射」） |
| `assetModelPath` | 几何模型根目录（可选）：`lib/asset-library.json` 里每个 type 的 `modelPath` 相对它解析；留空 = 全部程序化图元（见「几何模型库配置」） |
| `enableTextureGeneration` | 是否用 SuperPBR 给对象生成 PBR 贴图（默认 `false`；可选增强，见下文「可选增强：PBR 贴图」） |
| `textureResolution` | 贴图分辨率（默认 `512`，256–2048；越大越慢、越吃显存） |
| `textureObjects` | `main`（默认：地面 + 柱/墙/拱门/门房）或 `all`（三组全部对象；**每对象一次推理，很慢**） |
| `texturePromptPrefix` | 预留给贴图阶段的文本前缀（当前版本仅记录，尚未参与推理） |

保存后配置写两处：`$DSH_HOME/scene-skeleton-pipeline/config.json`（权威）与 profile 的 `cordis.patch.yml`
（bundle 安装时可用；`--patch` 开发覆盖层下宿主会拒绝写 profile，属预期）。

## 场景布局契约（layout.json）

`layout.json` 是 Blender 与下游引擎之间的唯一契约：Blender 按实际摆放写它，Unity 适配器严格按它装配。
`lib/layout.js` 定义并校验这份契约（`validateLayout` / `normalizeLayout` / `layoutSummary`）。

```json
{
  "sceneName": "SceneSkeleton",
  "axis": "z-up",
  "root": "SceneSkeleton_Root",
  "groups": [
    { "name": "Terrain", "objects": [
      { "asset": "scene_skeleton.fbx", "instanceName": "Ground",
        "position": [0, 0, 0], "rotation": [0, 0, 0], "scale": [1, 1, 1] }
    ]},
    { "name": "Buildings", "objects": [
      { "asset": "scene_skeleton.fbx", "instanceName": "column_01",
        "position": [-12, -10, 0.03], "rotation": [0, 0, 0], "scale": [1, 1, 1] }
    ]},
    { "name": "Props", "objects": [] }
  ],
  "lighting": {
    "ambient": { "intensity": 0.4, "color": [1, 1, 1] },
    "directional": { "intensity": 3.2, "rotation": [52, 0, -138], "color": [1, 0.95, 0.86] },
    "skybox": "default"
  },
  "camera": { "position": [21, -19, 12], "lookAt": [0, 2.5, 0] },
  "prefab": { "enabled": false, "path": "Assets/Prefabs/" }
}
```

字段含义：

- `sceneName` / `root`：场景名与根空节点名；`groups[].name` 会成为 `root` 下的空节点（分组）。
- `groups[].objects[]`：每个实例的 `asset`（首版固定同一个 `scene_skeleton.fbx`，可多次实例化）、
  `instanceName`（必须在该 fbx 内唯一）、`position` / `rotation`（度）/ `scale`。
- `lighting.ambient`：环境光强度与颜色；`lighting.directional`：方向光强度、欧拉角（度）、颜色；
  `lighting.skybox`：`"default"` 用引擎内置默认天空盒，`null` 不设置。
- `camera`：相机位置与看向点。
- `prefab`：仅 Unity 适配器使用；`enabled: true` 时把根节点存成 `Assets/Prefabs/<sceneName>.prefab`。

**坐标系（`axis`）——本版本默认 `z-up`**：

- `z-up`（默认）：layout.json 直接写 **Blender 原生**坐标（`position=[x,y,z]`、rotation 是 Blender XYZ 欧拉角），
  可以原样回灌 Blender 复现。
- `y-up`：写 Unity 转换后的值（`position=(x,z,-y)`、`scale=(x,z,y)`，旋转做基变换后转成 pitch/yaw/roll）。
- Unity 适配器在适配器层转换：`axis === 'z-up'` 时先转成 y-up 再交给 Editor 脚本，原始 layout 不变。

> **breaking change（v0.1.0 起）**：早期开发版本的 layout.json 只有 y-up 一种口径；本版本起默认 `z-up`，
> 并新增 `axis` 字段。下游自行解析 layout.json 时请**先读 `axis`**；缺少该字段的历史文件按 `y-up` 处理。
> 需要旧的 Unity 直消费口径时把 `layoutAxis` 配成 `y-up`。

`scale` 是**实例额外缩放**（不是物体原始缩放）：Blender 导出前已把物体 scale 烘进几何，生成的 layout 里恒为
`[1,1,1]`；手改 layout 的 scale 仍可做实例缩放。fbx 自带单位换算（Blender 米制 → fbx 厘米的 100 倍）由
导入设置承担，适配器每次装配前会把导入设置校正为 `Convert Units=true / globalScale=1`。

## LLM 精确布局（`plan_scene_layout`）

`sceneSource='template'` 时布局来自 scenic spec（固定构图）；`sceneSource='llm'` 时改为按一份 **plan JSON**
精确摆放：每个对象带 `position` / `size`，Blender 按坐标和尺寸用简单图元装配。

```ts
plan_scene_layout({
  sceneDescription: "东侧有喷泉，四角各一根石柱，北侧一段矮墙，西南一棵树",
  savePath: "/tmp/courtyard-plan.json",   // 可选：写盘，供 layoutObjects 引用
  width: 24, depth: 20                     // 可选：场地范围（米）
})
// → { ok, plan, errors, model, savedPath? }
```

`ok=false` 时 `errors` 是逐条中文原因（模型可据此重试）。plan JSON 结构：

```json
{
  "sceneName": "Courtyard",
  "bounds": { "width": 24, "depth": 20 },
  "objects": [
    { "id": "fountain_01", "type": "fountain", "position": [0, 0, 0], "size": [4, 0.8, 4] },
    { "id": "column_01",   "type": "column",   "position": [-8, 0, -6], "size": [0.8, 3.5, 0.8] },
    { "id": "tree_01",     "type": "tree",     "position": [-10, 0, 0], "size": [3, 5, 3] }
  ]
}
```

约定：`position` 是**对象底面中心**（贴地），`size` 是完整尺寸（米），plan 坐标口径固定为 **Unity Y-up**；
`id` 唯一（装配后的 `instanceName` 就是 `id`，缺省时按 `{type}_{序号}` 自动生成）。
`type` 只能从资产库白名单里选（见下表，共 18 种），分组由 type 自动派生，Terrain 自动生成地面。
LLM 不能自由发明 type——系统 prompt 会列出全部可用类型与尺寸范围，校验器遇到白名单外的 type 会拒绝并列出可用清单。

可用 type（`lib/asset-library.json` 是唯一事实源，prompt / schema / 校验器 / Blender 几何都从它派生）：

| type | 说明 | 分组 | 高度范围 | 平面尺寸范围 | 默认尺寸 (x,y,z) |
|---|---|---|---|---|---|
| `column` | 柱子 | Buildings | 0.5–10 m | 0.1–3 m | 0.6/3/0.6 |
| `wall` | 墙体 | Buildings | 0.3–8 m | 0.05–30 m | 4/2.4/0.4 |
| `archway` | 拱门 | Buildings | 1.5–8 m | 0.6–12 m | 6/3.2/0.6 |
| `gatehouse` | 门房 | Buildings | 1.5–9 m | 1–12 m | 5/4/4 |
| `platform` | 平台/台阶基座 | Buildings | 0.1–3 m | 0.5–20 m | 6/0.4/6 |
| `stairs` | 台阶 | Buildings | 0.2–3 m | 0.3–10 m | 3/1.2/2 |
| `tree` | 树 | Props | 1–12 m | 0.5–8 m | 3/5/3 |
| `bush` | 灌木 | Props | 0.2–3 m | 0.3–4 m | 1.2/1/1.2 |
| `fountain` | 喷泉 | Buildings | 0.2–4 m | 0.5–10 m | 4/0.8/4 |
| `bench` | 长椅 | Props | 0.3–1.5 m | 0.4–3 m | 2/0.5/0.7 |
| `lantern` | 灯柱 | Props | 0.5–6 m | 0.2–1.5 m | 0.6/3/0.6 |
| `rock` | 岩石 | Props | 0.1–6 m | 0.2–8 m | 1.5/1/1.5 |
| `crate` | 木箱 | Props | 0.2–3 m | 0.2–3 m | 0.9/0.9/0.9 |
| `barrel` | 木桶 | Props | 0.3–3 m | 0.3–3 m | 0.8/1.1/0.8 |
| `statue` | 雕像 | Props | 0.5–8 m | 0.3–4 m | 1.2/2.4/1.2 |
| `planter` | 花盆 | Props | 0.2–2 m | 0.3–4 m | 1/0.7/1 |
| `table` | 桌子 | Props | 0.4–1.6 m | 0.4–4 m | 1.6/0.8/0.9 |
| `chair` | 椅子 | Props | 0.3–1.8 m | 0.3–2 m | 0.6/1/0.6 |


校验（`lib/layout.js` 的 `validatePlan` / `validatePlanDetailed` 与 `lib/scripts/layout_validate.py` 同规则、同文案），
返回结构化结果 `{ ok, errors: [{ rule, message, objects }] }`，一次性列出全部违规项：

| 规则 | 判定 | 默认容差 | 错误示例 |
| --- | --- | --- | --- |
| 结构 | id 唯一、type 在白名单、group 与 category 匹配、尺寸在类型范围、对象数 ≤ 120 | — | `wall_01.group 与 type 不匹配：wall 应属于 Buildings（当前 Props）` |
| 边界越界 | 对象 AABB 超出场景边界（XZ 平面） | `sceneBounds = [-50, 50]` | `column_01 的包围盒超出场景边界 [-50, 50]（x 范围 59.5–60.5）` |
| 地面穿透 | 底部低于地面 | `groundTolerance = 0.05 m` | `column_01 沉入地面 0.3m（底部 y=-0.3）` |
| 悬浮 | 底部高于地面且 placement 不允许离地 | `maxFloatHeight = 0.3 m` | `chair_01 悬浮 1m，placement=ground 不允许地面放置` |
| 碰撞 | 两对象 AABB 三轴重叠都超过容差 | `maxCollisionOverlap = 0.1 m` | `column_01 与 column_02 碰撞，三轴重叠 0.8×3×0.8m，重叠体积约 1.92m³` |
| 支撑 | `placement` 含 `on_surface` 时，下方须有顶面接近且水平覆盖 ≥ 50% 的对象（AABB 级判断，不做物理模拟） | 同 `groundTolerance` | `planter_01 声明为 on_surface，但下方无有效支撑面（底部 y=1）` |

`placement` 含 `wall` / `ceiling` 的类型不受悬浮规则约束。规则全部是 AABB 级（盒对盒），不做刚体/SDF 模拟。

**失败与重试**：`plan_scene_layout` 把结构化 errors 反馈给模型并要求重新输出，最多 **3 次尝试**；成功后返回
`{ ok: true, plan, attempts, validation }`，三次仍失败返回 `{ ok: false, attempts: 3, errors, validation }`
（不静默接受非法 plan）。Blender 在执行 `sceneSource='llm'` 前会再校验一次，失败直接报错、不启动装配。
`validation` 字段与容差都可用 `layoutValidation` 配置调整（面板里的「物理校验」四项）。

**扩展 type**：在 `lib/asset-library.json` 里加一条（type / label / category / placement / sizeRange /
defaultSize / geometry 图元列表），其余四处（prompt、schema enum、校验器、Blender 几何）会自动生效；只有当需要
新的图元形状时才要改 `lib/scripts/run_scenic.py` 的 `_build_geometry_part`（现有形状：`box` / `cylinder` /
`cone` / `sphere` / `blob` / `steps`）。加完跑 `bash scripts/verify/verify-layout-types.sh --skip-llm` 快速自检。

plan 与 layout.json 是两份数据：plan 是「要摆什么」，layout.json 是装配后的**实际**摆放快照。

## 材质映射（asset-library 贴图）

给 `lib/asset-library.json` 里的 9 个语义材质 key（`stone` / `stone_dark` / `wood` / `wood_dark` /
`trunk` / `leaf` / `metal` / `ground` / `water`）配真实 PBR 贴图，让柱、墙、树默认就带石材/木纹/叶脉质感。

**为什么需要**：SuperPBR 是材质分解（从一张渲染图分离光照与材质），灰盒输入只会得到灰 albedo；
材质映射是把真实贴图**注入**材质，两者互补：

- 材质映射：按 key 提供基础材质（同一种石材的柱子共享同一个 `LLM_stone`）；
- SuperPBR：按对象做一次分解，产出 `LLM_<id>_pbr` 独立材质，覆盖该对象的 key 材质。

**优先级**：SuperPBR 独立材质（`LLM_<id>_pbr`） > 材质映射（`LLM_<key>`） > 纯色 fallback。

**数据结构**：`lib/asset-library.json` 的 `materials.<key>` 新增四个可选字段（相对 `assetLibraryPath`）：

```json
"stone": {
  "color": [0.62, 0.61, 0.58],
  "roughness": 0.85,
  "albedoPath": "stone/albedo.png",
  "normalPath": "stone/normal.png",
  "roughnessPath": "stone/roughness.png",
  "metallicPath": "stone/metallic.png"
}
```

`color` / `roughness` 保留作为 fallback。只下载 albedo 也能用：其余贴图缺失时对应输入回退常量（albedo 缺失时
整个 key 回退纯色，并在 `keysFallback` 里列出）。

**目录结构**：把贴图按 key 分目录放到 `assetLibraryPath` 下，例如

```
assetLibraryPath/
  stone/albedo.png      stone/normal.png      stone/roughness.png      stone/metallic.png
  wood/albedo.png       wood/normal.png       ...
  leaf/albedo.png       ...
```

**推荐 CC0 贴图源**（插件不自带贴图，许可证与存储由你负责）：

- [Poly Haven](https://polyhaven.com/textures)：CC0 PBR 贴图，通常同时提供 albedo/normal/roughness/metallic；
- [ambientCG](https://ambientcg.com)：CC0 PBR 贴图，按材质分类清晰。

**怎么用**：

1. 下载贴图，按 `assetLibraryPath/stone/albedo.png` 这样的结构放好；
2. 如果文件名/层级和默认不一致，改 `lib/asset-library.json` 对应 key 的 `albedoPath` 等路径；
3. 设置 → 场景骨架流水线 → 填 `assetLibraryPath` → 保存；
4. 下次执行自动生效；未配置或文件缺失时走纯色 fallback，场景仍可跑通，只是没有纹理。

**结果与面板**：`summary.materialMapping = { enabled, assetLibraryPath, keysWithTextures, keysFallback }`，
面板显示「材质映射：N 个 key 用贴图，M 个回退纯色」。

**当前适用范围**：材质映射作用于 `sceneSource='llm'` 的程序化图元（资产库 18 种 type 都用 `LLM_<key>` 材质）；
`sceneSource='template'` 的 scenic 庭院走 `courtyard.py` 里自己的 `@app.material`，不受 `assetLibraryPath` 影响
（模板模式的材质在 spec 里定义，后续可统一）。

**验证**：`bash scripts/verify/verify-material-mapping.sh`（fixture 贴图 → 未配置/已配置/部分缺失/与 SuperPBR 共存 + 回归）。

## 几何模型库配置（asset-library 的 GLB 资产）

默认装配用**程序化简单图元**（柱=圆柱+顶底、树=圆柱+圆锥等），够做灰盒但「积木感」强。
配置 `assetModelPath` 后，`sceneSource='llm'` 的装配会优先用真实 `.glb/.gltf` 模型替换图元，摆脱积木感。

**工作原理**：`lib/asset-library.json` 里每个 type 有一个可选 `modelPath`（相对 `assetModelPath`）。
装配某个对象时：

1. 若 `assetModelPath/<type>.modelPath` 存在 → `bpy.ops.import_scene.gltf()` 导入真实模型；
2. **Join 合并**所有 mesh（删掉导入的空节点/灯光/相机）；
3. **底部中心对齐原点**：把包围盒的底部中心平移到局部原点（贴地，不悬空）；
4. **等比缩放**：按 plan 的高度比例统一缩放（`scale = plan高度 / 模型高度`，宽高深同比例，**不拉伸**）；
5. **保留自带材质**：模型带材质槽就用它自带的；没有材质槽才回退 `_material(key)` 纯色/材质映射；
6. 重命名为对象 id、打 `asset_source="model"`、挂到对应分组 Empty 下。

找不到模型时回退程序化图元（打 `asset_source="primitive"`），**不会让流水线失败**。

**内置资产速配指南**（4 个 CC0 包，全部可免费商用；下载解压后按下方文件夹名放入 `assetModelPath` 根目录）：

| 资产包 | 下载链接 | 解压后创建的文件夹 | 覆盖的 type（放入的 `.glb` 文件名） |
| --- | --- | --- | --- |
| Kenney「Nature Kit」 | <https://kenney.nl/assets/nature-kit> | `kenney_nature/` | tree→`tree_pine.glb`、bush→`bush.glb`、rock→`rock_large.glb` |
| Kenney「Fantasy Town Kit」 | <https://kenney.nl/assets/fantasy-town-kit> | `kenney_fantasy/` | fountain→`fountain.glb`、lantern→`lantern.glb`、planter→`planter.glb` |
| Quaternius「Medieval Village MegaKit」 | <https://quaternius.com/packs/medievalvillagemegakit.html> | `quaternius_medieval/` | column→`column_stone.glb`、wall→`wall_stone.glb`、archway→`arch_stone.glb`、gatehouse→`gatehouse.glb`、platform→`floor_stone.glb`、stairs→`stairs_stone.glb`、bench→`bench.glb` |
| Quaternius「Survival Kit」 | <https://quaternius.com/packs/survivalkit.html> | `quaternius_survival/` | crate→`crate.glb`、barrel→`barrel.glb`、statue→`statue.glb`、table→`table.glb`、chair→`chair.glb` |

> 这些 `modelPath` 是**标准契约**（写在 `lib/asset-library.json`，每个 type 还带 `license: "CC0"` 与
> `sourceUrl` 来源链接）。包里文件命名不一定完全一致——**只要把包里对应语义的 `.glb` 重命名成上表
> 路径**放进对应文件夹即可。
>
> **未下载任何包时**：项目会平滑回退到程序化图元（`asset_source="primitive"`），全链路测试照常全绿、
> 不报错（`verify-geometry-mapping.sh` 有专门的「18 种 type 全量回退」断言覆盖这一点）。

> 注意：**几何映射只换几何，不换贴图**。真实模型若带自带贴图就直接用；想要统一风格，配合
> 「可选增强：PBR 贴图（SuperPBR）」一起开，SuperPBR 会给替换后的模型重新生成独立材质。

**结果与面板**：`summary.geometryMapping = { modelsUsed, primitivesFallback }`，面板显示
「几何映射：使用 N 个真实模型，M 个回退图元」。

**验证**：`bash scripts/verify/verify-geometry-mapping.sh`（fixture GLB → 未配置全 primitive / 配置后 tree=model
且底部对齐 + 等比缩放 + 高度匹配 plan / 回退 primitive + 回归）。

## 可选增强：PBR 贴图（SuperPBR）

默认关闭（`enableTextureGeneration=false`）。开启后 Blender 会在导出前给选中的装配对象做一次贴图：

1. **Smart UV Project** 展开 UV（`angle_limit=66°`、`island_margin=0.02`；已有非默认 UV 也重投影，保证一致）；
2. **隔离渲染**一个对象（隐藏其它对象、灰底 `(0.5, 0.5, 0.5)`、EEVEE、正面取景、`textureResolution` 正方形）；
3. 把渲染图上传给 ComfyUI，跑内置工作流：
   - `lib/workflows/pbr-superpbr.json`（完整版）：LoadImage → SuperPBR 分解 albedo/ORM → ORM Split，
     MoGe 出 normal/depth，可选 Detilt；
   - `lib/workflows/pbr-superpbr-lite.json`（回退版，无 MoGe）：只出 albedo/roughness/metallic/ao。
4. 下载 `{id}_albedo / _normal / _roughness / _metallic / _ao / _height` 到
   `<outputDir>/jobs/<jobId>/textures/`，新建 `LLM_<id>_pbr` 材质（Image Texture → Principled BSDF 的
   Base Color / Normal / Roughness / Metallic），替换该对象原来的纯色材质。

**自动回退 lite**：MoGe 法线在部分平台不可用（例如 macOS 的 MPS + 8 GB 显存，
`F.interpolate(antialias=True)` 在 fp16 下没有实现）。插件会先尝试完整工作流，
失败（或检测到 MoGe 节点/模型缺失）时自动改用 lite 工作流，只出 4 张图，
并在结果里标注：`summary.texture.workflow = "lite"`、`summary.texture.note` 写明原因。
法线贴图不可用不影响主流程，材质仍会正确连接 Base Color / Roughness / Metallic。

**控制开销**：`textureObjects='main'`（默认）只给地面 + 建筑类（柱/墙/拱门/门房）出贴图；
`all` 会给三组全部对象出贴图——**每个对象一次推理**，48 对象的场景可能要十几分钟。每个对象默认超时 120 秒。

**降级行为**（重要）：贴图是可选增强，**永远不阻断主流水线**：

- 缺节点 / 缺模型 / ComfyUI 不可达 → 整段跳过，结果里 `texture.error` 写明原因，`artifacts.textures=null`；
- 单个对象失败（超时、下载失败、UV 失败）→ 记录到 `texture.failed`，其余对象继续；
- 结果结构：`summary.texture = { enabled, model: 'superpbr', resolution, objectCount, failedCount,
  workflow: 'full'｜'lite', note? }`，关闭时是 `{ enabled: false }`；
- 单次 job 最多给 `12` 个对象出贴图（超过只取前 12 个并在 `note` 里说明），避免一台机器上跑几十分钟。

**限制**（如实说明，避免期待落空）：

- SuperPBR 是**材质分解**（从单张渲染图分离 albedo/粗糙度/金属度/AO/法线），**不会凭空发明纹理细节**——
  对一堵纯灰的白盒墙，分解出来的 albedo 仍然是一块灰；想要真实的石墙/木头质感，需要块 D 的资产库材质
  或提示词驱动的材质生成（路线图）；
- MoGe 法线在 macOS MPS + 8 GB 上不可用（见上），实际只出 4 张图；
- 每个对象单独一套材质（不做图集合并）；UV 用 Smart UV 自动投影，不追求手工级接缝；
- 贴图分辨率受显存限制（8 GB 显存建议 512）；`texturePromptPrefix` 当前仅记录、未参与推理。

## 导入到你的引擎

产物统一是 `scene.blend` + `scene.fbx` + `scene.glb` + `layout.json`。**拿到什么、需要做什么**：

### Unity

- 拿到：`scene_skeleton.fbx`（或启用适配器时直接得到装配好的 `Assets/Scenes/SceneSkeleton.unity`）+ `layout.json`。
- 需要做：FBX 导入时勾选 **Convert Units**（1 单位 = 1 米）；按 `layout.json` 的 `groups[].objects[]` 摆位
  （`instanceName` 对应 fbx 里的节点名）。`axis = z-up` 时先转成 Unity 的 Y-up（`(x,y,z) → (x,z,-y)`）。
- 省事做法：开启 `enableUnityAdapter`，插件用 batchmode 自动完成装配（含光照/相机/可选 prefab）。

### Unreal Engine

- 拿到：`scene.fbx`（建议用 FBX；UE 的 Datasmith 走 FBX 路径更稳）+ `layout.json`。
- 需要做：导入 FBX 后按 `layout.json` 摆位。注意 **UE 是 Z-up 左手系**，Blender 是 Z-up 右手系——两者 Z 轴同向
  但 Y 轴左右手性相反，导入时勾选转换或用蓝图按 `layout.json` 摆位；旋转符号需按手性取反。
- 不提供 UE adapter 代码（路线图）。

### Godot

- 拿到：`scene.glb`（已按 `export_yup=True` 导出）+ `layout.json`。
- 需要做：GLB 直接拖进场景即可（Godot 是 Y-up 右手系，与 GLB 的 Y-up 口径一致）；需要精确摆位时按
  `layoutAxis='y-up'` 的 layout 或用脚本读 `layout.json` 的 node 名。

## 工具与 service

- `check_environment()` → `{ checkedAt, environment: { blender, comfy, unity } }`，每项
  `{ status: 'ok' | 'missing' | 'error', detail, path? }`。
- `run_scene_pipeline({ prompt, dryRun })` → `{ ok, jobId, status, stages, artifacts, summary, failedStage, logs }`；
  `artifacts = { image, blend, fbx, glb, layout, scene, prefab }`，`summary = { scenePath, objectCount, groups,
  prefabPath, root, layoutPath, layoutAxis }`。`ok` 只在 job `done` 时为 true。
- `plan_scene_layout({ sceneDescription, savePath?, width?, depth? })` → `{ ok, plan, errors, model, savedPath? }`。
- service：`ctx.get('scenePipeline')` → `{ getEnvironment(), getConfig(), updateConfig(next), checkAll(), getConfigFile(), pipeline }`。

节点状态 `pending | running | ok | blocked | skipped | failed`；job 状态 `queued | running | done | blocked | failed`。
依赖非 `ok` → 该节点 `blocked`、后续 `skipped`。

PTC（`run_code`）用法见 [`examples/ptc-run-scene.ts`](examples/ptc-run-scene.ts)：

```ts
const result = await tools.run_scene_pipeline({ prompt, dryRun: false })
if (!result.ok) throw new Error(`failedStage=${result.failedStage}\n${(result.logs ?? []).join('\n')}`)
// result.summary.scenePath / objectCount / groups / layoutAxis 可直接用于后续代码
```

## 验证

回归分三组：**引擎无关核心** + **可选 Unity 适配器** + **单元 harness**。

```bash
bash scripts/verify/all.sh                # 核心 + harness（适配器默认 SKIP）
bash scripts/verify/all.sh --with-unity   # 额外跑 Unity 适配器断言（真实装配场景）
bash scripts/verify/all.sh --skip-real    # 只验宿主接线/布局/导出，不启动 ComfyUI/Blender
bash scripts/verify/verify-regression-meta.sh   # 回归体系元检查（防回潮）
```

单个脚本：`verify-step2.sh`（配置/服务/检测）、`verify-step3.sh`（编排 dry-run）、`verify-step4.sh`（真实链路）、
`verify-step5.sh`（layout 契约）、`verify-step6.sh`（发布文件/示例/scenic）、`verify-blender-export.sh`（四产物与层级）、
`verify-layout-axis.sh`（z-up/y-up）、`verify-layout-llm.sh`（plan → 摆放）、`verify-layout-types.sh`（资产库 18 种 type）、
`verify-layout-validation.sh`（五类物理校验 + 重试闭环）、`verify-texture.sh`（可选 PBR 贴图开关与降级）、
`verify-material-mapping.sh`（材质贴图注入：未配置/已配置/部分缺失/与 SuperPBR 共存）、
`verify-geometry-mapping.sh`（几何模型注入：未配置/配置/底部对齐+等比缩放/回退）、
`verify-unity-adapter.sh`（可选适配器）、`verify-publish-ready.sh`（发布就绪）。

贴图相关：`verify-texture.sh` 默认校验工作流结构（完整版 + lite 回退版）、关闭模式、缺少 SuperPBR 节点时的降级；
节点与模型齐全时会自动跑一次真实贴图（会启动 ComfyUI 推理，较慢）；`--skip-llm` 只做结构/关闭/降级/回归，
`--skip-texture` 在总回归里用（不启动贴图推理）。

本机实测（macOS，8GB）：ComfyUI 出图约 86 秒、Blender 约 2–5 秒、Unity batchmode 约 10–15 秒。
断言数：step2=31、step3=32、step4=22（`--skip-real` 15）、step5=33（`--skip-real` 15）、step6=93（`--skip-real` 84）、
blender-export=6、layout-axis=9、layout-llm=25、layout-types=12、layout-validation=28、
texture=28（`--skip-texture` 20、`--skip-llm` 18）、material-mapping=45（`--skip-llm` 36）、
geometry-mapping=21（`--skip-llm`）、
adapter=29、meta=30、publish-ready=49；harness 4 个全 PASS。核心组 13 个脚本。

额外验证：在一个真实在用的 Unity 工程（166 个既有资产、含 VRM/OpenUPM 包）上完整跑过一次真实执行，
job `done`，原有资产 0 个被改写/删除，只新增插件自己的 11 个文件（编辑器脚本、装配输入、场景与 `.meta`）。

### clone 自检记录（v0.1.0）

按「一个新用户从零开始」走了一遍，过程和结论如下：

```bash
# 1) 打发布包（等价于发布到 registry 的 tarball，只含 package.json 的 files 清单）
npm pack                                   # → dsh-scene-skeleton-pipeline-0.1.0.tgz（约 0.5MB）
tar -xzf dsh-scene-skeleton-pipeline-0.1.0.tgz -C /tmp/publish-clone

# 2) 全新 DSH_HOME + 全新 profile，按 README 的方式安装
export DSH_HOME=/tmp/publish-home
dsh --profile web --dump-config > /dev/null     # 第一次启动会生成 profile 模板
dsh plugin --profile web add /tmp/publish-clone/package

# 3) 启动并验一次 dry-run
dsh --profile web --no-open --port 0
```

结果：

- 安装：profile 的 `dependencies` 出现 `dsh-scene-skeleton-pipeline: link:/tmp/publish-clone/package`，
  `dsh.profile.bundles` 自动追加该包；pnpm 提示 *“The linked in dependency will not resolve the peer
  dependencies from the target node_modules”*（`@deepseek-ai/schemastery` 是 peer 依赖）。
  **实测启动正常**——DSH 的插件加载器会按宿主自身依赖解析裸模块名，所以 link 安装也能拿到 schemastery；
  从 registry 安装（包落在 profile 的 `node_modules` 里）时由 pnpm 正常解析。
- 启动日志：7 条齐全（loaded / service / check_environment / pipeline engine / run_scene_pipeline /
  plan_scene_layout / settings routes），环境检测 `blender=ok / comfy=ok / unity=missing`（未配 Unity，符合预期）。
- `GET /state`：200，`configEditable=true`，`pipeline.stages = ['comfy','blender']`（Unity 适配器默认关闭）。
- `POST /pipeline/run {dryRun:true}`：`job.status=done`、两个节点均 `ok`、`summary=null`（dry-run 不出产物）。
- 自检中补齐的发布项：`version` 定为 `0.1.0`、`description` 换成一句话定位、`keywords` 按检索习惯重排、
  `peerDependencies` 显式写出（`@deepseek-ai/schemastery`，由宿主提供）；`files` 清单已含
  `adapters/` / `scripts/` / `examples/`（`npm pack` 的 tarball 里都验证过）。

## 已知限制

- **scenic spec 只覆盖小型户外/庭院**：当前 `lib/scripts/scenes/courtyard.py` 是一个参数化庭院
  （宽/深/墙高/seed），不承诺大世界地图覆盖。
- **LLM 布局成功率非 100%**：`plan_scene_layout` 有 JSON 提取 + 结构/物理校验与 3 次重试，失败会返回逐条原因让模型
  重试；复杂描述仍可能给出不合理构图，建议配合 `savePath` 人工过一遍 plan。
- **不保证图生 3D 几何一致**：灰盒是程序化图元/声明式 spec，不会复刻概念图的建筑形体（路线图做图生 3D）。
- **URP/HDRP 未专门适配**：Unity 默认天空盒/光照参数在 URP/HDRP 下可能表现不同；Unity 2022.3 无内置 glTF
  导入器（`.glb` 会变 `DefaultAsset`），所以适配器走 `.fbx`。
- **ComfyUI 只支持 API 格式工作流**；只支持单机 `127.0.0.1` 默认端口（可改 `comfyUrl`）。
- **不接管软件生命周期**：不安装/启动/停止 ComfyUI、Blender、Unity；不接 MCP 桥接。
- **不做碰撞体/刚体物理**：校验只有 AABB 级静态规则（边界/穿透/悬浮/碰撞/支撑），不生成碰撞体、不做导航，白盒不保证可行走。
- **贴图是可选增强，不做版式级美术**：SuperPBR 走「隔离渲染 → 分解」，每对象单独材质、Smart UV 自动投影；
  不合并图集、不做跨对象纹理一致性，也不做超分辨率。8 GB 显存建议 512 分辨率、`textureObjects=main`。
- **材质映射需要自备 CC0 贴图**：插件不自带任何贴图文件，也不自动下载；`assetLibraryPath` 未配置或文件缺失时
  自动回退纯色（场景仍可跑通，只是没有纹理）。SuperPBR 不发明纹理细节，想要真实质感优先用材质映射。
- **几何映射需要自备 GLB 资产**：插件不自带任何真实模型，也不自动下载；`assetModelPath` 未配置或 `modelPath`
  文件缺失时自动回退程序化图元（场景仍可跑通）。导入时做底部中心对齐 + 等比缩放，不保证原资产的坐标轴/法线
  约定与 Blender 完全一致；超大 GLB 会拖慢装配。

## 路线图

1. ~~**PBR 贴图**~~：SuperPBR 版本已实现（可选增强，见「可选增强：PBR 贴图」）；~~**材质映射**~~已实现
   （见「材质映射（asset-library 贴图）」，按 key 注入 CC0 贴图）；~~**资产库几何映射**~~已实现
   （见「几何模型库配置」，GLB 替换程序化图元）；CHORD 等更强的材质分解方案仍在评估。
2. **图生 3D**：Hunyuan3D 2.1（shape 版约 10GB 显存、full 版约 29GB）把概念图变成真实几何，替代程序化图元。
3. **UE / Godot 适配器**：与 Unity 适配器等价的自动装配脚本。
4. MCP 桥接（Unity Editor 常驻连接、增量装配）。
5. 布局约束增强（道路连通性、可达性）。

## 许可证

[MIT](LICENSE) © 2026 LesterTown
