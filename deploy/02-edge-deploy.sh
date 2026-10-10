#!/usr/bin/env bash
# deploy/02-edge-deploy.sh
# 目的：部署 Cloudflare Workers 边缘网关（鉴权 + 密钥托管 + 资源代理）。
# 幂等：重复跑 = 更新 secrets + 重新部署。
# 前置：01-cf-resources.sh 已跑过（需要资源 ID）；engine 的隧道 URL 已知（见 05）。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cf_token
load_state

step "02  部署 edge 网关"

EDGE_DIR="${PROJECT_ROOT}/edge"
if [[ ! -f "${EDGE_DIR}/src/index.ts" ]]; then
  warn "找不到 ${EDGE_DIR}/src/index.ts —— 业务代码尚未编写（当前 M0 阶段）。"
  echo
  log "本脚本现在只做「能做的部分」：校验资源绑定 + 写入配置模板。"
  log "等 edge 代码就绪后重跑即可，逻辑无需改动。"
  echo
  step "资源绑定自检"
  [[ -n "${D1_DATABASE_ID:-}"      ]] && ok "D1        ${D1_DATABASE_ID}"      || warn "缺 D1_DATABASE_ID"
  [[ -n "${KV_NAMESPACE_ID:-}"     ]] && ok "KV        ${KV_NAMESPACE_ID}"     || warn "缺 KV_NAMESPACE_ID"
  [[ -n "${R2_BUCKET_NAME:-}"      ]] && ok "R2        ${R2_BUCKET_NAME}"      || warn "缺 R2_BUCKET_NAME"
  ok "记忆检索  本地暴力向量（无 Vectorize 依赖）"
  echo
  # R2 未开通时绝不能留 [[r2_buckets]] —— bucket_name 为空会让 wrangler deploy 直接失败
  R2_BLOCK="# R2 未开通：不写 [[r2_buckets]]（空 bucket_name 会让 wrangler deploy 报错）"
  if [[ -n "${R2_BUCKET_NAME:-}" ]]; then
    R2_BLOCK="[[r2_buckets]]
binding     = \"ASSETS_R2\"
bucket_name = \"${R2_BUCKET_NAME}\""
  fi

  log "codegen 出 wrangler.toml（把 ID 填进去）..."
  cat > "${EDGE_DIR}/wrangler.toml" <<EOF
name = "${EDGE_NAME}"
main = "src/index.ts"
compatibility_date = "2026-09-01"
# 需要 nodejs_compat 才能用部分 Node API
compatibility_flags = ["nodejs_compat"]

# ── 静态配置（只读）──────────────────────────────────────
[vars]
VECTOR_BACKEND = "local"
EMBED_DIMS     = "${EMBED_DIMS}"
EMBED_MODEL    = "@cf/baai/bge-m3"
# 引擎隧道地址 —— 有固定域名就写死；用 quick tunnel 则由 06 脚本自动同步
ENGINE_ORIGIN  = "http://127.0.0.1:${ENGINE_PORT}"
# 🩸 铁律：前端只允许走 WebSocket，禁止改成轮询。
#    依据（官方 pricing）：WS 消息经 Worker 转发【不计入】请求数。
#    1 秒轮询 = 86,400 请求/天/观众 → 100,000/天 的免费额度只够 1.1 个观众。
MAX_DAILY_AI_CALLS = "500"

# ── 绑定 ────────────────────────────────────────────────
[[d1_databases]]
binding       = "SHADOW_DB"
database_name = "${D1_NAME}"
database_id   = "${D1_DATABASE_ID}"

[[kv_namespaces]]
binding = "CONFIG_KV"
id      = "${KV_NAMESPACE_ID}"

${R2_BLOCK}

# v1.1: 不再绑定 Vectorize —— 检索在引擎本地做（架构 §5.4.2）

[ai]
binding = "AI"
EOF
  ok "已生成 ${EDGE_DIR}/wrangler.toml"
  echo
  warn "注意：ENGINE_ORIGIN 目前是占位值。真正部署前请填入隧道 URL（05 脚本会输出）。"
  exit 0
fi

# ── 正常部署路径 ─────────────────────────────────────────
cd "$EDGE_DIR"
need_cmd npx "Node.js 未安装"

log "安装依赖 ..."
npm ci --silent 2>/dev/null || npm install --silent

step "写入 Worker secrets（值不会打印）"
put_secret() {
  local name="$1" val="$2"
  if [[ -z "$val" ]]; then warn "跳过 $name（值为空）"; return; fi
  if printf '%s' "$val" | npx wrangler secret put "$name" --name "$EDGE_NAME" >/dev/null 2>&1; then
    ok "secret $name 已设置"
  else
    warn "secret $name 设置失败"
  fi
}

# LLM key 只存在于 Worker，服务器拿不到 —— 引擎通过 edge 的 /api/llm 转发
if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  put_secret DEEPSEEK_API_KEY "$DEEPSEEK_API_KEY"
elif grep -q '^DEEPSEEK_API_KEY=' "$HERMES_ENV" 2>/dev/null; then
  set -a; source <(grep '^DEEPSEEK_API_KEY=' "$HERMES_ENV"); set +a
  put_secret DEEPSEEK_API_KEY "$DEEPSEEK_API_KEY"
else
  warn "未找到 DEEPSEEK_API_KEY，跳过"
fi
put_secret EDGE_SHARED_TOKEN "$(ensure_edge_token >/dev/null 2>&1; printf '%s' "$EDGE_SHARED_TOKEN")"   # 与 engine.env 的 AITOWN_EDGE_TOKEN 同一个值

# ENGINE_ORIGIN 只走 [vars]，不要 put_secret：
# Worker 的同名 secret 会覆盖 var，而 quick tunnel URL 漂移时是靠 sed 改
# wrangler.toml 的 var 自愈的 —— 写成 secret 就永远改不动了。
[[ -n "${ENGINE_ORIGIN:-}" ]] || ENGINE_ORIGIN="$(get_state ENGINE_ORIGIN)"
if [[ -n "${ENGINE_ORIGIN:-}" ]]; then
  log "同步 ENGINE_ORIGIN → wrangler.toml"
  python3 - "${EDGE_DIR}/wrangler.toml" "$ENGINE_ORIGIN" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2]
src = open(path).read()
out = re.sub(r'(?m)^ENGINE_ORIGIN\s*=.*$', 'ENGINE_ORIGIN  = "%s"' % url, src)
open(path, 'w').write(out)
print("ENGINE_ORIGIN 已更新" if out != src else "ENGINE_ORIGIN 无变化")
PY
else
  warn "state 里没有 ENGINE_ORIGIN —— 先跑 05-tunnel-setup.sh，否则 Worker 连不到引擎"
fi

step "部署 Worker"
# ⚠️ 必须显式 --config 指定本目录的 wrangler.toml：仓库根目录还躺着一个
# wrangler.jsonc（name=ai-town、assets 指向 frontend），wrangler 会向上搜到它，
# 于是「以静态资源模式」部署同名 Worker —— 覆盖掉带 bindings 的版本，
# /api/* 全部 404（2026-10-10 实测踩到）。部署日志里会写 "No bindings found."。
if npx wrangler deploy --config "${EDGE_DIR}/wrangler.toml" --name "$EDGE_NAME" 2>&1 | tee /tmp/aitown-edge-deploy.log | tail -20; then
  ok "edge 部署完成"
  grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' /tmp/aitown-edge-deploy.log | head -1 | \
    { read -r u && save_state "EDGE_URL" "$u" && ok "EDGE_URL=$u"; } || true
else
  die "部署失败，日志见 /tmp/aitown-edge-deploy.log"
fi

step "冒烟测试"
EDGE_URL="${EDGE_URL:-$(get_state EDGE_URL)}"
if [[ -n "$EDGE_URL" ]]; then
  CODE=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${EDGE_URL}/api/health" || echo 000)
  log "GET ${EDGE_URL}/api/health → HTTP ${CODE}"
  [[ "$CODE" == "200" ]] && ok "edge 健康检查通过" || warn "健康检查未通过（若引擎未部署，这是预期的）"
fi

ok "下一步：03-engine-install.sh"
