# AI Town

一个自建的 2D AI 小镇：8 个有性格、有记忆、有关系值的 AI 居民，实时演给你看。

**部署形态**：Cloudflare（前端 + 边缘网关）/ 自建云主机（模拟引擎）/ DeepSeek（Agent 大脑）

---

## 快速开始

```bash
cd ~/ai-town

./deploy/00-preflight.sh        # 1. 环境自检（只读，随时可跑）
./deploy/01-cf-resources.sh     # 2. 创建 CF 资源（D1/R2/KV，不含 Vectorize）
./deploy/03-engine-install.sh   # 3. 服务器：装引擎 + systemd
./deploy/05-tunnel-setup.sh     # 4. 打通隧道（拿到公网入口）
./deploy/02-edge-deploy.sh      # 5. 部署 edge 网关（填入隧道地址）
./deploy/04-frontend-deploy.sh  # 6. 部署前端
./deploy/quota-check.sh         # 7. 看免费额度消耗
```

顺序不能乱：**3 要在 5 之前**（隧道要指向活着的引擎），**5 要在 2 之前**（edge 要知道引擎在哪）。

## ✅ CF 权限已就绪（2026-10-10 API 逐项实测）

`./deploy/00-preflight.sh` → **「全部检查通过，可以执行 01-cf-resources.sh」**（exit 0）。

| 权限 | 用途 | 状态 |
|---|---|---|
| Account → **D1** → Edit | 影子库 | ✅ 已开通（本次补上） |
| Account → **Workers AI** → Edit | embedding | ✅ 已开通（本次补上，70 个模型可见） |
| Account → Workers Scripts → Edit | edge 网关 | ✅ |
| Account → Pages → Edit | 前端 | ✅ |
| Account → Workers KV → Edit | 只读配置 | ✅ |
| Account → Cloudflare Tunnel → Edit | 隧道 | ✅ |
| Zone → DNS → Edit | （账号下 0 域名，暂无用武之地） | ✅ |
| Account → Account Analytics → Read | quota-check 看额度 | ✅ |
| Account → Account Settings → Read | 预检 | ✅ |
| Account → R2 → Edit | 素材存储（**首版不用**） | 🟢 未开通，不阻塞 —— 要用得先在 Dashboard 走 checkout 开通 R2 服务（code=10042）。⚠️ 账号未开通 R2 时 CF 在任何权限判断**之前**就返回 10042，所以 token 上 R2 权限到底加没加上，**从 API 无法验证**；对照证据：真正缺权限的端点（Vectorize、Billing 订阅）返回的是 `code=10000 Authentication error` |
| Account → Vectorize → Edit | ~~记忆检索~~ | ⬜ v1.1 已不用（本地暴力余弦） |

> 🔧 2026-10-10 修的探针 / 脚本 bug（曾导致误报「缺 5 项」+ D1 建表全军覆没）：

**权限探针类**
1. `00-preflight.sh` 用 `grep '"success":true'` 判断，但 CF 部分端点返回带空格的 pretty JSON → 永远匹配不上 → Pages / Workers Scripts 被误判为缺权限（其实早就有）。
2. `00-preflight.sh` GraphQL 里把 `"$(date …)"` 写进单引号 → 被当字面量 → 误判权限缺失。

**资源创建类**
3. `01-cf-resources.sh` **按「行」而不是按「分号」切 SQL** → 每个多行 `CREATE TABLE` 被拆成 3 段单独提交，实测 15 条全失败（首行 `incomplete input`、后续 `near "id": syntax error`），**D1 建完是空库**。已改为按分号切语句（并在结尾兜底执行无分号的尾巴），复验 6 条 DDL 全 OK、回读得到 3 表 3 索引。
4. `01-cf-resources.sh` 判断 R2 桶是否已存在时写死紧凑 JSON `grep "\"name\":\"bucket\""` → pretty JSON 下漏判 → 会把「已存在」当「不存在」去重复创建，然后报「创建失败，检查 R2 权限」把人带偏。已改为容忍空格，并区分 `10042（服务未开通）` / `权限缺失` / `真要创建` 三种分支。

**其它**
5. `quota-check.sh` 给 `readonly` 变量 `EMBED_DIMS` 重复赋值 → `set -e` 下崩在第 16 行（**此脚本从未跑通过一次**）；另有 `${R2_BUCKET_NAME}` unbound。
   > 另把 R2 归入 **optional**（不再计入失败），使预检结论与「首版不用 R2」的设计一致。
6. `02-edge-deploy.sh` 生成的 `wrangler.toml` **无条件**写 `[[r2_buckets]]` → R2 未开通时 `bucket_name` 为空 → `wrangler deploy` 会直接失败。已改为条件生成（R2 未开通时写一行注释代替绑定）。
7. `lib.sh` 的 `load_state` 用 `source` 加载 `.state.env`，而 01 会把 `EMBED_DIMS`（**lib.sh 里是 `readonly`**）写进状态文件 → **01 跑完那一刻起，02/03/04/05 全部在 source 阶段报 readonly 错并终止**（实测 02 就是这样挂的）。已改为逐行 export + 跳过 readonly 键；`save_state` 也不再写 readonly 键。
   > 判断 readonly 必须用 `declare -p X | grep -E '^declare -[A-Za-z]*r'` —— bash 打印的是 `declare -r X="1024"`，`grep ' readonly'` **永远匹配不上**（第一版修复就踩了这个坑）。

> ⚠️ **账号下 0 个域名** → `05-tunnel-setup.sh` 会自动落到 **quick tunnel 模式**（URL 每次重启变，
> 需自动同步进 Worker 环境变量）。要用 named tunnel 得先在 CF 添加一个域名。

下一步：**M1 已上线 Cloudflare**（2026-10-10），公开可访问：

| 环节 | 地址 / 位置 |
|---|---|
| 页面（Pages） | **https://ai-town-cbn.pages.dev** ← 用浏览器打开这个 |
| Worker（哑管道） | `https://aitown-edge.dcneowong.workers.dev`（WS 直通 + REST 转发） |
| 引擎 | 本机 systemd `aitown-engine`，`127.0.0.1:8080`，`X-Edge-Token` 鉴权 |
| 公网入口 | cloudflared quick tunnel（URL 会漂移，漂移后自动改 `wrangler.toml` 并重新部署 Worker） |

经 Worker 的公开地址验收：**8/8 居民在动、30 帧差分、零协议错误**（`node scripts/m1-verify.mjs wss://aitown-edge.dcneowong.workers.dev/ws 30`）。
**浏览器渲染 / 断线重连**已交用户目视确认。之后进 **M2（接 DeepSeek：日程 + 相遇对话 + 气泡）**。

本地跑起来（不碰任何云资源、不烧一分钱）：

```bash
cd ~/ai-town/engine && GOTOOLCHAIN=local go build -o ../bin/aitown ./cmd/aitown
AITOWN_EDGE_TOKEN=dev ../bin/aitown -addr 127.0.0.1:8080 &
node scripts/m1-verify.mjs 'ws://127.0.0.1:8080/ws?token=dev' 30   # ✅ 退出码 0
```

## 💰 免费档够不够？—— 结论：**够**，但要守四条红线（2026-09-30 逐条核实官方文档）

| 服务 | 免费额度 | 本项目预估用量 | 余量 |
|---|---|---|---|
| Pages 请求/带宽 | 无上限 | — | ✅ |
| **Workers 请求** | **100,000/天** | WS 握手级 ~几百/天 | 99%+ ⚠️ 前提：禁止轮询 |
| Workers CPU | 10ms/次 | 纯转发 1-3ms | ⚠️ edge 别加逻辑 |
| Workers AI | 10,000 neurons/天 | embedding 实耗 **<1%** | ✅ |
| D1 行写入 | 100,000/天 | 仅游戏日边界同步 | ✅ |
| R2 | 10GB 存储 | ~200MB 素材 | ✅ |
| Tunnel | 免费 | 1 条 | ✅ |
| Vectorize | — | **不使用**（v1.1） | ✅ 无配额压力 |

**唯一花钱的地方**：DeepSeek 对话 token → 约 **$3–6.5/月（¥22–47）**，这是全项目唯一的真实支出。

**四条红线（违反任何一条，免费档就破）**：

1. 🩸 **前端只走 WebSocket，禁止轮询** —— WS 消息经 Worker 转发*不计*请求数；改成 1 秒轮询就是 86,400 请求/天/观众，**两个观众就把当天额度烧光**
2. **Worker 保持哑管道** —— 不做业务计算，10ms CPU 非常紧
3. **tick 级热写全落 SQLite** —— D1 只在「游戏日」边界批量同步快照
4. **不引入 Vectorize** —— 本镇向量规模只有几千条，Go 本地暴力余弦 2-4ms 就够

完整核算过程见 `docs/ARCHITECTURE.md` §5.4 / §5.5。

## 当前阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | 架构文档 + 部署脚本脚手架 | ✅ 已完成 |
| **M1** | 引擎 tick 循环 + WebSocket 广播 + 前端画出 8 个点（不接 LLM） | ✅ **已上线 CF**（2026-10-10；页面 https://ai-town-cbn.pages.dev ，协议级公开验收 8/8，**浏览器渲染 / 断线重连待人工确认**） |
| M2 | 接 DeepSeek：日程生成 + 相遇对话 + 气泡 | ⬜ |
| M3 | 记忆系统：本地向量检索 + 每日反思 | ⬜ |
| M4 | 观察者介入：给 Agent 发消息 | ⬜ |
| M5 | 变速/暂停/回放 + 成本看板 | ⬜ |

M0 阶段脚本的行为：能做的都做（建资源、装 systemd、配隧道），
遇到还没写的业务代码会**明确提示并跳过**，不会假装成功。

## 目录

```
ai-town/
├── docs/ARCHITECTURE.md    ← 架构设计（先读这个）
├── docs/SUMMARY.md         ← 项目汇总（以本文为准）
├── docs/PROTOCOL.md        ← 引擎↔edge↔前端 线协议 v1
├── deploy/                 ← 部署脚本（幂等，可重复跑）
│   ├── lib.sh              公共函数 + 状态文件
│   ├── 00-preflight.sh     环境自检
│   ├── 01-cf-resources.sh  创建 Cloudflare 资源
│   ├── 02-edge-deploy.sh   部署 Workers 网关
│   ├── 03-engine-install.sh 装模拟引擎（systemd）
│   ├── 04-frontend-deploy.sh 部署 Pages 前端
│   ├── 05-tunnel-setup.sh  隧道暴露
│   └── quota-check.sh      免费额度看板
├── engine/                  ← Go 引擎（M1 已落地）
│   ├── cmd/aitown/          main：tick 循环 + HTTP/WS 入口
│   └── internal/world      地图/地点/居民/时钟 + BFS 寻路
│       ├── broadcast/       WS 差分广播（慢客户端直接踢）
│       └── store/           SQLite 主库（每 10 拍 flush）
├── edge/                    ← Cloudflare Worker（哑管道）
├── frontend/                ← canvas 前端（Vite + TS，只走 WS）
├── scripts/m1-verify.mjs    ← M1 验收脚本（可重复跑）
└── .state.env              ← 脚本间传递资源 ID（git 忽略）
```

## 资源命名

| 资源 | 名称 |
|---|---|
| Worker | `aitown-edge` |
| Pages | `ai-town` |
| D1 | `aitown-shadow` |
| Vectorize | ~~`aitown-memory`~~ **不使用**（v1.1 改本地检索） |
| KV | `aitown-config` |
| R2 | `aitown-assets` |
| Tunnel | `aitown-engine` |
| 服务 | `aitown-engine.service` / `cloudflared-aitown.service` |

## 关键约束（违反会静默失败）

- **部署机内存小（2GB）且与其它常驻服务同机** → 引擎 `MemoryMax=600M`，用完即让位
- 🩸 **前端禁止轮询，只走 WebSocket** → WS 消息经 Worker 转发不计请求数；1 秒轮询 = 86,400 请求/天/观众，免费额度只够 1.1 个观众
- **不用 Durable Objects** → 与服务器引擎职责重复（不是用不起，见架构 §5.4.3）
- **Worker CPU 只有 10ms** → edge 层只转发，禁止加计算
- **D1 免费行写入 100k/天** → 只在「游戏日」边界同步快照
- **不使用 Vectorize** → 记忆检索改 Go 本地暴力余弦，免费档不再有硬墙
- **LLM 模型名必须用 `deepseek-v4-flash`** → `deepseek-chat` 已于 2026-07-24 弃用
- **引擎不开公网端口** → 只绑 127.0.0.1，出口唯一是隧道

## 回滚

```bash
sudo systemctl disable --now aitown-engine cloudflared-aitown
rm -rf ~/ai-town/data ~/ai-town/bin
npx wrangler delete --name aitown-edge --force
npx wrangler pages project delete ai-town
```

Cloudflare 侧资源（D1/R2/KV）不会自动删除，需要到 Dashboard 手动清理 —— 这是刻意的，防止误删数据。
