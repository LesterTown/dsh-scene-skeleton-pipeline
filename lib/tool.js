/**
 * check_environment 工具定义。
 *
 * 走「纯对象定义 + ctx.tools.register」这条路（与 dsh-ops 的 ops_bash 一致）：
 * 不 import 任何 @deepseek-ai/* 值，因此不依赖 dsh-tools 是否可解析。
 * 注册时宿主会校验 output.schema，所以返回值必须是 schema 允许的形状。
 */

/** 单项检测结果的 JSON Schema。 */
const CHECK_ITEM_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['status', 'detail'],
  properties: {
    status: { type: 'string', enum: ['ok', 'missing', 'error'] },
    detail: { type: 'string' },
    path: { type: 'string' },
  },
}

/** check_environment 的返回值 schema：{ checkedAt, environment: { blender, comfy, unity } }。 */
export const ENVIRONMENT_OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['checkedAt', 'environment'],
  properties: {
    checkedAt: { type: 'string' },
    environment: {
      type: 'object',
      additionalProperties: false,
      required: ['blender', 'comfy', 'unity'],
      properties: {
        blender: CHECK_ITEM_SCHEMA,
        comfy: CHECK_ITEM_SCHEMA,
        unity: CHECK_ITEM_SCHEMA,
      },
    },
  },
}

const DESCRIPTION =
  '检查 Blender / ComfyUI / Unity 三项环境是否就绪，返回每项的状态、详情和路径。' +
  'status 为 ok / missing / error：missing 表示依赖没装或没启动（按 detail 的提示去配置或启动），' +
  'error 表示检测本身出错。只做探测，不会启动任何软件。'

/**
 * 构造 check_environment 工具定义。
 *
 * @param {import('./service.js').PipelineService} service - pipeline-service 实例。
 * @returns {object} 可直接交给 ctx.tools.register 的工具定义。
 */
export function createCheckEnvironmentTool(service) {
  return {
    name: 'check_environment',
    description: DESCRIPTION,
    parameters: {
      type: 'object',
      properties: {},
      additionalProperties: false,
    },
    output: {
      schema: ENVIRONMENT_OUTPUT_SCHEMA,
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }],
    },
    /**
     * 执行一次聚合检测：会刷新 service.environment，并原样返回最新结果。
     * @param {Record<string, unknown>} _args - 本工具没有参数。
     * @param {{ signal?: AbortSignal }} [_exec] - 宿主执行上下文。
     * @returns {Promise<object>} { checkedAt, environment }。
     */
    async execute(_args, _exec) {
      return await service.checkAll()
    },
  }
}
