# AI Town 线协议 v1（M1）

引擎 ↔ edge ↔ 前端之间的**唯一契约**。改动这里等于改动三方，必须同步改
`engine/internal/world`、`edge/src/index.ts`、`frontend/src/main.ts`。

设计约束（来自 `docs/ARCHITECTURE.md` 四条红线）：

- **只有 WebSocket 推**，没有任何「前端定时拉」的接口 —— WS 消息经 Worker 转发不计请求数；
  1 秒轮询 = 86,400 请求/天/观众，两个观众就烧光免费档。
- **帧要小**：M1 实测平均 ~1.0KB、最大 ~1.8KB/帧（30 帧/30 秒、8 居民、64×64 网格）。
- **只发差分**：世界没变化的拍子不发帧（空拍零字节）；新观众连上先发一次全量 `snapshot`。

## 连接

```
浏览器 ──WS──> edge Worker（哑管道，附加 X-Edge-Token） ──WS──> 引擎 127.0.0.1:8080/ws
```

- 引擎直连时鉴权：`?token=<AITOWN_EDGE_TOKEN>` 或 HTTP 头 `X-Edge-Token`。
  token 只存在于 **引擎 ↔ edge** 之间，**绝不进浏览器**。
- 未带 token 直连引擎 → 握手被拒（`rejectedClients` 计数 +1，无任何数据帧）。
- 扇出上限 `AITOWN_MAX_VIEWERS`（默认 50）；超限拒绝，慢客户端直接踢（`droppedClients`）。

## 服务端 → 客户端

### `hello`（连接建立后第一帧）

```json
{ "t": "hello", "protocol": 1, "server": "aitown-engine", "maxViewers": 50 }
```

### `snapshot`（全量，连上即发；客户端也可随时请求）

```json
{
  "t": "snapshot", "v": 1, "tick": 983, "gameDay": 0, "minuteOfDay": 196,
  "clock": "03:16", "speed": 1, "gridW": 64, "gridH": 64,
  "pois": [{ "id": "home", "name": "住处", "x": 4, "y": 4, "w": 8, "h": 6, "kind": "home" }],
  "agents": [{
    "id": "a01", "name": "阿明", "persona": "…", "color": "#4f9cf9",
    "homeX": 8, "homeY": 7, "x": 22, "y": 36, "facing": "down",
    "state": "move", "target": "market"
  }]
}
```

### `diff`（每拍，仅当有变化）

```json
{
  "t": "diff", "tick": 984, "gameDay": 0, "minuteOfDay": 196, "clock": "03:16", "speed": 1,
  "upd":    [{ "id": "a01", "name": "阿明", "x": 23, "y": 36, "facing": "right", "state": "move", "target": "market" }],
  "events": [{ "kind": "arrive", "agent": "a03", "poi": "cafe", "tick": 984 }]
}
```

- `upd` = 本拍位置/状态有变化的居民（整条 AgentView，含未变字段，保证幂等）。
- `events` = 世界事件（M1 只有 `arrive` / `depart`；M2 起会有 `say` / `chat`）。

### `pong`

```json
{ "t": "pong", "ts": 1760000000000 }
```

### `error`

```json
{ "t": "error", "code": "not_implemented", "msg": "M4 才支持观众介入" }
```

## 客户端 → 服务端

| 帧 | 作用 |
|---|---|
| `{"t":"ping"}` | 保活 / 探活，服务端回 `pong` |
| `{"t":"snapshot"}` | 强制重发全量快照（前端重连后自愈用） |
| `{"t":"interject", …}` | **M4** 才支持；M1 回 `error/not_implemented` |

## 游戏时钟

`1 tick = 1 拍（默认 1 秒真实时间）`；游戏日长度由 `AITOWN_GAME_DAY_SECONDS`（默认 7200s）决定：

```
minutePerTick = 1440 / (GAME_DAY_SECONDS / TICK_SECONDS)
minuteOfDay   = (tick * minutePerTick) mod 1440
gameDay       = tick / (GAME_DAY_SECONDS / TICK_SECONDS)
```

默认 7200s/游戏日 → 约 12 个游戏日/真实天。`clock` 是 `HH:MM` 字符串，前端直接显示。

## 验收脚本

```bash
node scripts/m1-verify.mjs 'ws://127.0.0.1:8080/ws?token=<TOKEN>' 30
```

断言：收到快照、居民数 = 8、差分帧 ≥ 一半秒数、**8/8 个居民在窗口内都动过**、
世界事件 ≥ 1、零协议错误。退出码 0 = 通过。
