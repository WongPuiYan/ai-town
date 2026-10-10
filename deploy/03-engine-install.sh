#!/usr/bin/env bash
# deploy/03-engine-install.sh
# 目的：把模拟引擎装成 systemd 服务（本机 127.0.0.1:8080，不开公网端口）。
# 幂等：重复跑会重新生成 unit、重新编译、平滑重启。
# 内存保护：MemoryHigh=400M 先节流 / MemoryMax=600M 才杀，绝不拖垮同机其他服务。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE_DIR="${PROJECT_ROOT}/engine"
# 部署机的运行期目录：默认 $HOME/ai-town，可用 AITOWN_HOME 覆盖（不写死具体家目录）
AITOWN_HOME="${AITOWN_HOME:-${HOME}/ai-town}"
ENGINE_BIN="${AITOWN_HOME}/bin/aitown"
DATA_DIR="${AITOWN_HOME}/data"
LOGS_DIR="${AITOWN_HOME}/logs"
UNIT="/etc/systemd/system/aitown-engine.service"
RUN_AS="$(id -un)"

step "03  安装模拟引擎"

# ---------------------------------------------------------------- 前置检查
step "3.1  资源预检"
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo)
log "可用内存 ${MEM_AVAIL} MB"
if (( MEM_AVAIL < 400 )); then
  die "可用内存不足 400MB，装引擎有 OOM 风险。先释放内存。"
fi
ok "内存预检通过"

if ss -tlnp 2>/dev/null | grep -q ":${ENGINE_PORT} "; then
  warn "端口 ${ENGINE_PORT} 已被占用，引擎可能已在运行（将走重启流程）"
fi

# ------------------------------------------------------------------ 装 Go
step "3.2  Go 工具链"
if command -v go >/dev/null 2>&1; then
  ok "Go 已安装: $(go version)"
else
  log "未检测到 Go，安装官方二进制（约 70MB）..."
  GO_VER="1.24.1"
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  TMP=$(mktemp -d)
  if curl -fsSL -m 300 "https://go.dev/dl/go${GO_VER}.linux-${ARCH}.tar.gz" -o "${TMP}/go.tgz"; then
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${TMP}/go.tgz"
    ok "Go 安装到 /usr/local/go"
    export PATH="$PATH:/usr/local/go/bin"
    grep -q '/usr/local/go/bin' "${HOME}/.bashrc" || \
      echo 'export PATH=$PATH:/usr/local/go/bin' >> "${HOME}/.bashrc"
  else
    rm -rf "$TMP"
    die "Go 下载失败。可手动安装后重跑本脚本。"
  fi
  rm -rf "$TMP"
fi

# ------------------------------------------------------------------ 目录
step "3.3  创建目录结构"
for d in "$DATA_DIR" "$(dirname "$ENGINE_BIN")" "$LOGS_DIR"; do
  mkdir -p "$d" && ok "目录就绪 $d"
done
chmod 750 "$DATA_DIR"; ok "data 目录权限收紧为 750（含 Agent 记忆，属敏感数据）"

# ---------------------------------------------------------------- 环境文件
step "3.4  引擎环境文件"
ENV_FILE="${AITOWN_HOME}/engine.env"
if [[ ! -f "$ENV_FILE" ]]; then
  load_cf_token 2>/dev/null || true
  cat > "$ENV_FILE" <<EOF
# AI Town 引擎配置 —— 权限 600，勿提交到 Git
# 服务器地址（只绑本地，隧道对外）
AITOWN_ADDR=127.0.0.1:${ENGINE_PORT}

# SQLite 主库
AITOWN_DB=${DATA_DIR}/aitown.db

# 时间节奏：1 个游戏日 = 多少真实秒
# v1.1：不再受 Vectorize 配额倒推约束（已改本地检索），此值可自由调。
# 7200s = 2 小时/游戏日 → 一天约 12 个游戏日。
AITOWN_GAME_DAY_SECONDS=7200
AITOWN_TICK_SECONDS=1

# LLM：走 edge 网关转发（DEEPSEEK key 存在 Cloudflare，不落服务器磁盘）
AITOWN_LLM_BASE_URL=${EDGE_URL:-http://127.0.0.1:8787}/api/llm
# ⚠️ 模型名必须是 deepseek-v4-flash：旧的 deepseek-chat 已于 2026-07-24 弃用
AITOWN_LLM_MODEL=deepseek-v4-flash
AITOWN_LLM_MAX_CONCURRENCY=4
AITOWN_LLM_QUEUE_SIZE=256

# 成本熔断：单日 token 硬上限，超了自动降级到模板台词
AITOWN_DAILY_TOKEN_BUDGET=500000
AITOWN_FALLBACK_MODE=template

# 记忆：embedding 走 edge 代理到 Workers AI（bge-m3, 1024 维，免费额度实耗 <1%）
# 但【检索】在本地做暴力余弦，不走 Vectorize（v1.1 决策，架构 §5.4.2）
AITOWN_EMBED_DIMS=${EMBED_DIMS}
AITOWN_VECTOR_BACKEND=${VECTOR_BACKEND:-local}
AITOWN_VECTOR_INDEX=${VECTOR_INDEX}
# 本地向量检索的内存上限（4,000 条 × 1024 维 ≈ 16MB，给 64MB 余量）
AITOWN_VEC_MEM_LIMIT_MB=64
AITOWN_MAX_OBS_PER_AGENT=200
AITOWN_MAX_REFLECT_PER_AGENT=300

# 观众数上限（WebSocket 广播扇出）
AITOWN_MAX_VIEWERS=50
EOF
  chmod 600 "$ENV_FILE"
  ok "已生成 ${ENV_FILE}"
else
  ok "复用已有 ${ENV_FILE}"
  warn "如果隧道 URL 变了，记得更新 AITOWN_LLM_BASE_URL"
fi

# 引擎 ↔ edge 共享口令：放在 engine.env（600），部署脚本从这里取同一个值。
# 缺了它引擎会【完全不鉴权】，隧道 URL 一旦泄漏任何人都能连。
# 注意顺序：先 ensure_edge_token（它会在文件已存在且缺 token 时补写），再判断，
# 否则会和它各写一行 —— 同一个键出现两次（systemd 取最后一行，值相同但很难看）。
ensure_edge_token >/dev/null 2>&1 || true
if grep -q '^AITOWN_EDGE_TOKEN=' "$ENV_FILE" 2>/dev/null; then
  ok "AITOWN_EDGE_TOKEN 已就位（值不打印）"
else
  printf '\n# 引擎 ↔ edge 共享口令（Worker 转发时带 X-Edge-Token）\nAITOWN_EDGE_TOKEN=%s\n' "$EDGE_SHARED_TOKEN" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "已生成 AITOWN_EDGE_TOKEN 并写入 ${ENV_FILE}（值不打印）"
fi

# ------------------------------------------------------------------ 编译
step "3.5  编译引擎"
if [[ -f "${ENGINE_DIR}/go.mod" ]]; then
  cd "$ENGINE_DIR"
  export PATH="$PATH:/usr/local/go/bin"
  # -trimpath: 去掉本地路径; -s -w: 去符号表 → 二进制更小
  log "go build -trimpath -ldflags='-s -w' ..."
  if CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${ENGINE_BIN}.new" ./cmd/aitown; then
    # 关键：先停服务再替换二进制，否则 "Text file busy"
    if systemctl is-active --quiet aitown-engine 2>/dev/null; then
      sudo systemctl stop aitown-engine
      log "已停止旧服务（避免 Text file busy）"
    fi
    mv "${ENGINE_BIN}.new" "$ENGINE_BIN"
    chmod 755 "$ENGINE_BIN"
    ok "编译完成 $(du -h "$ENGINE_BIN" | cut -f1) → ${ENGINE_BIN}"
  else
    die "编译失败。修好 ${ENGINE_DIR} 下的代码后重跑。"
  fi
else
  warn "找不到 ${ENGINE_DIR}/go.mod —— 引擎代码尚未编写（当前 M0 阶段）"
  log "跳过编译，继续装 systemd unit（unit 先指向占位二进制，代码就绪后重跑本脚本即可）"
fi

# ------------------------------------------------------------- systemd unit
step "3.6  systemd unit"
sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=AI Town Simulation Engine (tick loop + agent runtime)
Documentation=file://${PROJECT_ROOT}/docs/ARCHITECTURE.md
After=network-online.target
Wants=network-online.target
# 与同机其它常驻服务共存，互为独立服务
Conflicts=

[Service]
Type=simple
User=${RUN_AS}
Group=${RUN_AS}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${ENV_FILE}

# 只绑本地，公网入口只有 cloudflared 隧道
ExecStart=${ENGINE_BIN}

Restart=always
RestartSec=5
# LLM 调用可能瞬时打满，给足优雅退出时间把 SQLite 刷盘
TimeoutStopSec=30
KillSignal=SIGTERM

# ── 资源护栏（关键：小内存机器的保命设置）──────────────────
# Go GC 目标软上限。超过后 GC 会疯狂跑而不是撑爆内存
Environment=GOMEMLIMIT=150MiB
# 到 400M 开始节流（回收 page cache / 降速），到 600M 才 OOM kill
MemoryHigh=400M
MemoryMax=600M
# CPU 让位给同机其它常驻服务
CPUWeight=50
Nice=5

# ── 安全加固 ──────────────────────────────────────────────
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${DATA_DIR} ${LOGS_DIR}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=8192

# ── 日志 ──────────────────────────────────────────────────
StandardOutput=append:${LOGS_DIR}/engine.log
StandardError=append:${LOGS_DIR}/engine.err.log
SyslogIdentifier=aitown-engine

[Install]
WantedBy=multi-user.target
EOF
ok "unit 已写入 ${UNIT}"

log "设置日志轮转（防止日志把磁盘吃满）..."
sudo tee /etc/logrotate.d/aitown >/dev/null <<EOF
${LOGS_DIR}/*.log {
    daily
    rotate 7
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
ok "logrotate 配置完成（保留 7 天 / 单文件超 50M 轮转）"

# ---------------------------------------------------------------- 启动
step "3.7  启动服务"
sudo systemctl daemon-reload
sudo systemctl enable aitown-engine >/dev/null 2>&1 && ok "已设为开机自启"

if [[ -x "$ENGINE_BIN" ]]; then
  sudo systemctl restart aitown-engine
  sleep 3
  if systemctl is-active --quiet aitown-engine; then
    ok "服务运行中"
    MEM=$(systemctl show aitown-engine -p MemoryCurrent --value 2>/dev/null)
    [[ -n "$MEM" && "$MEM" != "[not set]" ]] && log "当前内存占用: $(( MEM / 1024 / 1024 )) MB"
    CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:${ENGINE_PORT}/health" || echo 000)
    log "本机健康检查: HTTP ${CODE}"
  else
    warn "服务未启动，最近日志："
    sudo journalctl -u aitown-engine -n 25 --no-pager | sed 's/^/       /'
  fi
else
  warn "二进制不存在（代码未编写），跳过启动"
  sudo systemctl disable aitown-engine >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 回归验证
step "3.8  同机服务回归验证（确认没被影响）"
if [[ -n "${AITOWN_PEER_SERVICES:-}" ]]; then
  for s in ${AITOWN_PEER_SERVICES}; do
    if systemctl is-active --quiet "$s"; then ok "$s 仍正常"; else warn "⚠️ $s 异常！请立即检查"; fi
  done
else
  log "未指定 AITOWN_PEER_SERVICES，跳过同机服务点名"
fi
log "整机内存：$(free -m | awk '/Mem:/{print $3" MB 已用 / "$2" MB 总量"}')"

ok "下一步：05-tunnel-setup.sh（暴露到公网）"
