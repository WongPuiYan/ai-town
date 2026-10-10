#!/usr/bin/env bash
# deploy/01-cf-resources.sh
# 目的：在 Cloudflare 免费档创建本项目需要的全部资源（幂等，已存在则复用）。
#   1. D1 数据库       aitown-shadow   —— 冷查询影子库
#   2. R2 桶           aitown-assets   —— 地图瓦片 / 精灵图 / 音效
#   3. KV 命名空间     aitown-config   —— 只读配置（绝不存实时状态）
# 所有 ID 写入 deploy/.state.env，供后续脚本复用。
# 不创建：Durable Objects（不需要 —— 见架构 §3.2）、Queues（用不上）。
# 不创建：Vectorize —— v1.1 已改为 Go 本地暴力向量检索（架构 §5.4.2）。
#         需要旧方案：export AITOWN_USE_VECTORIZE=1 后重跑本脚本。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_cf_token
step "01  Cloudflare 资源创建"

# ---------------------------------------------------------------- Vectorize
# v1.1（2026-09-30）：默认【跳过】。理由见 docs/ARCHITECTURE.md §5.4.2 ——
# 本镇向量规模约 4,000 条，Go 本地暴力余弦 2-4ms 就够，
# 用 Vectorize 反倒被 5M 存储维度 / 30M 查询维度 的免费配额卡住。
if [[ "${USE_VECTORIZE}" != "1" ]]; then
  step "Vectorize —— 已按 v1.1 决策跳过"
  log "记忆检索改在引擎本地做：SQLite BLOB(float32) + 暴力余弦，无配额、无网络往返"
  log "如需恢复旧方案：export AITOWN_USE_VECTORIZE=1 后重跑本脚本"
  save_state "VECTOR_BACKEND" "local"
  save_state "EMBED_DIMS" "$EMBED_DIMS"
else
step "Vectorize 索引（记忆检索 · 旧方案）"
VEC_EXISTING=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/vectorize/v2/indexes")
VEC_ID=$(printf '%s' "$VEC_EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i in (d.get('result') or []):
    if i.get('name') == '${VECTOR_INDEX}':
        print(i.get('name')); break
" 2>/dev/null || true)

if [[ -n "$VEC_ID" ]]; then
  ok "索引 ${VECTOR_INDEX} 已存在，复用"
else
  log "创建索引 ${VECTOR_INDEX}（${EMBED_DIMS} 维 / cosine / 32bit）..."
  RESP=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/vectorize/v2/indexes" \
    "{\"name\":\"${VECTOR_INDEX}\",\"description\":\"AI Town agent memory index\",\"config\":{\"dimensions\":${EMBED_DIMS},\"metric\":\"cosine\"}}")
  if cf_ok "$RESP" "创建 Vectorize 索引"; then
    ok "索引 ${VECTOR_INDEX} 创建成功"
  else
    warn "创建失败，检查 token 是否有 Vectorize 权限（Account→Vectorize→Edit）"
  fi
fi
save_state "VECTOR_INDEX_NAME" "$VECTOR_INDEX"
save_state "VECTOR_BACKEND" "vectorize"

# 免费额度速算，防止设计跑偏
python3 - "$EMBED_DIMS" <<'PY'
import sys
dims = int(sys.argv[1])
stored, queried = 5_000_000, 30_000_000
print(f"       免费存储容量: {stored // dims:,} 条向量")
print(f"       免费查询额度: {queried // dims:,} 次/月  ≈ {queried // dims // 30:,} 次/天")
print(f"       设计目标    : 8 人 × 500 条 = 4,000 条（占存储 {(4000*dims*100)//stored}%）")
PY
save_state "EMBED_DIMS" "$EMBED_DIMS"
fi

# ---------------------------------------------------------------------- D1
step "D1 数据库（影子库）"
D1_RESP=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database")
D1_UUID=$(printf '%s' "$D1_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for x in (d.get('result') or []):
    if x.get('name') == '${D1_NAME}':
        print(x.get('uuid')); break
" 2>/dev/null || true)

if [[ -n "$D1_UUID" ]]; then
  ok "D1 ${D1_NAME} 已存在 (${D1_UUID})"
else
  log "创建 D1 ${D1_NAME} ..."
  RESP=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database" "{\"name\":\"${D1_NAME}\"}")
  D1_UUID=$(printf '%s' "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('result') or {}
print(r.get('uuid', ''))
" 2>/dev/null || true)
  if [[ -n "$D1_UUID" ]]; then
    ok "D1 创建成功 (${D1_UUID})"
  else
    warn "D1 创建失败：$(printf '%s' "$RESP" | head -c 300)"
  fi
fi
[[ -n "$D1_UUID" ]] && save_state "D1_DATABASE_ID" "$D1_UUID"

# 建影子表（只需 3 张，只同步冷数据）
if [[ -n "$D1_UUID" ]]; then
  log "初始化影子表结构 ..."
  SCHEMA=$(cat <<'SQL'
CREATE TABLE IF NOT EXISTS agents (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, persona TEXT,
  home_x INTEGER, home_y INTEGER, synced_at INTEGER
);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY, tick INTEGER NOT NULL, agent_id TEXT NOT NULL,
  type TEXT NOT NULL, payload_json TEXT, importance INTEGER DEFAULT 0,
  game_day INTEGER, created_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_events_tick    ON events(tick DESC);
CREATE INDEX IF NOT EXISTS idx_events_day     ON events(game_day DESC, agent_id);
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY, tick INTEGER, a_id TEXT, b_id TEXT,
  transcript_json TEXT, game_day INTEGER, created_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_conv_day ON conversations(game_day DESC);
SQL
)
  # D1 不支持一次多语句 DDL，逐条执行。
  # ⚠️ 必须按「分号」切语句，不能按「行」切 —— 否则每个多行 CREATE TABLE 都会被拆散，
  #    首行报 incomplete input、后续行报 near "xxx": syntax error（2026-10-10 实测踩过）。
  STMT=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue          # 空行
    [[ "$line" =~ ^[[:space:]]*-- ]] && continue         # 注释
    STMT+="${line}"$'\n'
    if [[ "$line" == *";" ]]; then                       # 语句结束
      SQL=$(printf '%s' "$STMT" | tr '\n' ' ')
      STMT=""
      R=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database/${D1_UUID}/query" \
        "$(python3 -c 'import json,sys; print(json.dumps({"sql": sys.argv[1]}))' "$SQL")")
      if printf '%s' "$R" | grep -qE '"success":[[:space:]]*true'; then
        ok "  ✓ ${SQL:0:60}..."
      else
        warn "  ✗ ${SQL:0:60}...  $(printf '%s' "$R" | head -c 200)"
      fi
    fi
  done <<< "$SCHEMA"
  # 收尾：最后一条若忘了写分号也要执行
  if [[ -n "${STMT//[[:space:]]/}" ]]; then
    SQL=$(printf '%s' "$STMT" | tr '\n' ' ')
    R=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database/${D1_UUID}/query" \
      "$(python3 -c 'import json,sys; print(json.dumps({"sql": sys.argv[1]}))' "$SQL")")
    printf '%s' "$R" | grep -qE '"success":[[:space:]]*true' && ok "  ✓ ${SQL:0:60}..." || warn "  ✗ ${SQL:0:60}..."
  fi
fi

# ---------------------------------------------------------------------- R2
# ⚠️ R2 是可选资源（首版不用素材存储）。两种「用不了」要区分清楚，别混成「权限没加对」：
#    code=10042 → 账号还没开通 R2 服务（要在 Dashboard 走 checkout 开通），光加 token 权限没用
#    其它错误   → 才是权限/参数问题
# ⚠️ CF 返回的是 pretty JSON（键值间有空格），判断「桶是否存在」不能写死 "\"name\":\"x\""
step "R2 桶（素材，可选）"
R2_RESP=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets")
if printf '%s' "$R2_RESP" | grep -qE "\"name\":[[:space:]]*\"${R2_NAME}\""; then
  ok "R2 桶 ${R2_NAME} 已存在"
  save_state "R2_BUCKET_NAME" "$R2_NAME"
elif printf '%s' "$R2_RESP" | grep -q '10042'; then
  warn "跳过：账号尚未开通 R2 服务（code=10042）"
  log "  要用素材存储时：Dashboard → Storage & databases → R2 → 走 checkout 开通，再重跑本脚本即可"
  log "  首版（M1 心跳/血管）不需要 R2，跳过不影响后续步骤"
elif ! printf '%s' "$R2_RESP" | grep -qE '"success":[[:space:]]*true'; then
  warn "跳过：读不到 R2 列表（token 可能仍缺 R2→Edit），其它资源不受影响"
else
  log "创建 R2 桶 ${R2_NAME} ..."
  RESP=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets" "{\"name\":\"${R2_NAME}\"}")
  if cf_ok "$RESP" "创建 R2 桶"; then ok "R2 桶创建成功"; save_state "R2_BUCKET_NAME" "$R2_NAME"; else warn "创建失败，检查 R2 权限"; fi
fi

# ---------------------------------------------------------------------- KV
step "KV 命名空间（只读配置）"
KV_RESP=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
KV_ID=$(printf '%s' "$KV_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for n in (d.get('result') or []):
    if n.get('title') == '${KV_NAME}':
        print(n.get('id')); break
" 2>/dev/null || true)

if [[ -n "$KV_ID" ]]; then
  ok "KV ${KV_NAME} 已存在 (${KV_ID})"
else
  log "创建 KV ${KV_NAME} ..."
  RESP=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/storage/kv/namespaces" "{\"title\":\"${KV_NAME}\"}")
  KV_ID=$(printf '%s' "$RESP" | python3 -c "
import sys, json
print((json.load(sys.stdin).get('result') or {}).get('id',''))
" 2>/dev/null || true)
  [[ -n "$KV_ID" ]] && ok "KV 创建成功 (${KV_ID})" || warn "KV 创建失败"
fi
[[ -n "$KV_ID" ]] && save_state "KV_NAMESPACE_ID" "$KV_ID"
warn "铁律：KV 免费档每天只有 1,000 次写入。只存配置，绝不存 tick 状态。"

# --------------------------------------------------------------------- 汇总
step "资源汇总（已写入 deploy/.state.env）"
sed 's/^/       /' "$STATE_FILE" 2>/dev/null || warn "状态文件为空"
echo
ok "下一步：02-edge-deploy.sh"
