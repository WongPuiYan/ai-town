#!/usr/bin/env node
/**
 * M1 验收脚本（可重复跑）：连上引擎的 WebSocket，断言「8 个点真的在动」。
 *
 *   node scripts/m1-verify.mjs [ws-url] [seconds]
 *   默认 ws://127.0.0.1:8080/ws?token=$AITOWN_EDGE_TOKEN（没有 token 时直接连）
 *
 * 退出码：0 = 通过；1 = 断言失败（会打印失败原因）
 */
const url = process.argv[2] ?? 'ws://127.0.0.1:8080/ws' + (process.env.AITOWN_EDGE_TOKEN ? `?token=${process.env.AITOWN_EDGE_TOKEN}` : '')
const seconds = Number(process.argv[3] ?? 30)
const EXPECT_AGENTS = Number(process.env.EXPECT_AGENTS ?? 8)

let frames = 0, snapshots = 0, diffs = 0, pongs = 0, worldEvents = 0, errors = 0
const firstSeen = new Map()   // id -> [x,y]（首次快照）
const lastSeen = new Map()    // id -> [x,y]（最后一帧）
const moved = new Set()
const bytes = { max: 0, sum: 0 }
let snapshotAgents = 0, tick = -1, clock = '-'

const ws = new WebSocket(url)
ws.onopen = () => ws.send(JSON.stringify({ t: 'ping' }))
ws.onerror = (e) => { errors++; console.log(`[ERR] 连接错误: ${e?.message ?? ''}`) }
ws.onclose = (e) => { if (e?.code && e.code !== 1000) console.log(`[ERR] 连接关闭 code=${e.code} reason=${e.reason}`) }

ws.onmessage = (ev) => {
  frames++
  const n = typeof ev.data === 'string' ? ev.data.length : (ev.data?.byteLength ?? 0)
  bytes.sum += n; bytes.max = Math.max(bytes.max, n)
  let m
  try { m = JSON.parse(ev.data) } catch { errors++; console.log('[ERR] 非法 JSON 帧'); return }

  if (m.t === 'hello') console.log(`[OK ] hello: protocol=${m.protocol} server=${m.server} maxViewers=${m.maxViewers}`)
  else if (m.t === 'snapshot') {
    snapshots++; snapshotAgents = m.agents?.length ?? 0; tick = m.tick
    for (const a of m.agents ?? []) { firstSeen.set(a.id, [a.x, a.y]); lastSeen.set(a.id, [a.x, a.y]) }
    console.log(`[OK ] 全量快照: ${snapshotAgents} 个居民, ${m.pois?.length ?? 0} 个地点, 网格 ${m.gridW}x${m.gridH}, 第 ${m.gameDay} 天 ${m.clock}`)
  } else if (m.t === 'diff') {
    diffs++; tick = m.tick; clock = m.clock
    for (const a of m.upd ?? []) {
      const p = lastSeen.get(a.id)
      if (p && (p[0] !== a.x || p[1] !== a.y)) moved.add(a.id)
      lastSeen.set(a.id, [a.x, a.y])
    }
    for (const e of m.events ?? []) worldEvents++
  } else if (m.t === 'pong') pongs++
  else if (m.t === 'error') { errors++; console.log(`[ERR] 服务端错误: ${m.code} ${m.msg}`) }
}

await new Promise((r) => setTimeout(r, seconds * 1000))
try { ws.close() } catch {}

const report = {
  url, seconds, frames, snapshots, diffs, pongs, worldEvents, snapshotAgents,
  distinctIds: lastSeen.size, movedAgents: moved.size, tick, clock, errors,
  frameBytes: { avg: Math.round(bytes.sum / Math.max(frames, 1)), max: bytes.max },
}
console.log(JSON.stringify(report, null, 2))

// 居民抵达目的地后会停留 8~30 拍，所以短窗口里「有 1 个在休息」是正常现象：
// 「8/8 全动过」只在 ≥30 秒的窗口里作为硬断言；短窗口只要求按比例动起来。
const fullCoverage = seconds >= 30
const minMoved = fullCoverage ? EXPECT_AGENTS : Math.max(3, Math.ceil((EXPECT_AGENTS * seconds) / 30))

const fails = []
if (errors > 0) fails.push(`连接/协议错误 ${errors} 次`)
if (snapshots < 1) fails.push('没收到全量快照')
if (snapshotAgents !== EXPECT_AGENTS) fails.push(`快照居民数 ${snapshotAgents} ≠ ${EXPECT_AGENTS}`)
if (diffs < Math.floor(seconds * 0.5)) fails.push(`差分帧太少（${diffs}），世界可能没推进`)
if (moved.size < minMoved) fails.push(`只有 ${moved.size}/${EXPECT_AGENTS} 个居民动过（要求 ≥${minMoved}）`)
if (seconds >= 10 && worldEvents < 1) fails.push('没有任何世界事件（arrive/depart）')

if (fails.length) { console.log('\n❌ M1 验收失败:\n- ' + fails.join('\n- ')); process.exit(1) }
console.log(`\n✅ M1 验收通过：${moved.size}/${EXPECT_AGENTS} 个居民动过，${diffs} 帧差分，最大帧 ${bytes.max} 字节`)
if (!fullCoverage) console.log(`ℹ️  窗口只有 ${seconds}s（<30s），只断言了 ≥${minMoved} 人在动；要验收「8/8 全动过」请跑 ≥30 秒`)
process.exit(0)
