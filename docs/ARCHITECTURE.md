# AI Town 架构设计文档

> 版本 v1.0 ｜ 目标：从零自建（不复用 a16z ai-town 代码）｜ 部署：Cloudflare 免费档 + 自建云主机
>
> **⚠️ v1.1 修订（2026-09-30）**：官方文档逐条核实后修正 3 处 ——
> ① **前端物理上禁止轮询**（轮询 2 个观众就烧光当日额度，生死线）
> ② **移除 Vectorize 依赖**，改 Go 本地暴力向量检索（唯一的免费档硬墙消失）
> ③ 修正 Durable Objects 的额度论断（原文夸大，Hibernation API 不计 duration）
> 详见 §5.4。**§5.2 的结论已被 §5.4 取代，保留作为推理记录。**
> 所有额度数字均来自 2026-09 官方文档实测核实，来源见文末附录。

---

## 0. 产品定义

一个 2D 像素小镇，8 个 AI 居民。每个居民有性格、日程、长期记忆、彼此的关系值。

观众能做的事：
- 看他们实时走动、相遇、聊天（头顶气泡）
- 点开某个居民，看他今天的日程、他和谁聊过、他现在在想什么
- 给某个居民递一句话，影响他接下来的行为

**这不是聊天机器人合集，是一个「会自己过日子」的世界。**差别在于：你不说话的时候，小镇照常运转。

---

## 1. 先讲约束 —— 架构是约束推导出来的，不是拍脑袋

| # | 约束 | 实测值 | 推论 |
|---|---|---|---|
| A | 服务器规格 | 2 核 / 2GB / 可用内存 ~1.1GB / 无 Docker | 引擎必须单二进制、内存 < 200MB |
| B | 同机已有负载 | 常驻网关 + peer-service + GitHub Runner | 引擎内存预算压到 120MB |
| C | Cloudflare 只用免费档 | Free 计划 | 见下方红线 |
| D | LLM 必须外调 | 本机跑不动任何模型 | 走 DeepSeek API + CF Workers AI |
| E | 出口网络 | 公网可达 CF/DeepSeek，内网 ikas 代理不可达 | 公网 API 是唯一选项 |

### Cloudflare 免费档的四条硬红线（决定了架构形状）

| 服务 | 免费额度 | 为什么是红线 |
|---|---|---|
| **Workers CPU** | **10 ms / 次调用**（付费是 5 分钟） | 差 300 倍。**tick 引擎绝对不可能跑在 Worker 里。** |
| **Workers KV 写入** | **1,000 次 / 天** | 一个 1 秒/拍的引擎一天要写 86,400 次。**KV 不能碰实时状态。** |
| **Durable Objects 时长** | 13,000 GB-s / 天 | 1 个常亮 WebSocket DO ≈ 11,000 GB-s/天，**吃掉 85% 额度**。 |
| **Workers AI** | 10,000 neurons / 天 | 额度全给 LLM 的话瞬间打爆；给 embedding 用只用 1%。 |

> 结论一句话：**免费档的 Cloudflare 是「入口 + 代理 + 冷存储」，不是「算力」。算力必须放自己服务器上。**

---

## 2. 分层架构

```
┌───────────────────── 观众浏览器 ──────────────────────┐
│  Cloudflare Pages  (免费：请求/带宽无上限)             │
│  Vite + TypeScript + PixiJS                           │
│  · 渲染：地块 / 精灵 / 气泡 / 日程面板 / 关系图        │
│  · 首屏：REST 取快照   实时：WebSocket 收差分帧        │
└───────────────────────┬───────────────────────────────┘
                        │ HTTPS / WSS
┌───────────────────────▼──── Cloudflare Workers ───────┐
│  edge 网关 —— 唯一公网入口，所有密钥只存在这一层        │
│  /api/state     世界快照（代理到隧道）                  │
│  /api/embed     代理 Workers AI bge-m3（不暴露 CF key） │
│  /api/memory    代理 Vectorize 语义检索                 │
│  /api/history   直读 D1（历史事件，不消耗服务器）       │
│  /ws            WebSocket 透传到引擎（不落 Durable Obj）│
│  职责边界：转发 + 鉴权 + 限流。**不做任何计算。**       │
└───────────────────────┬───────────────────────────────┘
                        │ cloudflared 出站隧道
                        │ （服务器不开任何公网端口）
┌───────────────────────▼──── 云服务商 2C2G / systemd ────┐
│  aitown-engine  (Go 单二进制, 目标 RSS ≈ 120MB)        │
│  ┌──────────────────────────────────────────────────┐ │
│  │ ① Tick Scheduler  1s/拍，支持 暂停 / 1x / 4x / 回放│ │
│  │ ② World State     内存网格 + 实体表（零拷贝读）   │ │
│  │ ③ Agent Runtime   状态机 idle→plan→move→talk→reflect│
│  │ ④ LLM Gateway     并发闸门 4 + 退避重试 + 预算熔断 │ │
│  │ ⑤ Memory Store    SQLite(WAL) 事件流 + 向量缓存   │ │
│  │ ⑥ Broadcaster     WebSocket 差分帧广播（省流量）  │ │
│  └──────────────────────────────────────────────────┘ │
│  aitown.db  (SQLite WAL — 引擎的唯一真相源)            │
└───────┬────────────────────────────┬──────────────────┘
        │ 异步（对话）               │ 异步（向量化 + 检索）
        ▼                            ▼
   DeepSeek API                 Workers AI (bge-m3)
   （唯一真实成本）              Vectorize（语义检索）

        ┌── 异步 ──► D1   影子库：历史事件 / 对话记录（只读查询用）
        └── 异步 ──► R2   素材包：地图瓦片 / 精灵图 / 音效
```

---

## 3. 每个关键决策的理由

### 3.1 为什么 tick 引擎放自己服务器，不放 Cloudflare

Free 档 Worker 每次调用只有 **10ms CPU**。一个游戏循环每拍要跑寻路、碰撞、状态机、序列化 —— 轻松超 50ms。付费档才有 5 分钟。放 Worker 等于第一天就撞墙。

### 3.2 为什么实时推送走隧道直连，不用 Durable Objects

DO 是 Cloudflare 里做实时最"正统"的方案。我原先的算法是：

```
1 个常亮 WebSocket DO × 24h × 3600s × 128MB / 1GB = 11,059 GB-s / 天
免费额度                                               13,000 GB-s / 天
占用率                                                        85%
```

> **⚠️ v1.1 更正**：这个算法**只对不使用 Hibernation 的写法成立**。官方 DO pricing 原文：
> 「Calling `accept()` on a WebSocket in an Object will incur duration charges for the entire time the WebSocket is connected. **It is recommended to use the WebSocket Hibernation API to avoid incurring duration charges once all event handlers finish running.**」
> 用 Hibernation API 的 DO 在休眠期**不计 duration 费**。所以「85%」是夸大的说法，DO 在免费档其实是可用的实时方案。

**结论不变（仍然不用 DO），但理由要换成正的：**
- 引擎本来就必须跑在服务器上（Go tick 循环），实时层再套一层 DO 等于把状态拆到两处维护
- 隧道直连少一个组件、少一处状态、少一种失败模式
- **不是"用不起"，是"不需要"**

### 3.3 为什么 SQLite 是主库、D1 只是影子库

引擎每一拍都要写状态。D1 免费档 **每天只给 100,000 行写入** —— 按 1 秒/拍算是 86,400 行/天，只剩 13% 余量给业务数据，毫无弹性。

正确切法：
- **SQLite 本地主库**：承担所有 tick 级热写（引擎自己的磁盘，无配额）
- **D1 影子库**：只在**游戏日结束**时批量同步一次（约 12 次/天），给前端做历史查询

这不是妥协 —— 这是把"热写"和"冷查询"分开的标准做法。

### 3.4 为什么 embedding 给 Workers AI，对话给 DeepSeek

算笔账就清楚了：

| 用途 | 模型 | 免费额度能撑多久 |
|---|---|---|
| embedding 给 Worker AI | bge-m3，1075 neurons / 百万 token | 10,000 neurons/天 ≈ **930 万 token/天**。8 人小镇实际用 **不到 1%** |
| LLM 给 Workers AI | LLM 是最贵的模型类别 | 免费额度**几分钟打爆** |

**免费额度的正确用法：把最省额度的活（embedding）放 CF，把最耗额度的活（LLM）放付费 API。** 反过来做，免费额度第一天就没。

> **v1.1 补充**：embedding 计算仍然走 Workers AI（几乎不耗额度），但**向量检索不再走 Vectorize** —— 改成在 Go 里暴力余弦，因为我们的向量规模只有几千条。见 §5.4.2。

对话走 DeepSeek：OpenAI 兼容协议、中文/粤语好、价格低。

### 3.5 为什么引擎用 Go 而不是 TypeScript

| | Go | Node/TS |
|---|---|---|
| 常驻内存 | ~15MB + 业务 ≈ 120MB | ~60MB + 业务 ≈ 250MB+ |
| 部署 | 单静态二进制 | 需要 node_modules（几百 MB） |
| 并发 | goroutine，天然适合 tick + 并发 LLM 调用 | 单线程事件循环，LLM 阻塞要小心 |

而且 —— 你的主力语言是 Go，这块正好是**能写进 Web3 简历的系统设计作品**。

---

## 4. 模拟引擎内部设计（核心章节）

### 4.1 为什么用 tick 而不是纯事件驱动

生成式 Agent 需要"时间"这个原语：「早上 8 点起床」「下午 3 点在图书馆」「晚上回家」。

tick 提供统一时钟，换来三个能力：
- **加速/暂停/回放**（调 `speed` 一个变量就行）
- **可复现**（同 seed + 同 tick 序列 = 同一个小镇历史）
- **可观测**（任何时刻的状态都能序列化成快照）

### 4.2 一拍（tick）做什么

```
for each tick:
  1. world.clock++                        推进游戏时钟（1 tick = 1 游戏分钟）
  2. runtime.stepMovement()               A* 寻路，每拍走一格
  3. runtime.scanInteractions()           同格/相邻 → 触发相遇
  4. runtime.dispatchDueAgents()          到点的 Agent 唤醒（日程驱动）
  5. memory.flushDirty()                  批量落库（每 10 拍一次，减少 fsync）
  6. broadcaster.emitDiff()               广播差分帧（无变化不发）
```

**差分帧是关键优化**：8 个 Agent 每拍只发变化量（谁动了、谁说了什么），空拍一个字节都不发。否则每秒 1 帧全量状态会把浏览器和带宽都压垮。

### 4.3 Agent 决策分层 —— 省 token 的命门

**绝对不要每拍都问 LLM。** 那是烧钱最快的方式。分四层，频率差 3 个数量级：

| 层 | 频率 | 谁来做 | 成本 |
|---|---|---|---|
| **反射层** | 每拍 | 纯规则/状态机：走路、让路、回家、打哈欠 | **0** |
| **计划层** | 每游戏日 1 次 | LLM：生成当天日程 JSON | ~800 token |
| **对话层** | 相遇时 | LLM：生成台词（谁主动、说几句） | ~400 token/段 |
| **反思层** | 每游戏日 1 次 | LLM：把当天事件压成结论 + 更新关系 | ~1000 token |

**预估消耗**：8 人 × (800 + 5×400 + 1000) ≈ **每次游戏日 3 万 token**。

按 DeepSeek 的价格，一个游戏日成本是**厘级**。一天跑 12 个游戏日也是**几毛钱**。这就是分层带来的 1000 倍差距。

### 4.4 记忆三层（对标 Stanford Generative Agents 论文）

| 层 | 内容 | 存哪 | 是否向量化 |
|---|---|---|---|
| **Observation** | 原始事件："10:03 在咖啡馆遇到阿明" | SQLite（`vec` BLOB） | ✅ 最近 200 条/人 |
| **Reflection** | 高层结论："我最近和阿明走得近，也许该表白" | SQLite（`vec` BLOB） | ✅ 每人上限 300 条 |
| **Plan** | 当日日程 | SQLite（纯文本） | ❌ 不值得 |

**检索打分**（三个因子加权，纯论文做法）：

```
score = w1 · 向量余弦相似度      // 语义相关
      + w2 · 时间衰减           // exp(-Δt / 半衰期)，越近越重
      + w3 · 重要度             // LLM 生成记忆时自评 1-10
```

取 top-K（默认 8 条）拼进 prompt。

### 4.5 并发闸门与预算熔断（"永不卡死"设计）

LLM 调用耗时数秒，而 tick 是 1 秒/拍。**如果 tick 等 LLM，整个小镇就卡死了。**

拆法：
```
tick 线程  ──publish──►  taskQueue (buffered chan, cap 256)  ──►  4 个 worker goroutine
                              │                                        │
                         不阻塞 tick                              调 LLM，数秒
                              │                                        │
                 队列满？丢最低优先级任务                   结果回来 ──► event 回灌 tick
```

**三级降级**（保证任何情况小镇都在动）：

| 触发条件 | 降级动作 | 用户体验 |
|---|---|---|
| LLM 超时 / 报错 | 换模板台词池 | 台词变生硬，但对话照常 |
| 单日 token 超预算 | 关闭对话层，只留计划层 | 小镇继续过日子，不说话 |
| 队列积压 > 80% | 丢弃低优先级任务（反思层先丢） | 无感知 |

**核心原则：LLM 是增强，不是依赖。LLM 全挂了，小镇退化成规则 NPC，但绝不黑屏。**

---

## 5. 免费额度建模（这是本项目最容易翻车的地方）

### 5.1 逐项核算

| 服务 | 免费额度 | 本项目预估 | 余量 | 风险 |
|---|---|---|---|---|
| Pages 请求/带宽 | 无上限 | — | — | ✅ |
| Pages 构建 | 500 次/月 | ~30 | 94% | ✅ |
| Workers 请求 | 100,000/天 | WS 握手级 ~几百/天 | 99%+ | ⚠️ **前提：禁止轮询**（§5.4.1） |
| **Workers CPU** | **10ms/次** | 纯转发 1-3ms | — | ⚠️ 别加逻辑 |
| Workers AI | **10,000 neurons/天**（官方核实） | bge-m3 1075 neurons/M token → 理论上限 930 万 token/天；8 人小镇实际用 **<1%** | ~99% | ✅ |
| Vectorize | 30M 查询 / 5M 存储 维度 | **不使用** | — | ✅ v1.1 已移除（§5.4.2） |
| D1 读 | 5M 行/天 | 读主导 | 高 | ✅ |
| D1 写 | **100,000 行/天** | 仅游戏日边界同步 | 高 | ✅ |
| R2 | 10GB / 1M A类 / 10M B类 | 素材 ~200MB | 高 | ✅ |
| **KV 写入** | **1,000/天** | **0（不使用）** | — | ⚠️ 主动规避 |
| Durable Objects | 100k req/天, 13,000 GB-s/天 | **不使用** | — | ✅ 不需要（非用不起，见 §5.4.3） |
| Tunnel | 免费 | 1 条 | — | ✅ |
| 服务器 | 已持有 | +120MB RSS | — | ⚠️ 监控 |
| DeepSeek | 付费 | 唯一真实成本 | — | 预算熔断 |

### 5.2 ~~Vectorize 是本项目唯一的真实免费上限~~ —— 已废弃，见 §5.4

> ⚠️ **本节结论已被 §5.4 取代。** 保留它是因为「怎么算出这个上限」的推理过程有价值，
> 而且下面的数字**依然成立** —— 只是我们最终决定**干脆不用 Vectorize**。

模型选 `@cf/baai/bge-m3`：**1024 维**、多语言（中文/粤语友好）、1075 neurons/百万 token（embedding 类里最便宜的一档）。

**存储上限**：
```
5,000,000 存储维度 ÷ 1024 维/向量 = 4,882 条向量
```

**查询上限**：
```
30,000,000 查询维度/月 ÷ 1024 维   = 29,296 次查询/月
                                   ≈ 976 次查询/天
```

**倒推小镇节奏**（这是设计的输入，不是事后估算）：

```
每人每游戏日回忆次数   10 次
8 个居民              → 80 次/游戏日
每日可承受游戏日数      976 ÷ 80 ≈ 12 个

→ 1 个游戏日 ≈ 2 小时真实时间   ← 小镇的时间流速定下来了
```

**记忆容量分配**（必须做淘汰，否则 5 天后写满）：

| 类别 | 每人上限 | 8 人合计 | 说明 |
|---|---|---|---|
| Observation | 200 条 | 1,600 | 滚动淘汰。淘汰时**只删向量**，原文留在 SQLite/D1 |
| Reflection | 300 条 | 2,400 | 长期保留，满了合并相似条目 |
| **合计** | | **4,000** | **上限 4,882，安全余量 18%** |

> **设计要点：向量库是「检索索引」，不是「真相源」。** 真相源永远是 SQLite。向量被淘汰不影响数据完整性，只影响语义检索的召回 —— 这是关键的解耦。

### 5.3 兜底方案

Vectorize 查询额度用尽时：自动降级到**本地 BM25 关键词检索**（SQLite FTS5，零成本）。效果差一些，但小镇不中断。

---

### 5.4 v1.1 修订：官方文档逐条核实后，必须纠正的 3 点

#### 5.4.1 🩸 头号风险不是额度，是「轮询」—— 这是生死线

穷举免费档所有条目后发现：最可能让项目猝死的**不是任何配额**，而是一个架构选择。

官方 Workers pricing 原文：

> WebSocket connections made to a Worker are charged as a request, representing the initial `Upgrade` connection... **WebSocket messages routed through a Worker do not count as requests.**

推论：

| 前端方案 | 每观众每日请求数 | 100,000/天 能撑几个观众 |
|---|---|---|
| 1 秒轮询 HTTP | 86,400 | **1.1 个** ❌ |
| **WebSocket** | 1（只有握手那一下） | 100,000 个 ✅ |

**结论：前端必须 WebSocket，物理上禁止轮询。**
这不是性能优化，是生死线 —— 轮询方案**两个观众同看就把当天额度烧光**。

#### 5.4.2 🧱 原方案的过度设计：Vectorize 可以不用

官方文档**自相矛盾**，而且矛盾就在同一页里：

- 正文写着 `Vectorize is currently only available on the Workers paid plan.`
- 但紧接的计费表格 Free 列写着 `30 million queried / 5 million stored vector dimensions`
- Vectorize 自己的 FAQ 又说：`the Workers free tier will always include the ability to prototype and experiment with Vectorize for free`

**这个矛盾靠读文档解决不了，需要实测**（当前被 token 缺 `Vectorize→Edit` 权限挡住）。

但更重要的发现是 —— **这个纠结根本没必要**。

8 个居民、每人几百条记忆，全镇上限约 4,000 条向量。这个规模下：

```
4000 条 × 1024 维 × 4 字节(float32) = 16 MB 常驻内存
一次全量暴力点积: 4000 × 1024 ≈ 410 万次乘加 ≈ 2-4 ms（单核，Go）
```

**Vectorize 的价值从百万级向量才开始显现。我们差 3 个数量级。**

**v1.1 决策对照：**

| | v1.0 原方案 | **v1.1 新方案** |
|---|---|---|
| embedding 计算 | Workers AI bge-m3 | **不变**（免费额度只用 <1%） |
| 向量存储 | Vectorize | **SQLite BLOB（float32）** |
| 向量检索 | Vectorize 查询 API | **Go 内暴力余弦，2-4ms** |
| 查询配额 | ~813 次/天 ⚠️ | **无限制** ✅ |
| 存储配额 | 4,882 条 ⚠️ | **无限制**（实际受内存约束 ≈ 50 万条） |
| 每次检索网络往返 | 1 次 CF 往返 | **0（纯本地内存）** |
| 是否依赖文档矛盾 | 是 ⚠️ | **否** ✅ |

**收益：免费档唯一的硬墙消失了，检索延迟还下降一个数量级。**
连带好处：既然不算配额了，"1 个游戏日 = 2 小时"这个节奏约束也解除 ——
时间流速可以自由调，想加速到 5 分钟/游戏日也不用重新算账。

#### 5.4.3 ⚠️ 原方案的一处夸大：Durable Objects

我原先写「常亮 WS 的 DO 一天吃掉 85% 额度」。**这个说法不严谨，必须更正。**

官方 DO pricing 原文：

> Calling `accept()` on a WebSocket in an Object will incur duration charges for the entire time the WebSocket is connected. **It is recommended to use the WebSocket Hibernation API to avoid incurring duration charges once all event handlers finish running.**

即：**使用 Hibernation API 的 DO，休眠期间不计 duration 费用。** 那笔 85% 的账只对不使用 Hibernation 的写法成立。

**结论不变（仍然不用 DO），但理由要换成正的那个：**
- 引擎本来就必须跑在服务器（Go tick 循环），实时层再套一层 DO 等于把状态拆到两处维护
- 隧道直连少一个组件、少一处状态、少一种失败模式
- **不是「用不起」，是「不需要」**

#### 5.4.4 ✅ 核实结论

**免费档够用** —— 前提是守住下面四条红线：

1. **前端只走 WebSocket，禁止轮询**（§5.4.1）
2. **Worker 保持"哑管道"**：不做业务计算，10ms CPU 很紧
3. **tick 级热写全部落 SQLite**，D1 只在游戏日边界批量同步（§3.3）
4. **不引入 Vectorize**（§5.4.2）

唯一真实花钱的地方是 **DeepSeek 对话 token**（非 CF，见 §5.5）。

### 5.5 唯一真实成本：DeepSeek（官方定价已核实）

CF 免费档之外，只有这一项要花钱。

| 模型 | 输入（缓存未命中） | 输入（缓存命中） | 输出 |
|---|---|---|---|
| **deepseek-v4-flash**（本项目选用） | $0.15/M 闲时 · $0.30/M 忙时 | $0.003/M · $0.006/M | $0.60/M 闲时 · $1.20/M 忙时 |
| deepseek-v4-pro | $0.66/M · $1.32/M | — | $1.98/M · $3.96/M |

**本项目月度推算**（§4.3 的分层预算：30k token/游戏日，跑 12 游戏日/天）：

```
输入 20k + 输出 10k 每游戏日
× 12 游戏日/天 × 30 天
= 7.2M 输入 + 3.6M 输出 / 月

忙时: 7.2 × $0.30 + 3.6 × $1.20 = $6.48 / 月
闲时: 7.2 × $0.15 + 3.6 × $0.60 = $3.24 / 月
```

**→ 约 $3–6.5/月（¥22–47）**，这就是整个项目唯一的真实支出。

> 🔧 **顺带发现一个必改的 bug**：`deepseek-chat` 这个模型名**已于 2026-07-24 弃用**（自动映射到 `deepseek-v4-flash`）。
> 部署脚本里的环境变量必须改成 `deepseek-v4-flash`，否则会一直走弃用映射路径。

**降本空间**：DeepSeek 的**上下文缓存**对固定前缀（人设 + 规则 + 小镇背景）生效，
缓存命中价比未命中便宜 **50 倍**。把不变的内容放 prompt 前部即可大幅削减输入成本。

---

## 6. 数据模型

### 6.1 SQLite（服务器，主库）

```sql
world         (id, tick, game_minute, speed, seed, status)
agents        (id, name, persona, home_x, home_y, state, mood, tick_updated)
positions     (agent_id, x, y, facing, path_json)          -- 热表，10 拍 flush 一次
plans         (agent_id, game_day, schedule_json, created_tick)
events        (id, tick, agent_id, type, payload_json, importance, created_at)
memories      (id, agent_id, kind, text, importance, vec BLOB, vec_dim, created_tick, archived)
relations     (agent_id, other_id, affinity, last_interact_tick, note)
conversations (id, tick, a_id, b_id, transcript_json)
token_usage   (day, prompt_tokens, completion_tokens, cost_estimate)
```

索引：`events(tick)`、`memories(agent_id, kind, created_tick)`、`relations(agent_id)`

### 6.2 D1（影子库，冷查询）

只同步 3 张表，且只在游戏日边界：

```
agents        —— 档案（前端"居民列表"）
events        —— 事件流（前端"时间线"）
conversations —— 对话记录（前端"回看聊天"）
```

不同步 `positions` / `memories`（热数据 + 体积大）。

---

## 7. 网络暴露

引擎**只绑 `127.0.0.1:8080`**，不开任何公网端口。入口只有一条 cloudflared 出站隧道。

现有资源：一条 named tunnel `<other-tunnel-uuid>`（服务 peer-service）。

两种模式（取决于你是否有域名）：

| 模式 | 条件 | 特点 |
|---|---|---|
| **A. Named tunnel + DNS** | 有域名托管在 CF | URL 固定，Worker 环境变量配死，最省事 |
| **B. Quick tunnel** | 无域名 | URL 每次重启变，需 tunnel-monitor 自动同步到 Worker 环境变量 |

> ⚠️ **已知限制**：named tunnel **无 DNS 路由时不可外部访问**（`cfargotunnel.com` 需要 CNAME）。这是你之前踩过的坑。
> **推荐**：给 ai-town 单独建一条 tunnel（不要和 peer-service 共用，避免一个挂两个都挂），ingress 指向 `localhost:8080`。

---

## 8. 仓库结构

```
ai-town/
├── docs/
│   └── ARCHITECTURE.md          ← 本文档
├── engine/                      → 自建云主机（Go）
│   ├── cmd/aitown/main.go
│   ├── internal/
│   │   ├── world/               世界状态 + tick
│   │   ├── agent/               状态机 + 决策分层
│   │   ├── llm/                 DeepSeek 客户端 + 闸门 + 熔断
│   │   ├── memory/              SQLite + 本地暴力向量检索（v1.1）
│   │   ├── broadcast/           WebSocket 差分帧
│   │   └── shadow/              D1 影子同步
│   └── go.mod
├── edge/                        → Cloudflare Workers
│   ├── src/index.ts
│   └── wrangler.toml
├── frontend/                    → Cloudflare Pages
│   ├── src/  (PixiJS)
│   └── package.json
├── deploy/                      ← 部署脚本（本阶段产出）
└── .github/workflows/
```

**部署顺序：edge → engine → frontend**（前端要连 edge；edge 要连 engine）。

**CI/CD**：GitHub Actions。服务器侧用 **self-hosted runner**，不要用 SSH —— SSH 从 GitHub IP 段发起会触发云服务商安全告警（你已在 peer-service 上踩过这个坑）。

---

## 9. 里程碑

| 阶段 | 交付 | 验收标准 |
|---|---|---|
| **M1 链路** | 引擎跑 tick + WebSocket 广播 + 前端画出 8 个点 | 浏览器里看到 8 个点在动，断线重连正常 |
| **M2 智能** | 接入 DeepSeek，日程 + 对话 | Agent 有作息规律，见面会说话 |
| **M3 记忆** | Vectorize 检索 + 反思层 | Agent 能引用昨天的事，关系值有变化 |
| **M4 介入** | 观众给 Agent 递消息 | 消息影响该 Agent 的下一步行为 |
| **M5 打磨** | 加速/暂停/回放 + 成本看板 | 免费额度用尽不中断，成本可视化 |

**M1 是分水岭**：M1 之前架构都在纸上，M1 之后每加一个功能都是增量。建议 M1 严格不接 LLM —— 先把"心跳"和"血管"验证通。

---

## 10. 已知风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| 服务器内存被顶爆 | 中 | 高 | 引擎设 `GOMEMLIMIT=150MiB`；部署前 preflight 检查可用内存 |
| Vectorize 存储写满 | 高（若不淘汰） | 中 | 淘汰策略必须 M1 就实现，不能拖到 M3 |
| Vectorize 查询超额 | 中 | 中 | 自动降级 BM25；节奏参数（游戏日/真实日）做成可配 |
| Workers CPU 10ms 超限 | 低 | 高 | edge 层**只准转发**，代码评审卡这一条 |
| 误用 KV 存状态 | 中 | 高 | KV 只读配置；写路径物理上不接 KV |
| LLM 成本失控 | 中 | 中 | 单日 token 硬预算 + 超限降级；`token_usage` 表每日对账 |
| 隧道断连 | 中 | 高 | systemd `Restart=always` + 前端指数退避重连 |
| 同机负载争抢 | 中 | 中 | `systemd` 设 `CPUWeight` / `MemoryMax` 限制引擎 |

---

## 附录 A：核实过的官方数据来源

| 数据 | 来源 |
|---|---|
| Workers Free：100k 请求/天、**10ms CPU**、128MB 内存、50 子请求 | developers.cloudflare.com/workers/platform/limits/ |
| Workers AI：10,000 neurons/天，$0.011/1k neurons，00:00 UTC 重置 | developers.cloudflare.com/workers-ai/platform/pricing/ |
| bge-m3：1024 维、1075 neurons/百万 token；bge-small 1841；bge-large 18582 | 同上 |
| Vectorize Free：**30M 查询维度/月、5M 存储维度**；单向量上限 1536 维；Free 100 索引、1000 namespace | developers.cloudflare.com/vectorize/platform/pricing/ + /limits/ |
| D1 Free：5M 行读/天、**100k 行写/天**、5GB 存储 | developers.cloudflare.com/d1/platform/pricing/ |
| Durable Objects Free：100k 请求/天、**13,000 GB-s/天**；Free 仅支持 SQLite 后端 | developers.cloudflare.com/durable-objects/platform/pricing/ |
| R2 Free：10GB 存储/月、1M A类、10M B类、出站免费 | developers.cloudflare.com/r2/pricing/ |
| KV Free：100k 读/天、**1k 写/天**、1GB 存储 | developers.cloudflare.com/kv/platform/pricing/ |
| Pages Free：500 构建/月、20,000 文件、单文件 25MiB、请求带宽无上限 | developers.cloudflare.com/pages/platform/limits/ |
| Queues Free：10,000 操作/天、保留 24h | developers.cloudflare.com/queues/platform/pricing/ |

## 附录 B：环境实测记录

```
主机      <cloud-host>  Linux 6.8.0-71-generic  x86_64
CPU       2 vCPU
内存      1.9GB total / 888MB used / 1.1GB available
Swap      1.9GB (已用 360MB)
磁盘      50GB total / 19GB available (62% used)
Node      v24.14.0   npm 11.9.0   pnpm 10.30.2
Python    3.11.15
Go        ✗ 未安装（部署脚本会装）
Docker    ✗ 未安装（本方案不需要）
wrangler  4.99.0（CLOUDFLARE_API_TOKEN 已配置，账号 50a4fadd…）
cloudflared 已装，named tunnel <other-tunnel-uuid> → localhost:7360 (peer-service)
在跑服务  peer-gateway / peer-service / cloudflared-peer
          / actions.runner.other-repo-runner / sub-proxy(3X-UI) / tailscaled / fail2ban
公网出口  api.cloudflare.com ✓ 200    api.deepseek.com ✓ 401(可达)
```

**内存预算推演**：

```
当前可用                    1,100 MB
├─ aitown-engine 目标         -120 MB
├─ SQLite page cache           -30 MB
├─ 峰值余量（LLM 突发/GC）    -200 MB
└────────────────────────────────────
   部署后预计可用              750 MB   ← 可接受，留了 2 倍安全系数
```

**部署前必须做**：确认 GC 峰值不会触发 OOM killer。建议给引擎设 `MemoryHigh=400M` / `MemoryMax=600M`（超了先限制后杀，不会拖垮整机）。

---
