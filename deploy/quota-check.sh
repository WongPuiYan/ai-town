#!/usr/bin/env bash
# deploy/quota-check.sh
# 目的：一屏看清 Cloudflare 免费额度的「消耗 / 上限 / 剩余」。
# 为什么需要它：本项目架构完全建立在免费额度边界上，一旦某项越界就会静默失败。
#               这个脚本是唯一的预警机制 —— 建议挂成 cron 每日跑。
#
# 用法：  ./quota-check.sh           # 人类可读
#         ./quota-check.sh --json    # 机器可读（给 cron / 告警用）

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cf_token

JSON_OUT=0
[[ "${1:-}" == "--json" ]] && JSON_OUT=1

# 注意：EMBED_DIMS 由 lib.sh 以 readonly 定义（bge-m3 = 1024），这里不能再赋值，
#       否则 set -e 下会因「readonly variable」直接中止整个脚本。
WORKERS_REQ_FREE=100000        # /天
AI_NEURONS_FREE=10000          # /天
VEC_QUERY_FREE=30000000        # /月
VEC_STORE_FREE=5000000         # 维度
D1_READ_FREE=5000000           # /天
D1_WRITE_FREE=100000           # /天
KV_READ_FREE=100000            # /天
KV_WRITE_FREE=1000             # /天
R2_STORE_FREE=$((10*1024*1024*1024))  # 10 GB (bytes)

# ── GraphQL Analytics：拿过去 24h 的实际用量 ──────────────
gql() {
  local query="$1"
  curl -sS -m 30 "https://api.cloudflare.com/client/v4/graphql" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$query")"
}

# 进度条 —— 交给 python 画，避免 set -e 下 seq 空序列的坑
bar() {
  python3 - "$1" "$2" 28 <<'PY'
import sys
used, total, width = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
if total <= 0:
    print("░" * width + "   0%"); raise SystemExit
pct = used * 100 // total
filled = max(0, min(width, used * width // total))
print("█" * filled + "░" * (width - filled) + f" {pct:3d}%")
PY
}

row() { printf '  %-22s %-34s %12s / %-12s\n' "$1" "$(bar "$2" "$3")" "$2" "$3"; }

step "Cloudflare 免费额度使用情况  ($(date '+%Y-%m-%d %H:%M'))"
log "所有免费额度在 00:00 UTC 重置（北京时间 08:00）"

# ── Vectorize：v1.1 后本项目不再使用（改 Go 本地暴力向量检索）──
if [[ "${VECTOR_BACKEND:-local}" == "local" ]]; then
  step "Vectorize —— 本项目已不使用（v1.1 决策）"
  log "记忆检索在引擎本地做：SQLite BLOB(float32) + 暴力余弦，无配额可查"
  log "向量规模 ≈ 4,000 条 × ${EMBED_DIMS} 维 ≈ 16 MB 常驻内存"
  log "唯一相关额度是 embedding 计算：Workers AI 10,000 neurons/天（实耗 <1%）"
else
  step "Vectorize（记忆检索 · 旧方案）"
  VINFO=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/vectorize/v2/indexes/${VECTOR_INDEX}")
  VECTORS=$(printf '%s' "$VINFO" | python3 -c "
import sys, json
d = json.load(sys.stdin); r = d.get('result') or {}
print(r.get('vectorsCount') or r.get('vectors_count') or 0)
" 2>/dev/null || echo 0)
  STORED_DIMS=$(( VECTORS * EMBED_DIMS ))
  VEC_CAP=$(( VEC_STORE_FREE / EMBED_DIMS ))
  QUERY_CAP=$(( VEC_QUERY_FREE / EMBED_DIMS ))

  row "存储向量数"     "$VECTORS" "$VEC_CAP"
  row "存储维度"       "$STORED_DIMS" "$VEC_STORE_FREE"
  echo "       查询额度上限：${QUERY_CAP} 次/月 ≈ $(( QUERY_CAP / 30 )) 次/天（按 ${EMBED_DIMS} 维）"
  if (( STORED_DIMS > VEC_STORE_FREE * 80 / 100 )); then
    warn "存储已用超 80% —— 淘汰策略该跑了（observation 滚动淘汰 / reflection 合并）"
  fi
  if (( VECTORS > VEC_CAP )); then
    warn "⚠️ 接近或已超存储上限！新增记忆的向量化会失败。"
  fi
fi

# ── Workers 请求 ─────────────────────────────────────────
step "Workers 请求（过去 24h）"
Q='{ "query": "query { viewer { accounts(filter: {accountTag: \"'"$CLOUDFLARE_ACCOUNT_ID"'\"}) { workersInvocationsAdaptive(limit: 100, filter: {date_geq: \"'"$(date -u -d '24 hours ago' +%Y-%m-%d 2>/dev/null || date -u -v-24H +%Y-%m-%d)"'\", date_leq: \"'"$(date -u +%Y-%m-%d)"'\"}) { sum { requests errors } dimensions { scriptName } } } } }" }'
WRESP=$(gql "$Q" 2>/dev/null || echo '{}')
printf '%s' "$WRESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    accts = (d.get('data') or {}).get('viewer', {}).get('accounts') or []
    total = 0
    for a in accts:
        for w in (a.get('workersInvocationsAdaptive') or []):
            n = w['sum']['requests']; total += n
            print(f\"       {w['dimensions'].get('scriptName','?'):<28} {n:>10,} 次  错误 {w['sum']['errors']:,}\")
    print(f'  {\"合计\":<22} {\"\":<34} {total:>12,} / {100000} 次')
    pct = total * 100 // 100000
    if pct > 70: print(f'       ⚠️ 已用 {pct}%，注意前端轮询频率')
    else: print(f'       已用 {pct}%')
except Exception as e:
    print('       （GraphQL 查询不可用，跳过）')
" 2>/dev/null || echo "       （解析失败，跳过）"

# ── Workers AI 神经元 ────────────────────────────────────
step "Workers AI 神经元（embedding 用）"
NEU_Q='{ "query": "query { viewer { accounts(filter: {accountTag: \"'"$CLOUDFLARE_ACCOUNT_ID"'\"}) { aiInferenceAdaptive(limit: 50, filter: {date_geq: \"'"$(date -u +%Y-%m-%d)"'\"}) { sum { totalNeurons totalRequests } dimensions { modelId } } } } } }" }'
NRESP=$(gql "$NEU_Q" 2>/dev/null || echo '{}')
printf '%s' "$NRESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    accts = (d.get('data') or {}).get('viewer', {}).get('accounts') or []
    total = 0
    for a in accts:
        for m in (a.get('aiInferenceAdaptive') or []):
            n = m['sum'].get('totalNeurons') or 0; total += n
            print(f\"       {m['dimensions'].get('modelId','?'):<40} {n:>10,.0f} neurons\")
    print(f'  {\"合计\":<22} {\"\":<34} {total:>12,.0f} / {10000} neurons')
    pct = total * 100 // 10000
    print(f'       已用 {pct}%   —— embedding 是最省额度的用法，正常应该 <5%')
    if pct > 50: print('       ⚠️ 检查是否误把 LLM 也接到了 Workers AI（那是烧额度最快的做法）')
except Exception:
    print('       （GraphQL 查询不可用，跳过）')
" 2>/dev/null || echo "       （解析失败，跳过）"

# ── D1 ───────────────────────────────────────────────────
step "D1（影子库）"
D1_ID=$(get_state D1_DATABASE_ID 2>/dev/null || true)
if [[ -n "${D1_ID:-}" ]]; then
  D1_Q='{ "query": "query { viewer { accounts(filter: {accountTag: \"'"$CLOUDFLARE_ACCOUNT_ID"'\"}) { d1AnalyticsAdaptiveGroups(limit: 10, filter: {date_geq: \"'"$(date -u +%Y-%m-%d)"'\", databaseId: \"'"$D1_ID"'\"}) { sum { rowsRead rowsWritten } } } } }" }'
  D1RESP=$(gql "$D1_Q" 2>/dev/null || echo '{}')
  printf '%s' "$D1RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    accts = (d.get('data') or {}).get('viewer', {}).get('accounts') or []
    reads = writes = 0
    for a in accts:
        for g in (a.get('d1AnalyticsAdaptiveGroups') or []):
            reads += g['sum'].get('rowsRead') or 0
            writes += g['sum'].get('rowsWritten') or 0
    print(f'  行读取               {reads:>12,} / {5000000:,} 行/天')
    print(f'  行写入               {writes:>12,} / {100000:,} 行/天')
    wpct = writes * 100 // 100000
    print(f'  写入已用 {wpct}%')
    if wpct > 50:
        print('       ⚠️ D1 写入偏高！确认引擎没有把 tick 级状态同步到 D1（应只在游戏日边界同步）')
except Exception:
    print('       （GraphQL 查询不可用，跳过）')
" 2>/dev/null || echo "       （解析失败，跳过）"
else
  warn "未找到 D1_DATABASE_ID（先跑 01-cf-resources.sh）"
fi

# ── R2 ───────────────────────────────────────────────────
step "R2（素材）"
R2_BUCKET="${R2_BUCKET_NAME:-${R2_NAME:-aitown-assets}}"
R2INFO=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${R2_BUCKET}/usage" 2>/dev/null || echo '{}')
printf '%s' "$R2INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin); r = d.get('result') or {}
    payload = r.get('payloadSize') or r.get('storage') or 0
    print(f'  存储                 {payload/1024/1024:>10.1f} MB / {10*1024:.0f} MB (免费 10GB)')
    print(f'  已用 {payload*100//(10*1024*1024*1024)}%')
except Exception:
    print('       （用量接口不可用，免费档正常 —— 10GB 对素材包绰绰有余）')
" 2>/dev/null || true

# ── 服务器侧 ─────────────────────────────────────────────
step "服务器（本机）"
if systemctl is-active --quiet aitown-engine 2>/dev/null; then
  MEM_B=$(systemctl show aitown-engine -p MemoryCurrent --value 2>/dev/null || echo 0)
  CPU_NS=$(systemctl show aitown-engine -p CPUUsageNSec --value 2>/dev/null || echo 0)
  [[ "$MEM_B" == "[not set]" ]] && MEM_B=0
  printf '  %-22s %12s MB  (上限 600 MB)\n' "引擎内存" "$(( MEM_B / 1024 / 1024 ))"
  printf '  %-22s %12s s\n' "引擎 CPU 累计" "$(( CPU_NS / 1000000000 ))"
  if (( MEM_B > 400*1024*1024 )); then warn "引擎内存超 400MB，已进入 MemoryHigh 节流区"; fi
else
  log "  aitown-engine 未运行"
fi
printf '  %-22s %12s MB\n' "整机已用内存" "$(free -m | awk '/Mem:/{print $3}')"
printf '  %-22s %12s MB\n' "整机可用内存" "$(free -m | awk '/Mem:/{print $7}')"
printf '  %-22s %12s\n'   "磁盘可用"     "$(df -h / | awk 'NR==2{print $4}')"

# ── 预算表 ───────────────────────────────────────────────
step "免费额度红线速查（架构红线，不可越）"
cat <<'EOF'
  Workers CPU        10 ms/次        → edge 层只准转发，禁止加计算逻辑
  Workers KV 写入     1,000/天        → 只存配置；引擎写路径物理上不接 KV
  Durable Objects    13,000 GB-s/天 → 不用：与服务器引擎职责重复（非用不起，架构 §5.4.3）
  🩸 Workers 请求     100,000/天      → 【禁止轮询】1秒轮询=86,400/天/观众 → 1个观众吃掉86%，2个就爆
  Workers AI          10,000 neurons/天 → 只给 embedding，实耗 <1%
  D1 行写入           100,000/天      → 只在游戏日边界同步快照
  Vectorize           已不使用        → v1.1 改本地暴力检索，无配额
  Pages               请求带宽无上限   → 前端可以放心用
EOF
echo
ok "额度检查完成"
