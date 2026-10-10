/**
 * AI Town Edge Worker —— 只做哑管道（架构 §5.2 / 红线 ②）。
 *
 * 为什么这里几乎不写逻辑：CF 免费档给 Worker 的 CPU 只有 10ms/请求，
 * 任何「在边缘算东西」的想法都会在观众变多时崩掉。所以：
 *   - WebSocket 直通引擎（不解析帧、不改帧、不缓冲）
 *   - REST 只做无脑转发 + 超时保护
 *   - LLM / 向量 / 历史查询一律留 501 占位，等 M2~M4 再按红线实现
 *
 * 免费档红线（勿违）：
 *   ① 前端只走 WebSocket —— 本 Worker 不提供任何供轮询的「全量状态」端点被高频调用
 *   ② Worker 只做哑管道 —— 不在这里跑计时、不在这里跑 A*
 *   ③ tick 热写全落引擎 SQLite —— D1 只在游戏日边界同步（M4）
 *   ④ 不用 Vectorize —— 向量检索在引擎侧本地暴力余弦（M3）
 */

export interface Env {
  SHADOW_DB: D1Database
  CONFIG_KV: KVNamespace
  ASSETS_R2?: R2Bucket
  AI?: Ai
  ENGINE_ORIGIN: string
  EDGE_SHARED_TOKEN: string
  VECTOR_BACKEND?: string
  EMBED_DIMS?: string
  EMBED_MODEL?: string
  MAX_DAILY_AI_CALLS?: string
  DEEPSEEK_API_KEY?: string
}

const ENGINE_TIMEOUT_MS = 3000

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // 边缘不缓存任何世界状态
      'cache-control': 'no-store',
    },
  })
}

function notImplemented(what: string, milestone: string): Response {
  return json({ ok: false, error: 'not_implemented', what, milestone }, 501)
}

/** 带超时的引擎请求（tunnel 抖动时不能让 Worker 挂着耗 CPU） */
async function fetchEngine(env: Env, path: string, init?: RequestInit): Promise<Response> {
  const url = env.ENGINE_ORIGIN.replace(/\/$/, '') + path
  const headers = new Headers(init?.headers)
  headers.set('X-Edge-Token', env.EDGE_SHARED_TOKEN)
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), ENGINE_TIMEOUT_MS)
  try {
    return await fetch(url, { ...init, headers, signal: ctrl.signal })
  } finally {
    clearTimeout(timer)
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const path = url.pathname

    // ── ① WebSocket：哑管道直通引擎 ──
    if (path === '/ws') {
      if (request.headers.get('Upgrade') !== 'websocket') {
        return json({ ok: false, error: 'expected_websocket_upgrade' }, 426)
      }
      try {
        return await fetchEngine(env, '/ws' + url.search, { headers: request.headers })
      } catch (err) {
        // 引擎没起来 / 隧道断：给前端一个明确的 502，前端会走重连退避
        return json({ ok: false, error: 'engine_unreachable', detail: String(err) }, 502)
      }
    }

    // ── ② 健康检查：顺手把引擎的 /health 透传（低频，仅用于部署验收）──
    if (path === '/api/health') {
      const started = Date.now()
      let engine: unknown = null
      let engineOk = false
      try {
        const res = await fetchEngine(env, '/health')
        engineOk = res.ok
        engine = await res.json()
      } catch (err) {
        engine = { error: String(err) }
      }
      return json({
        ok: true,
        edge: 'aitown-edge',
        engineOk,
        engine,
        edgeLatencyMs: Date.now() - started,
      })
    }

    // ── ③ 全量快照：只给调试/冷启动用，前端正常路径是 WebSocket ──
    if (path === '/api/state') {
      if (request.method !== 'GET') return json({ ok: false, error: 'method_not_allowed' }, 405)
      try {
        const res = await fetchEngine(env, '/api/state')
        return new Response(res.body, {
          status: res.status,
          headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
        })
      } catch (err) {
        return json({ ok: false, error: 'engine_unreachable', detail: String(err) }, 502)
      }
    }

    // ── ④ LLM 出口（M2）：只有引擎拿着 EDGE_SHARED_TOKEN 才能调用 ──
    if (path === '/api/llm') {
      if (request.headers.get('X-Edge-Token') !== env.EDGE_SHARED_TOKEN) {
        return json({ ok: false, error: 'unauthorized' }, 401)
      }
      return notImplemented('llm_proxy', 'M2')
    }

    // ── ⑤ Workers AI 向量（M3）：本地暴力余弦优先，这里留最小出口 ──
    if (path === '/api/embed') {
      if (request.headers.get('X-Edge-Token') !== env.EDGE_SHARED_TOKEN) {
        return json({ ok: false, error: 'unauthorized' }, 401)
      }
      return notImplemented('embed', 'M3')
    }

    // ── ⑥ D1 历史查询（M4）：只在游戏日边界有数据，别拿它做实时 ──
    if (path === '/api/history') {
      return notImplemented('history', 'M4')
    }

    return json({ ok: false, error: 'not_found', path }, 404)
  },
}
