/**
 * AI Town 前端 M1：WebSocket 观众端。
 *
 * 铁律（架构 §5.4.1）：只走 WebSocket。本文件里**没有任何 setInterval 拉 HTTP**，
 * 唯一的定时器是「连接健康检查」与「WS 保活 ping」，且都只在连接已建立时工作。
 */

// ────────────────────────────── 类型 ──────────────────────────────

interface Poi {
  id: string
  name: string
  x: number
  y: number
  w: number
  h: number
  kind: string
}

interface AgentView {
  id: string
  name: string
  persona: string
  color: string
  homeX: number
  homeY: number
  x: number
  y: number
  facing: string
  state: string
  target?: string
}

interface WorldEvent {
  kind: string
  agent: string
  name?: string
  poi?: string
  tick: number
}

interface Snapshot {
  t: 'snapshot'
  v: number
  tick: number
  gameDay: number
  minuteOfDay: number
  clock: string
  speed: number
  gridW: number
  gridH: number
  pois: Poi[]
  agents: AgentView[]
}

interface Diff {
  t: 'diff'
  tick: number
  gameDay: number
  minuteOfDay: number
  clock: string
  speed: number
  upd?: AgentView[]
  events?: WorldEvent[]
}

type ServerMsg = Snapshot | Diff | { t: 'pong' } | { t: 'error'; msg: string }

// ────────────────────────────── 连接地址 ──────────────────────────────

const EDGE_URL = (import.meta.env?.VITE_EDGE_URL as string | undefined) ?? ''

function wsURL(): string {
  if (EDGE_URL) {
    return EDGE_URL.replace(/^http/, 'ws').replace(/\/$/, '') + '/ws'
  }
  // 本地开发：直连引擎（引擎只绑 127.0.0.1，绝不会暴露到公网）
  if (location.hostname === '127.0.0.1' || location.hostname === 'localhost') {
    return 'ws://127.0.0.1:8080/ws'
  }
  // 同源部署（Pages + Worker 同域名时）
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}/ws`
}

// ────────────────────────────── 状态 ──────────────────────────────

interface Rendered extends AgentView {
  rx: number
  ry: number
}

const state = {
  conn: 'connecting' as 'connecting' | 'open' | 'closed' | 'limited',
  gridW: 64,
  gridH: 64,
  pois: [] as Poi[],
  agents: new Map<string, Rendered>(),
  tick: 0,
  clock: '00:00',
  gameDay: 0,
  speed: 1,
  lastFrameAt: 0,
  reconnects: 0,
  events: [] as WorldEvent[],
}

const $ = (id: string): HTMLElement => document.getElementById(id) as HTMLElement
const canvas = $('stage') as HTMLCanvasElement
const ctx = canvas.getContext('2d') as CanvasRenderingContext2D

// ────────────────────────────── WebSocket 客户端 ──────────────────────────────

let ws: WebSocket | null = null
let backoff = 500
let manualClose = false

function setStatus(s: typeof state.conn, text: string) {
  state.conn = s
  const el = $('status')
  el.dataset.state = s
  el.textContent = text
}

function connect() {
  setStatus('connecting', '连接中…')
  try {
    ws = new WebSocket(wsURL())
  } catch (err) {
    setStatus('closed', '地址无效')
    console.error('[ws] 创建失败', err)
    scheduleReconnect()
    return
  }

  ws.onopen = () => {
    backoff = 500
    setStatus('open', '已连接')
    console.log('[ws] 已连接', wsURL())
  }

  ws.onmessage = (ev: MessageEvent<string>) => {
    state.lastFrameAt = performance.now()
    let msg: ServerMsg
    try {
      msg = JSON.parse(ev.data) as ServerMsg
    } catch {
      console.warn('[ws] 收到非法 JSON')
      return
    }
    switch (msg.t) {
      case 'snapshot':
        applySnapshot(msg)
        break
      case 'diff':
        applyDiff(msg)
        break
      case 'pong':
        break
      case 'error':
        console.warn('[ws] 服务端错误', msg.msg)
        break
    }
  }

  ws.onclose = () => {
    if (manualClose) return
    setStatus('closed', '已断开')
    scheduleReconnect()
  }

  ws.onerror = () => {
    // onerror 之后一定会跟 onclose，重连逻辑统一放在 onclose
  }
}

function scheduleReconnect() {
  const wait = backoff
  backoff = Math.min(backoff * 2, 8000)
  state.reconnects++
  $('reconnects').textContent = String(state.reconnects)
  setStatus('closed', `重连中 ${(wait / 1000).toFixed(1)}s`)
  window.setTimeout(connect, wait)
}

/** 保活：20s 一次业务 ping；45s 无帧则判定假连接，主动重连（快速隧道会静默断流） */
function keepAlive() {
  window.setInterval(() => {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ t: 'ping' }))
      if (state.lastFrameAt && performance.now() - state.lastFrameAt > 45_000) {
        console.warn('[ws] 45s 无帧，判定连接已死，主动重连')
        ws.close()
      }
    }
  }, 20_000)
}

function applySnapshot(s: Snapshot) {
  state.gridW = s.gridW
  state.gridH = s.gridH
  state.pois = s.pois
  state.tick = s.tick
  state.clock = s.clock
  state.gameDay = s.gameDay
  state.speed = s.speed
  const seen = new Set<string>()
  for (const a of s.agents) {
    seen.add(a.id)
    const prev = state.agents.get(a.id)
    state.agents.set(a.id, { ...a, rx: prev?.rx ?? a.x, ry: prev?.ry ?? a.y })
  }
  for (const id of [...state.agents.keys()]) if (!seen.has(id)) state.agents.delete(id)
  logEvent({ kind: 'snapshot', agent: '-', tick: s.tick })
}

function applyDiff(d: Diff) {
  state.tick = d.tick
  state.clock = d.clock
  state.gameDay = d.gameDay
  state.speed = d.speed
  for (const a of d.upd ?? []) {
    const prev = state.agents.get(a.id)
    state.agents.set(a.id, { ...a, rx: prev?.rx ?? a.x, ry: prev?.ry ?? a.y })
  }
  for (const e of d.events ?? []) logEvent(e)
}

function logEvent(e: WorldEvent) {
  state.events.unshift(e)
  if (state.events.length > 12) state.events.pop()
  const verb = e.kind === 'arrive' ? '抵达' : e.kind === 'depart' ? '前往' : e.kind
  $('log').innerHTML = state.events
    .map((x) => {
      if (x.kind === 'snapshot') return `<li>#${x.tick} 收到全量快照</li>`
      return `<li>#${x.tick} <b>${x.name ?? x.agent}</b> ${verb} ${x.poi ?? ''}</li>`
    })
    .join('')
}

// ────────────────────────────── 渲染 ──────────────────────────────

function draw(now: number, dt: number) {
  const scale = canvas.width / state.gridW
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // 地砖
  ctx.fillStyle = '#0b1020'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.strokeStyle = 'rgba(48,54,61,0.55)'
  ctx.lineWidth = 1
  ctx.beginPath()
  for (let i = 0; i <= state.gridW; i++) {
    ctx.moveTo(i * scale, 0)
    ctx.lineTo(i * scale, canvas.height)
    ctx.moveTo(0, i * scale)
    ctx.lineTo(canvas.width, i * scale)
  }
  ctx.stroke()

  // 地点
  for (const p of state.pois) {
    const x = p.x * scale
    const y = p.y * scale
    const w = p.w * scale
    const h = p.h * scale
    ctx.fillStyle = p.kind === 'home' ? 'rgba(79,156,249,0.16)' : p.kind === 'work' ? 'rgba(249,163,79,0.14)' : 'rgba(63,185,80,0.14)'
    ctx.strokeStyle = p.kind === 'home' ? 'rgba(79,156,249,0.55)' : p.kind === 'work' ? 'rgba(249,163,79,0.5)' : 'rgba(63,185,80,0.5)'
    ctx.lineWidth = 1.5
    roundRect(x, y, w, h, 6)
    ctx.fill()
    ctx.stroke()
    ctx.fillStyle = 'rgba(230,237,243,0.72)'
    ctx.font = '12px sans-serif'
    ctx.textBaseline = 'top'
    ctx.fillText(p.name, x + 6, y + 5)
  }

  // 居民
  const alpha = Math.min(1, dt * 10)
  for (const a of state.agents.values()) {
    a.rx += (a.x - a.rx) * alpha
    a.ry += (a.y - a.ry) * alpha
    const cx = (a.rx + 0.5) * scale
    const cy = (a.ry + 0.5) * scale
    const r = Math.max(5, scale * 0.45)

    ctx.beginPath()
    ctx.arc(cx, cy, r * 2.1, 0, Math.PI * 2)
    ctx.fillStyle = hexA(a.color, 0.16)
    ctx.fill()

    ctx.beginPath()
    ctx.arc(cx, cy, r, 0, Math.PI * 2)
    ctx.fillStyle = a.color
    ctx.fill()
    ctx.lineWidth = 1.5
    ctx.strokeStyle = a.state === 'move' ? '#ffffff' : 'rgba(255,255,255,0.35)'
    ctx.stroke()

    // 朝向
    const d: Record<string, [number, number]> = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] }
    const [dx, dy] = d[a.facing] ?? [0, 1]
    ctx.beginPath()
    ctx.arc(cx + dx * r * 0.55, cy + dy * r * 0.55, r * 0.26, 0, Math.PI * 2)
    ctx.fillStyle = '#0d1117'
    ctx.fill()

    ctx.fillStyle = '#e6edf3'
    ctx.font = '11px sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText(a.name, cx, cy - r - 14)
    ctx.textAlign = 'left'
  }

  // HUD
  $('tick').textContent = String(state.tick)
  $('clock').textContent = state.clock
  $('day').textContent = String(state.gameDay)
  $('agents').textContent = String(state.agents.size)
  $('age').textContent = state.lastFrameAt ? `${((now - state.lastFrameAt) / 1000).toFixed(1)}s` : '–'
}

function roundRect(x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.quadraticCurveTo(x + w, y, x + w, y + r)
  ctx.lineTo(x + w, y + h - r)
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
  ctx.lineTo(x + r, y + h)
  ctx.quadraticCurveTo(x, y + h, x, y + h - r)
  ctx.lineTo(x, y + r)
  ctx.quadraticCurveTo(x, y, x + r, y)
  ctx.closePath()
}

function hexA(hex: string, a: number): string {
  const n = parseInt(hex.replace('#', ''), 16)
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`
}

let last = performance.now()
function frame(now: number) {
  const dt = Math.min(0.1, (now - last) / 1000)
  last = now
  draw(now, dt)
  requestAnimationFrame(frame)
}

// ────────────────────────────── 启动 ──────────────────────────────

const READY_TIMEOUT = window.setTimeout(() => {
  if (state.conn !== 'open') setStatus('limited', '还没连上引擎？')
}, 6000)

canvas.addEventListener('click', () => {
  // 手动 resync（调试用）：让服务端重发全量快照
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: 'snapshot' }))
})
window.addEventListener('beforeunload', () => {
  manualClose = true
  window.clearTimeout(READY_TIMEOUT)
  ws?.close()
})

keepAlive()
connect()
requestAnimationFrame(frame)

// 调试钩子：浏览器控制台 / 自动化验收用（不含任何密钥）
;(window as unknown as { __aitown: unknown }).__aitown = { state, wsURL, wsReady: () => ws?.readyState ?? -1 }
