# AI Town — 项目汇总（重整版）

> 2026-10-10 整理。把之前散落在 README / ARCHITECTURE / 多次对话里的结论合并成一份可直接读的版本。
> **以本文为准**：`ARCHITECTURE.md` 的 §5.2 / §3.2 与部分图表仍是 v1.0 措辞（已在文末列出），本文是 v1.1 后的最终状态。

---

## 1. 一句话定位

一个自建的 2D 像素小镇，**8 个 AI 居民**实时过日子：有性格、有日程、有长期记忆、彼此有关系值。
观众能看他们走动/相遇/聊天，能点开看某人的日程与想法，能给他递一句话影响他下一步。

> 关键差别：**不是聊天机器人合集**。你不说话的时候，小镇照常运转。

**不复用 a16z ai-town 代码**（原版要自托管 Convex，吃 1GB+ 内存，这台 2GB 机器扛不住）。
**部署形态**：Cloudflare（前端 + 边缘网关）+ 自建云主机（模拟引擎）+ DeepSeek（大脑）。

---

## 2. 硬约束（架构是这些约束推出来的）

| # | 约束 | 实测值 | 推论 |
|---|---|---|---|
| A | 服务器 | 2 核 / 2GB，**扣掉常驻服务后可用约 1GB**，无 Docker | 引擎必须单二进制、内存 < 200MB |
| B | 同机负载 | 若干常驻服务（网关 / 媒体服务 / CI Runner） | 引擎内存预算压到 **120MB** |
| C | Cloudflare 只用免费档 | Free 计划 | 见下方四条红线 |
| D | LLM 必须外调 | 本机跑不动模型 | DeepSeek API + Workers AI |
| E | 出口网络 | 公网可达 CF/DeepSeek，**内网 ikas 代理不可达** | 只能走公网 API |

### Cloudflare 免费档的四条硬红线（违反任一条，免费档就破）

1. 🩸 **前端只走 WebSocket，禁止轮询** — WS 消息经 Worker 转发**不计**请求数；1 秒轮询 = 86,400 请求/天/观众，**两个观众就把当天 10 万额度烧光**。这不是优化，是生死线。
2. **Worker 保持哑管道** — 免费档 **10ms CPU/次**（付费 5 分钟），只准转发 + 鉴权 + 限流，禁止任何业务计算。
3. **tick 级热写全落 SQLite** — D1 免费 **10 万行写/天**，1 秒/拍就是 86,400 行，只在「游戏日」边界批量同步快照。
4. **不引入 Vectorize** — 全镇向量只有几千条，Go 本地暴力余弦 2–4ms 就够，还省掉一个文档矛盾依赖。

> **Workers KV 也不碰**（免费 1,000 写/天，一天要写 86,400 次）——只读配置可以，实时状态物理上不接 KV。

---

## 3. 分层架构

```
观众浏览器  →  Cloudflare Pages   Vite + TypeScript + PixiJS
                · 首屏 REST 取快照；实时 WebSocket 收差分帧
              ↓ HTTPS / WSS
            Cloudflare Workers   edge 网关（唯一公网入口，密钥只在这层）
                /api/state    世界快照（代理到隧道）
                /api/embed    代理 Workers AI bge-m3（不暴露 CF key）
                /api/history  直读 D1（历史事件，不消耗服务器）
                /ws           WebSocket 透传到引擎
              ↓ cloudflared 出站隧道（服务器不开任何公网端口）
            云主机 2C2G  systemd
              aitown-engine（Go 单二进制，目标 RSS ≈ 120MB）
                ① Tick Scheduler  1s/拍，暂停 / 1x / 4x / 回放
                ② World State     内存网格 + 实体表（零拷贝读）
                ③ Agent Runtime   状态机 idle→plan→move→talk→reflect
                ④ LLM Gateway     并发闸门 4 + 退避重试 + 预算熔断
                ⑤ Memory Store    SQLite(WAL) 事件流 + 向量缓存
                ⑥ Broadcaster     WebSocket 差分帧广播
              aitown.db（SQLite WAL — 引擎的唯一真相源）
              ↓ 异步：对话 → DeepSeek API ｜ embedding → Workers AI bge-m3
              ↓ 异步：冷数据 → D1 影子库 ｜ 素材 → R2
```

> ⚠️ `ARCHITECTURE.md` §2 图里的 `/api/memory` 与「Vectorize 语义检索」是 v1.0 残留，**v1.1 已不需要**。

---

## 4. 关键决策（含 v1.0 → v1.1 的修正）

| 决策 | 结论 | 理由 |
|---|---|---|
| tick 引擎放哪 | **自己服务器** | Worker 免费档 10ms CPU，游戏循环轻松超 50ms，放 Worker 第一天就撞墙 |
| 实时层 | **隧道直连，不用 Durable Objects** | 引擎本来就必须跑服务器，再套 DO = 状态拆两处。**不是用不起，是不需要**（Hibernation API 休眠期不计 duration，v1.0 的「吃 85% 额度」是夸大，已更正） |
| 主库 | **SQLite 主 / D1 影子** | 热写与冷查询分开；D1 只在游戏日边界同步（约 12 次/天） |
| embedding | **Workers AI bge-m3** | 10,000 neurons/天 ≈ 930 万 token/天，8 人小镇实耗 **<1%**；LLM 放 CF 则几分钟打爆 |
| 对话 | **DeepSeek** | OpenAI 兼容、中文/粤语好、便宜 |
| 引擎语言 | **Go** | 常驻 ≈120MB（Node 250MB+）、单静态二进制、goroutine 天然适合 tick + 并发 LLM；顺带是能写进 Web3 简历的系统设计作品 |
| 向量检索 | **Go 本地暴力余弦**（v1.1 改） | 4,000 条 × 1024 维 = 16MB 内存，全量点积 2–4ms；Vectorize 的价值从百万级向量才开始，差 3 个数量级 |
| 时钟模型 | **tick**（1 拍 = 1 游戏分钟） | 换来加速/暂停/回放、可复现（同 seed + 同 tick 序列 = 同一段历史）、可观测快照 |

### 4.1 一拍做什么

```
1. world.clock++           推进游戏时钟
2. runtime.stepMovement()  A* 寻路，每拍走一格
3. runtime.scanInteractions()  同格/相邻 → 触发相遇
4. runtime.dispatchDueAgents() 到点的 Agent 唤醒（日程驱动）
5. memory.flushDirty()     每 10 拍批量落库（减少 fsync）
6. broadcaster.emitDiff()  差分帧广播（没变化不发字节）
```

### 4.2 Agent 决策四层 —— 省 token 的命门

**绝对不要每拍都问 LLM。** 分四层，频率差 3 个数量级：

| 层 | 频率 | 谁做 | 成本 |
|---|---|---|---|
| 反射层 | 每拍 | 纯规则/状态机（走路、让路、回家） | **0** |
| 计划层 | 每游戏日 1 次 | LLM 生成当天日程 JSON | ~800 token |
| 对话层 | 相遇时 | LLM 生成台词 | ~400 token/段 |
| 反思层 | 每游戏日 1 次 | LLM 压缩当天事件 + 更新关系 | ~1000 token |

**≈ 3 万 token / 游戏日**（8 人 ×(800+5×400+1000)）→ 一个游戏日成本**厘级**。这就是分层带来的 1000 倍差距。

### 4.3 记忆三层（对标 Stanford Generative Agents）

| 层 | 内容 | 存哪 | 向量化 |
|---|---|---|---|
| Observation | 原始事件「10:03 在咖啡馆遇到阿明」 | SQLite `vec` BLOB | ✅ 最近 200 条/人 |
| Reflection | 高层结论「我最近和阿明走得近」 | SQLite `vec` BLOB | ✅ 上限 300 条/人 |
| Plan | 当日日程 | SQLite 纯文本 | ❌ 不值得 |

检索打分（三因子加权）：`w1·余弦相似度 + w2·时间衰减 exp(-Δt/半衰期) + w3·重要度(LLM 自评 1-10)`，取 top-K=8 拼进 prompt。

**设计要点：向量是「检索索引」，不是「真相源」。** 真相源永远是 SQLite；淘汰向量不影响数据完整性。

### 4.4 永不卡死（LLM 是增强，不是依赖）

```
tick 线程 ──publish──► taskQueue(buffered chan, cap 256) ──► 4 个 worker goroutine
            不阻塞 tick        队列满 → 丢最低优先级              调 LLM 数秒 → 回灌 tick
```

三级降级：**LLM 超时/报错** → 换模板台词池；**单日 token 超预算** → 关对话层只留计划层；**队列积压 > 80%** → 丢反思层任务。
**LLM 全挂了，小镇退化成规则 NPC，但绝不黑屏。**

---

## 5. 额度与成本（唯一真实支出：DeepSeek）

逐项核算过一遍，全部有官方文档出处（见 `ARCHITECTURE.md` 附录 A）：

| 服务 | 免费额度 | 本项目预估 | 余量 |
|---|---|---|---|
| Pages 请求/带宽 | 无上限 | — | ✅ |
| Pages 构建 | 500/月 | ~30 | ✅ |
| **Workers 请求** | **100,000/天** | WS 握手级 ~几百/天 | 99%+（前提：禁止轮询） |
| Workers CPU | 10ms/次 | 纯转发 1–3ms | ⚠️ 别加逻辑 |
| Workers AI | 10,000 neurons/天 | 实耗 <1% | ✅ |
| D1 读 / 写 | 5M 行/天 / **100k 行/天** | 仅游戏日边界同步 | ✅ |
| R2 | 10GB / 1M A类 / 10M B类 | ~200MB 素材 | ✅ |
| ~~Vectorize~~ | — | **不使用**（v1.1） | ✅ 硬墙消失 |
| KV 写入 | 1,000/天 | **0（不使用）** | ⚠️ 主动规避 |
| Durable Objects | 13,000 GB-s/天 | **不使用** | ✅ |
| Tunnel | 免费 | 1 条 | ✅ |
| 服务器 | 已持有 | +120MB RSS | ⚠️ 监控 |

**DeepSeek 月度推算**（30k token/游戏日 × 12 游戏日/天 × 30 天 = 7.2M 输入 + 3.6M 输出）：

```
忙时 $0.30/M 入 + $1.20/M 出  →  $6.48/月
闲时 $0.15/M 入 + $0.60/M 出  →  $3.24/月
```

**→ 约 $3–6.5/月（¥22–47），全项目唯一支出。** 模型用 `deepseek-v4-flash`
（`deepseek-chat` 已于 **2026-07-24 弃用**，脚本里必须写 v4-flash）。
降本空间：上下文缓存对固定前缀（人设+规则+小镇背景）生效，**缓存命中价比未命中便宜 50 倍**，把不变内容放 prompt 前部。

---

## 6. 数据模型

**SQLite 主库**：`world` `agents` `positions`（热表，10 拍 flush）`plans` `events` `memories`(vec BLOB) `relations` `conversations` `token_usage`
索引：`events(tick)`、`memories(agent_id, kind, created_tick)`、`relations(agent_id)`

**D1 影子库**：只同步 3 张表，只在游戏日边界 —— `agents`（居民列表）`events`（时间线）`conversations`（回看聊天）。
不同步 `positions` / `memories`（热数据 + 体积大）。

---

## 7. 网络暴露

引擎**只绑 `127.0.0.1:8080`**，不开任何公网端口，唯一入口是一条 cloudflared 出站隧道。

| 模式 | 条件 | 特点 |
|---|---|---|
| A. Named tunnel + DNS | 有域名托管在 CF | URL 固定，Worker 环境变量配死，最省事 |
| B. Quick tunnel | 无域名 | URL 每次重启变，需 monitor 自动同步 |

> ⚠️ **已知坑**：named tunnel **没有 DNS 路由时无法外部访问**（`cfargotunnel.com` 需要 CNAME）。
> **建议给 ai-town 单独建一条 tunnel**，不要和同机其它项目共用 ingress（避免一个挂两个都挂）。

---

## 8. 里程碑与当前进度

| 阶段 | 交付 | 验收标准 | 状态 |
|---|---|---|---|
| **M0** | 架构文档 + 部署脚本 | — | ✅ **已完成** |
| **M1** | 引擎 tick + WS 广播 + 前端画出 8 个点 | 浏览器里看到 8 个点在动，断线重连正常 | ✅ **代码完成**（2026-10-10；协议级验收通过，浏览器渲染待人工确认） |
| **M2** | 接 DeepSeek：日程 + 相遇对话 + 气泡 | 有作息规律，见面会说话 | ⬜ |
| **M3** | 记忆系统：本地向量检索 + 每日反思 | 能引用昨天的事，关系值有变化 | ⬜ |
| **M4** | 观众介入：给 Agent 递消息 | 消息影响该 Agent 下一步行为 | ⬜ |
| **M5** | 变速/暂停/回放 + 成本看板 | 额度用尽不中断，成本可视化 | ⬜ |

**M1 是分水岭**，建议 M1 **严格不接 LLM** —— 先把「心跳」和「血管」验证通。

### ✅ M1 代码已落地（2026-10-10，协议级验收通过）

| 交付 | 文件 | 说明 |
|---|---|---|
| 引擎（心跳 + 血管） | `engine/cmd/aitown/main.go` | tick 循环、`/health`、`/api/state`、`/ws`；`GOTOOLCHAIN=local` + Go 1.23 构建通过 |
| 世界 | `engine/internal/world/world.go` | 64×64 网格、7 个地点、8 个居民；BFS 寻路 + 停留；游戏时钟（默认 7200s/游戏日） |
| 广播 | `engine/internal/broadcast/hub.go` | WS 差分帧、只发变化、慢客户端直接踢、扇出上限 50 |
| 主库 | `engine/internal/store/store.go` | SQLite（`modernc.org/sqlite`，纯 Go，`CGO_ENABLED=0` 可编译）、每 10 拍 flush |
| 边缘 | `edge/src/index.ts` + `edge/wrangler.toml`（codegen） | 哑管道：WS 直通 + REST 转发；`X-Edge-Token` 只存在于引擎↔edge |
| 前端 | `frontend/`（Vite + TS + Canvas 2D） | 只走 WebSocket（零轮询）、指数退避重连、插值平滑 |
| 协议 | `docs/PROTOCOL.md` | 线协议 v1：`hello`/`snapshot`/`diff`/`pong`/`error` |
| 验收 | `scripts/m1-verify.mjs` | 可重复跑的断言脚本（退出码 0 = 通过） |

**实测证据**（本机，未碰任何云资源）：

```
node scripts/m1-verify.mjs ws://127.0.0.1:8787/ws 30     # 经「伪 edge」代理（附加 token）
✅ 8/8 个居民在 30s 内都动过 · 30 帧差分 · 平均 1003B/帧 · 最大 1845B · 0 协议错误
直连引擎不带 token → 握手被拒（0 帧）                    # 鉴权生效
SQLite 回读：3 表 3 索引 + world 1 行 + positions 8 行 + events 245 行
```

> 已知未验证项：**真浏览器里的渲染与断线重连**（本机 Chrome 无法启动，见 README 说明），
> 以及 `03/05/02/04` 的真部署链路（需要 sudo / 隧道 URL）。
>
> 刻意偏离架构文档的一处：M1 前端用 **Canvas 2D** 而不是 PixiJS。理由：8 个点不需要渲染引擎，
> 少一层依赖就少一个失败面；等到 M2 上瓦片/精灵图/气泡时再换（渲染代码已隔离在 `draw()` 里）。

### 磁盘现状（M1 产出）

```
~/ai-town/                          ⚠️ 还不是 git 仓库（未 git init）
├── README.md
├── docs/ARCHITECTURE.md            v1.0 + v1.1 修订章
├── docs/SUMMARY.md                 ← 本文件
├── docs/PROTOCOL.md                ← 线协议 v1（M1 新增）
├── deploy/lib.sh · 00-preflight · 01-cf-resources · 02-edge-deploy
│        03-engine-install · 04-frontend-deploy · 05-tunnel-setup · quota-check
├── engine/                          ← Go 引擎（cmd/aitown + internal/{world,broadcast,store}）
├── edge/src/index.ts + wrangler.toml ← Worker 哑管道
├── frontend/{index.html,src/main.ts,vite.config.ts}
├── scripts/m1-verify.mjs            ← 验收脚本
├── bin/aitown · data/aitown.db · logs/   ← 运行时产物（git 忽略）
└── .github/workflows/deploy.yml     self-hosted runner（不用 SSH，避免云厂商异常登录告警）
```

脚本行为约定：能做的都做，遇到还没写的业务代码**明确提示并跳过，不假装成功**。

### ✅ CF 资源已创建（2026-10-10 跑完 `01-cf-resources.sh`，已回读验证）

```bash
./deploy/01-cf-resources.sh     # exit 0，幂等可重跑
```

| 资源 | 结果 | 回读验证 |
|---|---|---|
| **D1** `aitown-shadow` | ✅ 建库 | UUID 见 `deploy/.state.env`（`D1_ID`），`sqlite_master` 回读 **3 表 3 索引**（`agents` / `events` / `conversations` + 3 个 idx） |
| **KV** `aitown-config` | ✅ 建命名空间 | ID 见 `deploy/.state.env`（同账号另有一条 `NOVEL_READER`，别混用） |
| **Vectorize** | ⬜ 按 v1.1 决策跳过 | `VECTOR_BACKEND=local`、`EMBED_DIMS=1024` |
| **R2** `aitown-assets` | 🟢 跳过 | `code=10042 Please enable R2` —— 账号未开通 R2 服务 |

`deploy/.state.env` 已生成：`VECTOR_BACKEND=local` / `EMBED_DIMS=1024` / `D1_DATABASE_ID` / `KV_NAMESPACE_ID`（git 忽略）。

> ⚠️ 首次跑时 **D1 建表 15 条全失败**（`01-cf-resources.sh` 按「行」而不是按「分号」切 SQL，多行 `CREATE TABLE` 被拆散）→ **库建出来了但是空库**。已修，复验 6 条 DDL 全 OK。详见 README 的 bug 清单第 3 条。

### ✅ CF Token 权限已就绪（2026-10-10 用户补齐后实测）

`./deploy/00-preflight.sh` → **「全部检查通过，可以执行 01-cf-resources.sh」**（exit 0）。

| 权限 | 用途 | 状态 |
|---|---|---|
| Account → **D1** → Edit | 影子库（`01-cf-resources.sh` 建库） | ✅ 本次补上 |
| Account → **Workers AI** → Edit | embedding（70 个模型可见） | ✅ 本次补上 |
| Account → Workers Scripts / Pages / Workers KV / Cloudflare Tunnel → Edit | edge / 前端 / 配置 / 隧道 | ✅ 本来就有 |
| Account → Account Analytics → Read | quota-check 看额度 | ✅ 本来就有 |
| Account → R2 → Edit | 素材存储（**首版不用**） | 🟢 未开通，不阻塞；要用得先走 Dashboard checkout 开通 R2 服务（code=10042） |
| Account → Vectorize → Edit | ~~记忆检索~~ | ⬜ v1.1 已不需要 |

> 之前文档写「缺 5 项」是**探针 bug 造成的误报**（2026-10-10 已修）：
> `00-preflight.sh` 用 `grep '"success":true'` 判断，但 CF 返回带空格的 pretty JSON，
> 永远匹配不上 → Pages / Workers Scripts 被误判为缺权限，其实早就有；
> 另把 R2 归入 optional，使预检结论与「首版不用 R2」一致。
> `quota-check.sh` 另因给 `readonly` 变量 `EMBED_DIMS` 重复赋值而崩在第 16 行（从未跑通），也已修。

> ⚠️ **账号下 0 个域名** → `05-tunnel-setup.sh` 会落到 **quick tunnel 模式**（URL 每次重启变，需自动同步进 Worker）；
> 要 named tunnel 得先在 CF 添加域名。本机既有的 cloudflared 配置**不属于本账号**（服务同机另一项目），
> 所以 05 脚本必须 `--config` 指向空配置，否则默认 ingress 会把 quick tunnel 也转发过去。

### ✅ M1 已上线 Cloudflare（2026-10-10）

| 环节 | 地址 / 位置 | 备注 |
|---|---|---|
| **页面（Pages）** | **https://ai-town-cbn.pages.dev** | 用户用浏览器打开这个；构建时把 Worker 地址烧进包 |
| Worker（哑管道） | `https://aitown-edge.dcneowong.workers.dev` | WS 直通 + REST 转发，`env.ENGINE_ORIGIN` 指隧道 |
| 引擎 | systemd `aitown-engine` @ `127.0.0.1:8080` | 口令在 `engine.env` 的 `AITOWN_EDGE_TOKEN`（600） |
| 公网入口 | cloudflared quick tunnel（`cloudflared-aitown`） | URL 漂移 → 自动改 `wrangler.toml` → 自动重部署 Worker |

**公开路径验收**：`node scripts/m1-verify.mjs wss://aitown-edge.dcneowong.workers.dev/ws 30`
→ 8/8 居民在动、30 帧差分、最大帧 1853B、0 协议错误；页面 `HTTP 200` + 标题 `AI Town — M1 心跳`。
**浏览器渲染 / 断线重连**由用户目视确认。

### 🐛 部署这一轮踩的坑（都已修，见脚本内注释）

| # | 症状 | 根因 → 修法 |
|---|---|---|
| 8 | 引擎永远 401 | `02` 每次 `openssl rand` 生成 `EDGE_SHARED_TOKEN`，与引擎 `AITOWN_EDGE_TOKEN` 永不相等 → 单一真相源：`ensure_edge_token()` 从 `engine.env` 取同一个值 |
| 9 | `03` 跑出 `deepseek-chat: command not found` | 未加引号的 heredoc 里，注释中的反引号被当命令执行 → 去掉反引号 |
| 10 | `curl` 带 token 反而 400 | 口令被写了两行（值相同），`$(grep)` 取到多行 → header 畸形；修：先 `ensure_edge_token` 再判断补写 |
| 11 | quick tunnel URL 通了，返回的却是同机另一服务的页面 | **cloudflared 默认读 `~/.cloudflared/config.yml`**，里面的 ingress 覆盖 `--url` → 显式 `--config deploy/cloudflared-aitown-empty.yml` |
| 12 | Worker `/api/*` 全 404，日志 `No bindings found.` | 仓库根还有个 `wrangler.jsonc`（assets→frontend），wrangler 向上搜到它 → 以静态资源模式部署同名 Worker，覆盖带 bindings 的版本；修：`--config edge/wrangler.toml` + 根配置挪去 `deploy/attic/` |
| 13 | 隧道重启后页面永远「重连中」 | 生成脚本里 `\$HOME`/`\${HOME}` 过度转义（带引号 heredoc 中 `\$` 是字面量）→ CF 凭据没加载、npx 兜底失效、Worker 部署静默失败；修：写成运行时原样 + 输出重定向到 `deploy/worker-redeploy.log` |
| 14 | 同上（部署失败） | systemd 的 PATH 里没有 nvm 的 node/npx → unit 加 `Environment=PATH=<nvm>/bin:…`，脚本内再兜底扫 `~/.nvm/versions/node/*/bin` |
| 15 | 04 冒烟测试「通过」但页面不是自己的 | 项目名全局唯一，真实域名是 `ai-town-cbn.pages.dev`；`ai-town.pages.dev` 是**别人的**项目 → 只测状态码会 200 假通过；修：逐个候选 + 校验页面标题 |

下一步（M1 已上线）：进 **M2（接 DeepSeek：日程 + 相遇对话 + 气泡）**；
顺带可选项：给 `ai-town` 加域名换掉 quick tunnel、给 runner 加 `aitown-engine` 标签把 CI 打开。
仓库：https://github.com/WongPuiYan/ai-town （public，仅代码与文档，无密钥）

### 🔑 凭据与 CI（本仓库 **public**，代码里不放任何密钥）

**本地**：本机密钥文件（默认 `$HOME/.hermes/.env`，600，可用 `AITOWN_SECRETS_ENV` 覆盖）存
`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` / `DEEPSEEK_API_KEY`；
引擎侧 `engine.env`（600）存 `AITOWN_EDGE_TOKEN`。两类文件都**不进版本库**（见 `.gitignore`）。
`deploy/lib.sh` 不再硬编码账号 ID：读不到就 `die`，宁可失败也不要用错账号去部署。

**GitHub Secrets**（Settings → Secrets and variables → Actions）：

| Secret | 用途 | 本地来源 |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | wrangler 部署 / quota-check | 本机密钥文件 |
| `CLOUDFLARE_ACCOUNT_ID` | 同上 | 本机密钥文件 |
| `DEEPSEEK_API_KEY` | M2 起引擎调 LLM | 本机密钥文件 |
| `PEER_SERVICES`（**变量**，非 secret） | CI 回归验证点名的同机服务名 | 部署机自定 |

**CI 现状（尚未启用）**：`deploy.yml` 的 engine job 要 self-hosted runner 标签 `aitown-engine`，
而部署机上现有的 self-hosted runner 只注册在**别的仓库**（标签不匹配）→ 首次 push 的运行会一直 `queued`。
启用三步：① 给本机 runner 加 `aitown-engine` 标签（或另注册一个）② 配置上表 3 个 Secrets ③（可选）加带审批的 Environment。
远程管理 CI 需要 PAT 具备 `Actions: Read and write` + `Secrets: Read and write`（当前 fine-grained token 无此权限 → 403）。

### 部署顺序（幂等，可重复跑）

```
00-preflight → 01-cf-resources → 03-engine-install → 05-tunnel-setup → 02-edge-deploy → 04-frontend-deploy → quota-check
```
顺序不能乱：**3 要在 5 之前**（隧道要指向活着的引擎），**5 要在 2 之前**（edge 要知道引擎在哪）。

---

## 9. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| 服务器内存被顶爆 | 中 | 高 | `GOMEMLIMIT=150MiB`；systemd `MemoryHigh=400M`/`MemoryMax=600M`；preflight 检查可用内存 |
| Workers CPU 10ms 超限 | 低 | 高 | edge 层只准转发，代码评审卡这一条 |
| 误用 KV 存状态 | 中 | 高 | KV 只读配置，写路径物理上不接 |
| LLM 成本失控 | 中 | 中 | 单日 token 硬预算 + 超限降级；`token_usage` 每日对账 |
| 隧道断连 | 中 | 高 | systemd `Restart=always` + 前端指数退避重连 |
| 同机负载争抢 | 中 | 中 | systemd `CPUWeight` / `MemoryMax` 限制引擎 |
| 记忆不淘汰撑爆 | 中 | 中 | 淘汰策略 M1 就实现（Observation 200/人、Reflection 300/人） |

---

## 10. 文档不一致处（待修）

整理时发现的 v1.0 残留，**本文已按 v1.1 更正**，但那两处原文还没改：

1. `ARCHITECTURE.md` §2 架构图：`/api/memory 代理 Vectorize 语义检索` + 底部署名 `Vectorize（语义检索）` → 已不使用。
2. `ARCHITECTURE.md` §9 里程碑 M3：「Vectorize 检索 + 反思层」→ 应为「本地向量检索 + 反思层」。
3. `ARCHITECTURE.md` §10 风险表：两行 Vectorize 风险（存储写满 / 查询超额）→ 已不适用。
4. `ARCHITECTURE.md` §5.3 兜底方案提到「Vectorize 额度用尽降级 BM25」→ 逻辑仍成立，但触发条件已不存在。

（`README.md` 与脚本已在 v1.1 同步过，无残留。）
