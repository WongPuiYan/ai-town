#!/usr/bin/env bash
# deploy/00-preflight.sh
# 目的：部署前把「一定会炸的地方」提前炸出来 —— 内存、端口、工具、CF 权限。
# 幂等：只读，不改任何东西。安全，可随时重跑。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAIL=0
note_fail() { warn "$1"; FAIL=$((FAIL+1)); }

step "1/6  系统资源"
MEM_TOTAL=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo)
SWAP_TOTAL=$(awk '/SwapTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
SWAP_FREE=$(awk '/SwapFree/{printf "%.0f", $2/1024}' /proc/meminfo)
CPU_N=$(nproc 2>/dev/null || echo '?')
log "CPU:      ${CPU_N} 核"
log "内存:     ${MEM_TOTAL} MB 总量 / ${MEM_AVAIL} MB 可用"
log "Swap:     ${SWAP_TOTAL} MB 总量 / ${SWAP_FREE} MB 可用"
log "磁盘 /:   $(df -h / | awk 'NR==2{print $4" 可用 ("$5" 已用)"}')"

# 引擎目标 120MB + SQLite 30MB + 峰值余量 200MB
NEED=400
if (( MEM_AVAIL < NEED )); then
  note_fail "可用内存 ${MEM_AVAIL}MB < 建议 ${NEED}MB。先释放内存或加 swap 再部署。"
else
  ok "内存余量充足（需要 ${NEED}MB，可用 ${MEM_AVAIL}MB）"
fi

if (( SWAP_TOTAL == 0 )); then
  warn "没有 swap。2GB 机器建议配 2GB swap 作为 OOM 缓冲。"
fi

step "2/6  端口占用"
if ss -tlnp 2>/dev/null | grep -q ":${ENGINE_PORT} "; then
  note_fail "端口 ${ENGINE_PORT} 已被占用：$(ss -tlnp | grep ":${ENGINE_PORT} " | head -1)"
else
  ok "端口 ${ENGINE_PORT} 空闲（引擎将绑定 127.0.0.1:${ENGINE_PORT}）"
fi

step "3/6  必需工具"
need_or_note() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1  $(command -v "$1")"
  else
    # Go 和 wrangler 可以后面装，不算致命
    if [[ "$2" == "hard" ]]; then note_fail "缺少 $1（必需）"; else warn "缺少 $1（可自动安装）"; fi
  fi
}
need_or_note curl     hard
need_or_note python3  hard
need_or_note git      hard
need_or_note systemctl hard
need_or_note cloudflared soft
need_or_note node     soft
need_or_note npx      soft
need_or_note go       soft

step "4/6  Cloudflare 凭据与权限"
load_cf_token
PERMS=$(cf_api GET "/user/tokens/verify")
if cf_ok "$PERMS" "token verify"; then
  ok "API Token 有效"
else
  note_fail "API Token 无效或权限不足"
fi

# 逐个探测本项目需要的权限
# ⚠️ CF 返回的是 pretty-printed JSON（键值间有空格），用 grep '"success":true' 会永远匹配不上
#    → 这里用正则容忍空格；判定逻辑与 lib.sh 的 cf_ok 一致
probe() {
  local label="$1" path="$2" mode="${3:-required}" hint="${4:-}"
  if cf_api GET "$path" | grep -qE '"success":[[:space:]]*true'; then
    ok "权限可用: $label"
  elif [[ "$mode" == optional ]]; then
    warn "未开通（可延后，不计入失败）: $label${hint:+   → $hint}"
  else
    warn "权限缺失: $label   → 需要给 token 加对应权限"
    FAIL=$((FAIL+1))
  fi
}
probe "Account→Pages→Edit"            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects"
probe "Account→Workers Scripts→Edit"  "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts"
probe "Account→D1→Edit"               "/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database"
# R2 是 optional：首版不用素材存储。注意 R2 即使加了权限也可能返回 code=10042
#   —— 那是「账号还没开通 R2 服务」（要在 Dashboard 走 checkout），不是权限没加对。
probe "Account→R2→Edit"               "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets" optional "首版不用；要用需先在 Dashboard 开通 R2 服务（走 checkout）"
probe "Account→Workers KV→Edit"       "/accounts/${CLOUDFLARE_ACCOUNT_ID}/storage/kv/namespaces"
probe "Account→Workers AI→Edit"       "/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/models/search?per_page=1"
probe "Account→Vectorize→Edit"        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/vectorize/v2/indexes" optional "v1.1 已改本地暴力余弦，不需要"
probe "Account→Cloudflare Tunnel→Edit" "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false"
probe "Zone→DNS→Edit"                 "/zones?per_page=1"

# Account Analytics→Read：quota-check.sh 靠 GraphQL 拿用量，缺了就看不了额度
#   ⚠️ 日期必须在单引号外插值，否则 "$(date …)" 会被当成字面量 → GraphQL 解析报错 → 误判成权限缺失
TODAY_UTC="$(date -u +%Y-%m-%d)"
GQL='{"query":"query { viewer { accounts(filter: {accountTag: \"'"${CLOUDFLARE_ACCOUNT_ID}"'\"}) { workersInvocationsAdaptive(limit: 1, filter: {date_geq: \"'"${TODAY_UTC}"'\"}) { sum { requests } } } } }"}'
if cf_api POST "/graphql" "$GQL" | grep -qE '"data":[[:space:]]*\{'; then
  ok "权限可用: Account→Account Analytics→Read"
else
  warn "权限缺失: Account→Account Analytics→Read   → quota-check.sh 看额度需要"
  FAIL=$((FAIL+1))
fi

step "5/6  下游 API 可达性"
check_url() {
  local label="$1" url="$2"
  local code
  code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' "$url" 2>/dev/null || echo 000)
  if [[ "$code" == "000" ]]; then
    note_fail "$label 不可达 ($url)"
  else
    ok "$label 可达 (HTTP $code)"
  fi
}
check_url "Cloudflare API"    "https://api.cloudflare.com/client/v4/ips"
check_url "DeepSeek API"      "https://api.deepseek.com"
check_url "Workers AI 端点"   "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/models/search?per_page=1"

if [[ -n "${DEEPSEEK_API_KEY:-}" ]] || grep -q '^DEEPSEEK_API_KEY=' "$HERMES_ENV" 2>/dev/null; then
  ok "DEEPSEEK_API_KEY 已配置"
else
  note_fail "缺少 DEEPSEEK_API_KEY —— 引擎无法生成对话。加到 ~/.hermes/.env"
fi

step "6/6  已有服务影响面"
for s in peer-gateway peer-service cloudflared-peer tailscaled fail2ban; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    ok "$s 运行中（部署后需回归验证）"
  else
    log "$s 未运行"
  fi
done
log "cloudflared 现有 tunnel 配置："
[[ -f "${HOME}/.cloudflared/config.yml" ]] && sed 's/^/       /' "${HOME}/.cloudflared/config.yml" || warn "未找到 ~/.cloudflared/config.yml"

step "结果"
if (( FAIL == 0 )); then
  ok "全部检查通过，可以执行 01-cf-resources.sh"
  exit 0
else
  die "有 ${FAIL} 项需要处理，请先修好再继续。"
fi
