/**
 * dsh-scene-skeleton-pipeline — Client 半边（设置页面板）。
 *
 * 形态与 dsh-cursor-dev 的 client.js 一致：手写、无构建，
 * 通过 `window.__ModuleLoader__.load({ id, factory })` 注册；
 * 面板挂在 `settings.section` 槽位，是插件在「设置」里的一个页签。
 *
 * 面板本身不探测环境：它只读宿主 half 注册的 HTTP 路由
 *   GET  /plugins/dsh-scene-skeleton-pipeline/state           当前配置 + 三项检测结果 + 流水线状态
 *   POST /plugins/dsh-scene-skeleton-pipeline/check           重新检测
 *   POST /plugins/dsh-scene-skeleton-pipeline/config          保存配置并立即重新检测
 *   POST /plugins/dsh-scene-skeleton-pipeline/pipeline/run    跑一次流水线（dryRun:true 仅编排；dryRun:false 真实启动软件）
 */

window.__ModuleLoader__.load({
  id: 'dsh-scene-skeleton-pipeline',
  factory: require => {
    const module = { exports: {} }
    const exports = module.exports

    const react = require('react')
    const h = react.createElement

    const BASE = '/plugins/dsh-scene-skeleton-pipeline'
    const SETTINGS_ID = 'dsh-scene-skeleton-pipeline'

    const FONT =
      '-apple-system, "PingFang SC", "Segoe UI", system-ui, sans-serif'
    const MONO = 'ui-monospace, SFMono-Regular, Consolas, monospace'

    const CARD = {
      border: '1px solid rgba(127,127,127,.24)',
      borderRadius: '10px',
      padding: '12px 14px',
      display: 'flex',
      flexDirection: 'column',
      gap: '6px',
    }
    const TITLE = { font: `600 14px/1.4 ${FONT}`, color: 'inherit' }
    const SUBTITLE = { font: `12px/1.6 ${FONT}`, opacity: 0.72, color: 'inherit' }
    const LABEL = { font: `600 12px/1.4 ${FONT}`, opacity: 0.85, color: 'inherit' }
    const DETAIL = { font: `12px/1.6 ${FONT}`, opacity: 0.78, color: 'inherit', wordBreak: 'break-word' }
    const PATH_TEXT = { font: `11px/1.5 ${MONO}`, opacity: 0.6, color: 'inherit', wordBreak: 'break-all' }
    const INPUT = {
      boxSizing: 'border-box',
      width: '100%',
      padding: '6px 9px',
      font: `12px/1.5 ${MONO}`,
      color: 'inherit',
      background: 'rgba(127,127,127,.10)',
      border: '1px solid rgba(127,127,127,.28)',
      borderRadius: '7px',
    }
    const BUTTON = {
      padding: '6px 14px',
      font: `12px/1.5 ${FONT}`,
      color: 'inherit',
      background: 'rgba(127,127,127,.16)',
      border: '1px solid rgba(127,127,127,.28)',
      borderRadius: '8px',
      cursor: 'pointer',
    }
    const BUTTON_PRIMARY = {
      ...BUTTON,
      background: 'var(--dsh-accent, #6d8cff)',
      borderColor: 'transparent',
      color: '#fff',
    }

    const STATUS_COLOR = {
      ok: '#3fbf7f',
      missing: '#e0a23a',
      error: '#e5636c',
    }
    const STATUS_TEXT = {
      ok: '正常',
      missing: '缺失',
      error: '错误',
    }
    const ITEM_LABEL = {
      blender: 'Blender',
      comfy: 'ComfyUI',
      unity: 'Unity',
    }
    const STAGE_STATUS_COLOR = {
      pending: '#8b8b93',
      running: '#6d8cff',
      ok: STATUS_COLOR.ok,
      blocked: STATUS_COLOR.missing,
      skipped: '#8b8b93',
      failed: STATUS_COLOR.error,
    }
    const STAGE_STATUS_TEXT_ZH = {
      pending: '待运行',
      running: '运行中',
      ok: '完成',
      blocked: '阻塞',
      skipped: '跳过',
      failed: '失败',
    }
    const STAGE_STATUS_TEXT_EN = {
      pending: 'pending',
      running: 'running',
      ok: 'done',
      blocked: 'blocked',
      skipped: 'skipped',
      failed: 'failed',
    }

    /** 面板文案（跟随 App 语言）。 */
    function texts(lang) {
      const zh = lang !== 'en'
      return {
        title: zh ? '场景骨架流水线' : 'Scene skeleton pipeline',
        subtitle: zh
          ? '环境检测 + 真实流水线：ComfyUI 出图 → Blender 生成场景骨架与布局 JSON → Unity 按布局装配场景（分组 / 光照 / 相机）。'
          : 'Environment checks plus a real pipeline: ComfyUI image → Blender skeleton and layout JSON → Unity assembles the scene (groups / lighting / camera).',
        pipelineTitle: zh ? '流水线（真实执行）' : 'Pipeline (real execution)',
        pipelineNote: zh
          ? 'dry-run 只做节点编排与依赖检查；真实执行会启动 ComfyUI 出图（1-3 分钟）、Blender headless 生成骨架与 layout.json、Unity batchmode 按布局装配场景（首次 1-4 分钟）。'
          : 'Dry-run only orchestrates; real execution launches ComfyUI (1-3 min), Blender headless (skeleton + layout.json) and Unity batchmode (1-4 min on first run).',
        promptHint: zh ? '场景描述，例如：一座带台阶的日式庭院' : 'Scene prompt, e.g. a Japanese courtyard with stone steps',
        runDry: zh ? '运行 dry-run' : 'Run dry-run',
        runReal: zh ? '真实执行' : 'Run for real',
        confirmReal: zh ? '确认真实执行（会启动软件）' : 'Confirm real run (launches apps)',
        realRunning: zh ? '真实执行中…（可能需要几分钟）' : 'Running for real… (may take minutes)',
        cancel: zh ? '取消' : 'Cancel',
        artifacts: zh ? '产物' : 'Artifacts',
        sceneSummary: zh ? '场景装配结果' : 'Scene assembly',
        scenePathLabel: zh ? '场景' : 'Scene',
        objectCountLabel: zh ? '对象数' : 'Objects',
        groupsLabel: zh ? '分组' : 'Groups',
        prefabLabel: zh ? 'prefab' : 'Prefab',
        runningPipeline: zh ? '运行中…' : 'Running…',
        jobStatus: zh ? 'job 状态' : 'job status',
        noJobYet: zh ? '还没有运行过流水线' : 'No pipeline run yet',
        check: zh ? '重新检测' : 'Re-check',
        save: zh ? '保存并重新检测' : 'Save and re-check',
        saving: zh ? '保存中…' : 'Saving…',
        checking: zh ? '检测中…' : 'Checking…',
        lastChecked: zh ? '最近检测' : 'Last checked',
        never: zh ? '尚未检测' : 'never',
        saveOk: zh ? '已保存到插件配置' : 'Saved to plugin config',
        blenderHint: zh ? 'Blender 可执行文件路径（留空自动探测）' : 'Blender executable (empty = auto-detect)',
        comfyHint: zh ? 'ComfyUI 地址' : 'ComfyUI URL',
        unityHint: zh ? 'Unity 项目根目录（含 ProjectSettings/ProjectVersion.txt）' : 'Unity project root (contains ProjectSettings/ProjectVersion.txt)',
        workflowHint: zh ? 'ComfyUI API 工作流 JSON（留空用内置 txt2img 模板）' : 'ComfyUI API workflow JSON (empty = built-in txt2img template)',
        checkpointHint: zh ? 'checkpoint 文件名（留空自动选第一个）' : 'Checkpoint filename (empty = first available)',
        negativeHint: zh ? '负向提示词（留空用内置默认）' : 'Negative prompt (empty = built-in default)',
        unityExeHint: zh ? 'Unity 可执行文件（留空按工程版本自动探测）' : 'Unity executable (empty = detect from project version)',
        outputHint: zh ? '产物输出目录（留空用 DSH_HOME 下默认目录）' : 'Output directory (empty = default under DSH_HOME)',
        blenderModeHint: zh ? 'Blender 场景模式（scenic 声明式场景 / legacy 固定体块）' : 'Blender scene mode (scenic declarative / legacy boxes)',
        scenicWidthHint: zh ? 'scenic 庭院宽度（米，默认 24）' : 'scenic courtyard width (m, default 24)',
        scenicDepthHint: zh ? 'scenic 庭院深度（米，默认 20）' : 'scenic courtyard depth (m, default 20)',
        scenicWallHeightHint: zh ? 'scenic 墙高（米，默认 3.2）' : 'scenic wall height (m, default 3.2)',
        sceneSourceHint: zh ? '场景来源（template 模板 / llm 精确布局）' : 'Scene source (template / llm layout)',
        layoutObjectsHint: zh ? '布局 plan（JSON 文件路径或内联 JSON，sceneSource=llm 时使用）' : 'Layout plan (JSON path or inline JSON, used when sceneSource=llm)',
        layoutAxisHint: zh ? 'layout.json 坐标系（z-up = Blender 原生，默认；y-up = Unity 转换值）' : 'layout.json axis (z-up = Blender native, default; y-up = Unity converted)',
        validationCollisionHint: zh ? '布局校验：碰撞容差（米，三轴重叠都超过才算碰撞，默认 0.1）' : 'Layout validation: collision tolerance in metres (default 0.1)',
        validationFloatHint: zh ? '布局校验：悬浮容差（米，底部高于地面超过该值判为悬浮，默认 0.3）' : 'Layout validation: max float height in metres (default 0.3)',
        validationGroundHint: zh ? '布局校验：地面穿透容差（米，底部低于 -该值判为沉入地面，默认 0.05）' : 'Layout validation: ground tolerance in metres (default 0.05)',
        textureEnableHint: zh ? '是否启用 SuperPBR 贴图生成（true/false，默认 false）' : 'Enable SuperPBR textures (true/false, default false)',
        textureResolutionHint: zh ? '贴图分辨率（默认 512）' : 'Texture resolution (default 512)',
        textureObjectsHint: zh ? '贴图范围（main = 地形与主要建筑 / all = 全部对象）' : 'Texture scope (main = terrain + main buildings / all = all objects)',
        texturePrefixHint: zh ? '贴图提示词前缀（预留，SuperPBR 未使用）' : 'Texture prompt prefix (reserved; unused by SuperPBR)',
        textureLabel: zh ? '贴图' : 'Textures',
        materialLabel: zh ? '材质映射' : 'Material mapping',
        materialNone: zh ? '未配置（纯色）' : 'not configured (solid colors)',
        materialWith: zh ? '个 key 用贴图' : 'keys textured',
        materialFallback: zh ? '个 key 回退纯色' : 'keys fallback',
        assetLibraryHint: zh ? '材质贴图根目录（留空=纯色 fallback）' : 'Texture root (empty = solid colors)',
        geometryLabel: zh ? '几何映射' : 'Geometry mapping',
        geometryNone: zh ? '未配置（全部图元）' : 'not configured (all primitives)',
        geometryWith: zh ? '个真实模型' : 'real models',
        geometryFallback: zh ? '个回退图元' : 'primitive fallbacks',
        assetModelHint: zh ? '真实模型根目录（留空=全部程序化图元；配置后按 modelPath 导入 .glb/.gltf）' : 'Real model root (empty = all primitives; else import .glb/.gltf by modelPath)',
        textureNone: zh ? '未启用' : 'disabled',
        textureFailed: zh ? '失败对象' : 'failed',
        validationBoundsHint: zh ? '布局校验：场景边界（米，格式 -50,50，默认 ±50）' : 'Layout validation: scene bounds in metres (e.g. -50,50)',
        planTip: zh ? '可以让模型调用 plan_scene_layout 工具，把文字描述生成为这里的 plan。' : 'Ask the model to call plan_scene_layout to turn text into a plan.',
        unityAdapterHint: zh ? 'Unity 适配器（true = 在 Blender 之后追加 Unity 装配节点；默认 false）' : 'Unity adapter (true = append a Unity assembly stage; default false)',
        extra: zh ? '可选配置' : 'Optional settings',
      }
    }

    function langOf(ctx) {
      try {
        const locale = ctx.get?.('locale')?.getLocale?.()
        return typeof locale?.active === 'string' && locale.active.startsWith('en') ? 'en' : 'zh'
      } catch {
        return 'zh'
      }
    }

    /** 带 cookie 的 JSON 请求（面板与宿主同源）。 */
    async function request(path, init) {
      const response = await fetch(BASE + path, {
        credentials: 'same-origin',
        cache: 'no-store',
        ...init,
      })
      const text = await response.text()
      let body = null
      try {
        body = text === '' ? null : JSON.parse(text)
      } catch {
        body = { ok: false, error: text.slice(0, 400) }
      }
      if (!response.ok) {
        const message = body && typeof body === 'object' && typeof body.error === 'string' ? body.error : `HTTP ${response.status}`
        throw new Error(message)
      }
      return body
    }

    /** 一行状态：圆点 + 名称 + 状态词。 */
    function StatusRow({ item, status, lang }) {
      const color = STATUS_COLOR[status] ?? STATUS_COLOR.error
      return h(
        'div',
        { style: { display: 'flex', alignItems: 'center', gap: '8px' } },
        h('span', {
          style: { width: '8px', height: '8px', borderRadius: '50%', background: color, flex: '0 0 auto' },
        }),
        h('span', { style: { font: `600 13px/1.4 ${FONT}`, color: 'inherit' } }, ITEM_LABEL[item] ?? item),
        h(
          'span',
          { style: { font: `11px/1 ${FONT}`, color, border: `1px solid ${color}`, borderRadius: '999px', padding: '2px 8px' } },
          STATUS_TEXT[status] ?? status ?? '?',
        ),
      )
    }

    /** 一个小号配置输入框（标签 + 输入框）。 */
    function ExtraField({ label, value, onChange, placeholder }) {
      return h(
        'label',
        { style: { display: 'flex', flexDirection: 'column', gap: '3px' } },
        h('span', { style: { font: `11px/1.4 ${FONT}`, opacity: 0.72 } }, label),
        h('input', {
          style: INPUT,
          value: value ?? '',
          placeholder: placeholder ?? '',
          spellCheck: false,
          onChange: event => onChange(event.target.value),
        }),
      )
    }

    /** 下拉选择（目前用于 layoutAxis）。 */
    function SelectField({ label, value, options, onChange }) {
      return h(
        'label',
        { style: { display: 'flex', flexDirection: 'column', gap: '3px' } },
        h('span', { style: { font: `11px/1.4 ${FONT}`, opacity: 0.72 } }, label),
        h(
          'select',
          {
            style: INPUT,
            value: value ?? '',
            onChange: event => onChange(event.target.value),
          },
          options.map(([optionValue, optionLabel]) =>
            h('option', { key: optionValue, value: optionValue }, optionLabel),
          ),
        ),
      )
    }

    /** 单项卡片：状态 + detail + path + 输入框（可带附加配置项）。 */
    function ItemCard({ item, result, value, onChange, placeholder, extras, lang }) {
      const status = result?.status ?? 'missing'
      return h(
        'div',
        { style: CARD },
        h(StatusRow, { item, status, lang }),
        h('div', { style: DETAIL }, result?.detail ?? ''),
        result?.path
          ? h('div', { style: PATH_TEXT }, 'path: ' + result.path)
          : null,
        h('input', {
          style: INPUT,
          value: value ?? '',
          placeholder,
          spellCheck: false,
          onChange: event => onChange(event.target.value),
        }),
        ...(extras ?? []).map(field => h(ExtraField, { key: field.label, ...field })),
      )
    }

    /** 流水线区块：节点状态 + prompt 输入 + dry-run / 真实执行按钮。 */
    function PipelineSection({ state, lang, prompt, onPrompt, onRun, busy, confirmReal, onCancelReal }) {
      const zh = lang !== 'en'
      const t = texts(lang)
      const pipeline = state?.pipeline ?? null
      const lastJob = pipeline?.lastJob ?? null
      const stages =
        Array.isArray(lastJob?.stages) && lastJob.stages.length > 0
          ? lastJob.stages
          : (pipeline?.stages ?? []).map(stage => ({ ...stage, status: 'pending', detail: '' }))
      const jobStatus = lastJob?.status ?? null
      const summary = lastJob?.summary ?? null
      const artifactEntries = Array.isArray(lastJob?.artifacts)
        ? lastJob.artifacts.map(artifact => [artifact?.kind, artifact?.path])
        : Object.entries(lastJob?.artifacts ?? {})
      const visibleArtifacts = artifactEntries.filter(
        ([, path]) => typeof path === 'string' && path !== '',
      )
      const statusTextOf = status =>
        (zh ? STAGE_STATUS_TEXT_ZH : STAGE_STATUS_TEXT_EN)[status] ?? status ?? '?'
      const colorOf = status => STAGE_STATUS_COLOR[status] ?? STAGE_STATUS_COLOR.pending

      return h(
        'div',
        { style: { ...CARD, gap: '8px' } },
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', gap: '10px', flexWrap: 'wrap' } },
          h('span', { style: TITLE }, t.pipelineTitle),
          jobStatus
            ? h(
                'span',
                {
                  style: {
                    font: `11px/1 ${FONT}`,
                    color: colorOf(jobStatus),
                    border: `1px solid ${colorOf(jobStatus)}`,
                    borderRadius: '999px',
                    padding: '2px 8px',
                  },
                },
                `${t.jobStatus}: ${statusTextOf(jobStatus)}`,
              )
            : h('span', { style: SUBTITLE }, t.noJobYet),
        ),
        h('div', { style: SUBTITLE }, t.pipelineNote),
        h(
          'div',
          { style: { display: 'flex', flexDirection: 'column', gap: '6px' } },
          ...stages.map(stage =>
            h(
              'div',
              { key: stage.id, style: { display: 'flex', alignItems: 'flex-start', gap: '8px' } },
              h('span', {
                style: {
                  width: '8px',
                  height: '8px',
                  borderRadius: '50%',
                  marginTop: '5px',
                  flex: '0 0 auto',
                  background: colorOf(stage.status),
                },
              }),
              h(
                'div',
                { style: { display: 'flex', flexDirection: 'column', gap: '1px', minWidth: 0 } },
                h(
                  'div',
                  { style: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' } },
                  h('span', { style: { font: `600 13px/1.4 ${FONT}` } }, stage.title ?? stage.label ?? stage.id),
                  h('span', { style: { font: `11px/1 ${FONT}`, color: colorOf(stage.status) } }, statusTextOf(stage.status)),
                ),
                stage.detail ? h('div', { style: DETAIL }, stage.detail) : null,
              ),
            ),
          ),
        ),
        pipeline?.outputDir
          ? h('div', { style: PATH_TEXT }, `${t.outputHint}: ${pipeline.outputDir}`)
          : null,
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' } },
          h('input', {
            style: { ...INPUT, flex: '1 1 220px' },
            value: prompt ?? '',
            placeholder: t.promptHint,
            spellCheck: false,
            onChange: event => onPrompt?.(event.target.value),
          }),
          h(
            'button',
            { style: BUTTON, disabled: busy, onClick: () => onRun?.(true) },
            busy ? t.runningPipeline : t.runDry,
          ),
          h(
            'button',
            { style: BUTTON_PRIMARY, disabled: busy, onClick: () => onRun?.(false) },
            busy ? t.realRunning : confirmReal ? t.confirmReal : t.runReal,
          ),
          confirmReal
            ? h('button', { style: BUTTON, disabled: busy, onClick: () => onCancelReal?.() }, t.cancel)
            : null,
        ),
        visibleArtifacts.length > 0
          ? h(
              'div',
              { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
              h('div', { style: { font: `11px/1.4 ${FONT}`, opacity: 0.72 } }, t.artifacts),
              ...visibleArtifacts.map(([kind, path]) =>
                h('div', { key: `${kind}-${path}`, style: PATH_TEXT }, `${kind}: ${path}`),
              ),
            )
          : null,
        summary && (summary.scenePath || summary.objectCount != null)
          ? h(
              'div',
              { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
              h('div', { style: { font: `11px/1.4 ${FONT}`, opacity: 0.72 } }, t.sceneSummary),
              summary.scenePath
                ? h('div', { style: PATH_TEXT }, `${t.scenePathLabel}: ${summary.scenePath}`)
                : null,
              summary.root
                ? h('div', { style: PATH_TEXT }, `root: ${summary.root}`)
                : null,
              summary.objectCount != null
                ? h('div', { style: PATH_TEXT }, `${t.objectCountLabel}: ${summary.objectCount}`)
                : null,
              Array.isArray(summary.groups) && summary.groups.length > 0
                ? h('div', { style: PATH_TEXT }, `${t.groupsLabel}: ${summary.groups.join(' / ')}`)
                : null,
              summary.prefabPath
                ? h('div', { style: PATH_TEXT }, `${t.prefabLabel}: ${summary.prefabPath}`)
                : null,
              summary.texture
                ? h(
                    'div',
                    { style: PATH_TEXT },
                    summary.texture.enabled
                      ? summary.texture.error
                        ? `${t.textureLabel}: ${summary.texture.error}`
                        : `${t.textureLabel}: ${summary.texture.objectCount ?? 0} / ${summary.texture.model ?? 'superpbr'} ${summary.texture.resolution ?? ''}px` +
                          (summary.texture.workflow === 'lite' ? '（lite：无 MoGe 法线）' : '') +
                          (summary.texture.failedCount ? `（${t.textureFailed} ${summary.texture.failedCount}）` : '') +
                          (summary.texture.note ? `（${summary.texture.note}）` : '')
                      : `${t.textureLabel}: ${t.textureNone}`,
                  )
                : null,
              summary.materialMapping
                ? h(
                    'div',
                    { style: PATH_TEXT },
                    summary.materialMapping.enabled
                      ? `${t.materialLabel}: ${(summary.materialMapping.keysWithTextures ?? []).length} ${t.materialWith}` +
                        `，${(summary.materialMapping.keysFallback ?? []).length} ${t.materialFallback}` +
                        (summary.materialMapping.assetLibraryPath ? `（${summary.materialMapping.assetLibraryPath}）` : '')
                      : `${t.materialLabel}: ${t.materialNone}`,
                  )
                : null,
              summary.geometryMapping
                ? h(
                    'div',
                    { style: PATH_TEXT },
                    summary.geometryMapping.modelsUsed || summary.geometryMapping.primitivesFallback
                      ? `${t.geometryLabel}: ${summary.geometryMapping.modelsUsed ?? 0} ${t.geometryWith}` +
                        `，${summary.geometryMapping.primitivesFallback ?? 0} ${t.geometryFallback}`
                      : `${t.geometryLabel}: ${t.geometryNone}`,
                  )
                : null,
            )
          : null,
      )
    }

    function SettingsPanel(props) {
      const ctx = props?.ctx
      const lang = langOf(ctx ?? {})
      const t = texts(lang)
      const [state, setState] = react.useState(null)
      const [form, setForm] = react.useState({
        blenderExe: '',
        comfyUrl: 'http://127.0.0.1:8188',
        comfyWorkflowPath: '',
        comfyCheckpoint: '',
        comfyNegativePrompt: '',
        unityProjectPath: '',
        unityExe: '',
        outputDir: '',
        blenderSceneMode: 'scenic',
        scenicWidth: '24',
        scenicDepth: '20',
        scenicWallHeight: '3.2',
        sceneSource: 'template',
        layoutObjects: '',
        layoutAxis: 'z-up',
        validationMaxCollisionOverlap: '0.1',
        validationMaxFloatHeight: '0.3',
        validationGroundTolerance: '0.05',
        validationSceneBounds: '-50,50',
        enableUnityAdapter: 'false',
        assetLibraryPath: '',
        assetModelPath: '',
        enableTextureGeneration: 'false',
        textureResolution: '512',
        textureObjects: 'main',
        texturePromptPrefix: '',
      })
      const [busy, setBusy] = react.useState('')
      const [note, setNote] = react.useState(null)
      const [prompt, setPrompt] = react.useState('')
      const [pipelineBusy, setPipelineBusy] = react.useState(false)
      const [confirmReal, setConfirmReal] = react.useState(false)

      const applyState = next => {
        setState(next)
        if (next && next.config) {
          setForm({
            blenderExe: next.config.blenderExe ?? '',
            comfyUrl: next.config.comfyUrl ?? 'http://127.0.0.1:8188',
            comfyWorkflowPath: next.config.comfyWorkflowPath ?? '',
            comfyCheckpoint: next.config.comfyCheckpoint ?? '',
            comfyNegativePrompt: next.config.comfyNegativePrompt ?? '',
            unityProjectPath: next.config.unityProjectPath ?? '',
            unityExe: next.config.unityExe ?? '',
            outputDir: next.config.outputDir ?? '',
            blenderSceneMode: next.config.blenderSceneMode ?? 'scenic',
            scenicWidth: next.config.scenicWidth ?? '24',
            scenicDepth: next.config.scenicDepth ?? '20',
            scenicWallHeight: next.config.scenicWallHeight ?? '3.2',
            sceneSource: next.config.sceneSource ?? 'template',
            layoutObjects: next.config.layoutObjects ?? '',
            layoutAxis: next.config.layoutAxis ?? 'z-up',
            validationMaxCollisionOverlap: String(next.config.layoutValidation?.maxCollisionOverlap ?? '0.1'),
            validationMaxFloatHeight: String(next.config.layoutValidation?.maxFloatHeight ?? '0.3'),
            validationGroundTolerance: String(next.config.layoutValidation?.groundTolerance ?? '0.05'),
            validationSceneBounds: Array.isArray(next.config.layoutValidation?.sceneBounds)
              ? next.config.layoutValidation.sceneBounds.join(',')
              : '-50,50',
            enableUnityAdapter: next.config.enableUnityAdapter === true ? 'true' : 'false',
            assetLibraryPath: next.config.assetLibraryPath ?? '',
            assetModelPath: next.config.assetModelPath ?? '',
            enableTextureGeneration: next.config.enableTextureGeneration === true ? 'true' : 'false',
            textureResolution: String(next.config.textureResolution ?? '512'),
            textureObjects: next.config.textureObjects === 'all' ? 'all' : 'main',
            texturePromptPrefix: next.config.texturePromptPrefix ?? '',
          })
        }
      }

      react.useEffect(() => {
        let alive = true
        request('/state')
          .then(next => {
            if (alive) applyState(next)
          })
          .catch(error => {
            if (alive) setNote({ kind: 'bad', text: String(error?.message ?? error) })
          })
        return () => {
          alive = false
        }
      }, [])

      const recheck = async () => {
        setBusy('check')
        setNote(null)
        try {
          const next = await request('/check', { method: 'POST' })
          applyState(next)
        } catch (error) {
          setNote({ kind: 'bad', text: String(error?.message ?? error) })
        } finally {
          setBusy('')
        }
      }

      const save = async () => {
        setBusy('save')
        setNote(null)
        try {
          const body = {
            ...form,
            layoutValidation: {
              maxCollisionOverlap: Number(form.validationMaxCollisionOverlap),
              maxFloatHeight: Number(form.validationMaxFloatHeight),
              groundTolerance: Number(form.validationGroundTolerance),
              sceneBounds: String(form.validationSceneBounds)
                .split(/[,，\s]+/)
                .filter(item => item !== '')
                .map(Number),
            },
          }
          const next = await request('/config', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(body),
          })
          applyState(next)
          if (next?.saved === true) {
            const where = Array.isArray(next.saveTargets) && next.saveTargets.includes('file') ? `（${next.configFile ?? ''}）` : ''
            setNote({ kind: 'good', text: t.saveOk + where })
          } else {
            setNote({ kind: 'bad', text: next?.saveError ?? '保存失败' })
          }
        } catch (error) {
          setNote({ kind: 'bad', text: String(error?.message ?? error) })
        } finally {
          setBusy('')
        }
      }

      const runPipeline = async dryRun => {
        if (dryRun === false && confirmReal !== true) {
          setConfirmReal(true)
          return
        }
        setConfirmReal(false)
        setPipelineBusy(true)
        setNote(null)
        try {
          const next = await request('/pipeline/run', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ prompt, dryRun: dryRun !== false }),
          })
          if (next?.snapshot) applyState(next.snapshot)
          if (next?.job && next.job.status !== 'done') {
            const failed = (next.job.stages ?? []).find(stage => stage.status === 'failed' || stage.status === 'blocked')
            setNote({ kind: 'bad', text: failed?.detail ?? `job ${next.job.status}` })
          }
        } catch (error) {
          setNote({ kind: 'bad', text: String(error?.message ?? error) })
        } finally {
          setPipelineBusy(false)
        }
      }

      const environment = state?.environment ?? null
      const checkedAt = state?.checkedAt

      return h(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: '12px', padding: '2px', font: `13px/1.6 ${FONT}`, color: 'inherit' } },
        h('div', { style: TITLE }, t.title),
        h('div', { style: SUBTITLE }, t.subtitle),
        environment
          ? h(
              'div',
              { style: { display: 'flex', flexDirection: 'column', gap: '10px' } },
              h(ItemCard, {
                item: 'blender',
                result: environment.blender,
                value: form.blenderExe,
                placeholder: t.blenderHint,
                lang,
                onChange: value => setForm(prev => ({ ...prev, blenderExe: value })),
              }),
              h(ItemCard, {
                item: 'comfy',
                result: environment.comfy,
                value: form.comfyUrl,
                placeholder: t.comfyHint,
                lang,
                extras: [
                  {
                    label: t.workflowHint,
                    value: form.comfyWorkflowPath,
                    placeholder: 'config.json / workflow_api.json',
                    onChange: value => setForm(prev => ({ ...prev, comfyWorkflowPath: value })),
                  },
                  {
                    label: t.checkpointHint,
                    value: form.comfyCheckpoint,
                    placeholder: 'DreamShaper_8_pruned.safetensors',
                    onChange: value => setForm(prev => ({ ...prev, comfyCheckpoint: value })),
                  },
                  {
                    label: t.negativeHint,
                    value: form.comfyNegativePrompt,
                    placeholder: 'blurry, low quality, watermark',
                    onChange: value => setForm(prev => ({ ...prev, comfyNegativePrompt: value })),
                  },
                ],
                onChange: value => setForm(prev => ({ ...prev, comfyUrl: value })),
              }),
              h(ItemCard, {
                item: 'unity',
                result: environment.unity,
                value: form.unityProjectPath,
                placeholder: t.unityHint,
                lang,
                extras: [
                  {
                    label: t.unityExeHint,
                    value: form.unityExe,
                    placeholder: '/Applications/Unity/Hub/Editor/<version>/Unity.app/Contents/MacOS/Unity',
                    onChange: value => setForm(prev => ({ ...prev, unityExe: value })),
                  },
                ],
                onChange: value => setForm(prev => ({ ...prev, unityProjectPath: value })),
              }),
              h(ExtraField, {
                label: t.outputHint,
                value: form.outputDir,
                placeholder: '~/.dsh/scene-skeleton-pipeline/outputs',
                onChange: value => setForm(prev => ({ ...prev, outputDir: value })),
              }),
              h(ExtraField, {
                label: t.blenderModeHint,
                value: form.blenderSceneMode,
                placeholder: 'scenic（默认）/ legacy',
                onChange: value => setForm(prev => ({ ...prev, blenderSceneMode: value })),
              }),
              h(ExtraField, {
                label: t.scenicWidthHint,
                value: form.scenicWidth,
                placeholder: '24',
                onChange: value => setForm(prev => ({ ...prev, scenicWidth: value })),
              }),
              h(ExtraField, {
                label: t.scenicDepthHint,
                value: form.scenicDepth,
                placeholder: '20',
                onChange: value => setForm(prev => ({ ...prev, scenicDepth: value })),
              }),
              h(ExtraField, {
                label: t.scenicWallHeightHint,
                value: form.scenicWallHeight,
                placeholder: '3.2',
                onChange: value => setForm(prev => ({ ...prev, scenicWallHeight: value })),
              }),
              h(ExtraField, {
                label: t.sceneSourceHint,
                value: form.sceneSource,
                placeholder: 'template（默认）/ llm',
                onChange: value => setForm(prev => ({ ...prev, sceneSource: value })),
              }),
              h(ExtraField, {
                label: t.layoutObjectsHint,
                value: form.layoutObjects,
                placeholder: '~/plan.json 或 {"objects":[...]}',
                onChange: value => setForm(prev => ({ ...prev, layoutObjects: value })),
              }),
              h(SelectField, {
                label: t.layoutAxisHint,
                value: form.layoutAxis,
                options: [
                  ['z-up', 'z-up（Blender 原生，默认）'],
                  ['y-up', 'y-up（Unity 转换值）'],
                ],
                onChange: value => setForm(prev => ({ ...prev, layoutAxis: value })),
              }),
              h(ExtraField, {
                label: t.unityAdapterHint,
                value: form.enableUnityAdapter,
                placeholder: 'false（默认）/ true',
                onChange: value => setForm(prev => ({ ...prev, enableUnityAdapter: value })),
              }),
              h(ExtraField, {
                label: t.validationCollisionHint,
                value: form.validationMaxCollisionOverlap,
                placeholder: '0.1',
                onChange: value => setForm(prev => ({ ...prev, validationMaxCollisionOverlap: value })),
              }),
              h(ExtraField, {
                label: t.validationFloatHint,
                value: form.validationMaxFloatHeight,
                placeholder: '0.3',
                onChange: value => setForm(prev => ({ ...prev, validationMaxFloatHeight: value })),
              }),
              h(ExtraField, {
                label: t.validationGroundHint,
                value: form.validationGroundTolerance,
                placeholder: '0.05',
                onChange: value => setForm(prev => ({ ...prev, validationGroundTolerance: value })),
              }),
              h(ExtraField, {
                label: t.validationBoundsHint,
                value: form.validationSceneBounds,
                placeholder: '-50,50',
                onChange: value => setForm(prev => ({ ...prev, validationSceneBounds: value })),
              }),
              h(ExtraField, {
                label: t.assetLibraryHint,
                value: form.assetLibraryPath,
                placeholder: '/path/to/textures（含 stone/albedo.png 等）',
                onChange: value => setForm(prev => ({ ...prev, assetLibraryPath: value })),
              }),
              h(ExtraField, {
                label: t.assetModelHint,
                value: form.assetModelPath,
                placeholder: '/path/to/models（含 kenney_nature/tree_pine.glb 等）',
                onChange: value => setForm(prev => ({ ...prev, assetModelPath: value })),
              }),
              h(ExtraField, {
                label: t.textureEnableHint,
                value: form.enableTextureGeneration,
                placeholder: 'false（默认）/ true',
                onChange: value => setForm(prev => ({ ...prev, enableTextureGeneration: value })),
              }),
              h(ExtraField, {
                label: t.textureResolutionHint,
                value: form.textureResolution,
                placeholder: '512',
                onChange: value => setForm(prev => ({ ...prev, textureResolution: value })),
              }),
              h(SelectField, {
                label: t.textureObjectsHint,
                value: form.textureObjects,
                options: [
                  ['main', 'main（地形 + 主要建筑）'],
                  ['all', 'all（全部对象）'],
                ],
                onChange: value => setForm(prev => ({ ...prev, textureObjects: value })),
              }),
              h(ExtraField, {
                label: t.texturePrefixHint,
                value: form.texturePromptPrefix,
                placeholder: '（预留）',
                onChange: value => setForm(prev => ({ ...prev, texturePromptPrefix: value })),
              }),
              h('div', { style: SUBTITLE }, t.planTip),
            )
          : h('div', { style: SUBTITLE }, t.checking),
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', gap: '10px', flexWrap: 'wrap' } },
          h(
            'button',
            { style: BUTTON_PRIMARY, disabled: busy !== '', onClick: save },
            busy === 'save' ? t.saving : t.save,
          ),
          h('button', { style: BUTTON, disabled: busy !== '', onClick: recheck }, busy === 'check' ? t.checking : t.check),
          h('span', { style: SUBTITLE }, `${t.lastChecked}: ${checkedAt ?? t.never}`),
        ),
        note ? h('div', { style: { font: `12px/1.5 ${FONT}`, color: note.kind === 'good' ? STATUS_COLOR.ok : STATUS_COLOR.error } }, note.text) : null,
        h(PipelineSection, {
          state,
          lang,
          prompt,
          onPrompt: setPrompt,
          onRun: runPipeline,
          busy: pipelineBusy,
          confirmReal,
          onCancelReal: () => setConfirmReal(false),
        }),
        state?.configEditable === false
          ? h('div', { style: SUBTITLE }, lang === 'en' ? 'Config editing is unavailable on this host; edit the profile patch instead.' : '当前宿主没有配置编辑器；请直接修改 profile 的 patch 层配置。')
          : null,
      )
    }

    function apply(ctx) {
      const seats = []
      ctx.inject(['slots'], injected => {
        const slots = injected.get('slots')
        if (slots === undefined || typeof slots.register !== 'function' || typeof slots.inject !== 'function') {
          console.warn('[dsh-scene-skeleton-pipeline] slots 服务不可用，设置页面板未注册')
          return undefined
        }
        const release = slots.inject('settings.section', () =>
          slots.register(
            {
              name: 'settings.section',
              id: SETTINGS_ID,
              order: 63,
              label: () => (langOf(ctx) === 'en' ? 'Scene skeleton pipeline' : '场景骨架流水线'),
            },
            () => h(SettingsPanel, { ctx }),
          ),
        )
        seats.push(release)
        return undefined
      })
      ctx.effect(() => () => {
        for (const release of seats) {
          try {
            release?.()
          } catch {
            /* 卸载失败不影响应用 */
          }
        }
        seats.length = 0
      })
    }

    exports.name = 'dsh-scene-skeleton-pipeline-client'
    exports.apply = apply
    exports.inject = []
    return module.exports
  },
})
