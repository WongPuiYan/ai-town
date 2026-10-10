#!/usr/bin/env bash
# deploy/04-frontend-deploy.sh
# 目的：把 PixiJS 前端部署到 Cloudflare Pages。
# 幂等：重复跑 = 重新构建 + 重新部署。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cf_token
load_state

FE_DIR="${PROJECT_ROOT}/frontend"

step "04  部署前端到 Cloudflare Pages"

if [[ ! -f "${FE_DIR}/package.json" ]]; then
  warn "找不到 ${FE_DIR}/package.json —— 前端代码尚未编写（当前 M0 阶段）。"
  echo
  log "占位页部署选项：可以先部署一个占位页把 Pages 项目建起来，"
  log "这样域名/CI 都能提前打通。要这样做的话跑："
  echo "       $0 --placeholder"
  exit 0
fi

cd "$FE_DIR"
need_cmd npx "Node.js 未安装"
export CLOUDFLARE_ACCOUNT_ID

# 页面和 Worker 不在同一个域（Pages 在 *.pages.dev，Worker 在 *.workers.dev），
# 所以 Worker 地址必须在【构建时】烧进前端包，否则页面会去连 pages.dev/ws 然后一直重连。
EDGE_URL="${EDGE_URL:-$(get_state EDGE_URL)}"
[[ -n "$EDGE_URL" ]] || die "state 里没有 EDGE_URL —— 先跑 02-edge-deploy.sh，否则页面连不上引擎"
export VITE_EDGE_URL="$EDGE_URL"
ok "前端将连接 edge：${VITE_EDGE_URL}"

log "安装依赖 ..."
npm ci --silent 2>/dev/null || npm install --silent

log "构建 ..."
npm run build 2>&1 | tail -15

DIST=""
for c in dist build out; do
  [[ -d "${FE_DIR}/${c}" ]] && DIST="${FE_DIR}/${c}" && break
done
[[ -n "$DIST" ]] || die "构建产物目录不存在（找过 dist/build/out）"
ok "构建产物：${DIST} ($(du -sh "$DIST" | cut -f1))"

# 部署前自检：别把密钥打进前端
step "4.1  构建产物安全扫描"
if grep -rlE '(sk-[a-zA-Z0-9]{20,}|CLOUDFLARE_API_TOKEN|DEEPSEEK_API_KEY=[^ ])' "$DIST" 2>/dev/null | head -5 | grep -q .; then
  warn "⚠️ 构建产物里疑似有密钥，请检查后再部署："
  grep -rlE '(sk-[a-zA-Z0-9]{20,}|CLOUDFLARE_API_TOKEN|DEEPSEEK_API_KEY=[^ ])' "$DIST" 2>/dev/null | head -5 | sed 's/^/       /'
  die "已中止部署"
fi
ok "未发现泄漏的密钥"

step "4.2  部署"
if npx wrangler pages deploy "$DIST" --project-name "$PAGES_NAME" --branch main 2>&1 | tee /tmp/aitown-pages.log | tail -12; then
  ok "Pages 部署完成"
  URL=$(grep -oE 'https://[a-zA-Z0-9._-]+\.pages\.dev' /tmp/aitown-pages.log | tail -1)
  [[ -n "$URL" ]] && save_state "PAGES_URL" "$URL" && log "本次部署地址: $URL"
  # ⚠️ 别假设生产域名 = ${PAGES_NAME}.pages.dev：项目名全局唯一，wrangler 会给真实域名加后缀
  # （本项目实为 ai-town-cbn.pages.dev）。而 ai-town.pages.dev 是【别人的】项目 —— 拿它当自己会 200 假通过。
  ok "真实生产地址由 4.3 冒烟测试探明并写入 PAGES_HOST"
else
  die "部署失败，日志 /tmp/aitown-pages.log"
fi

step "4.3  冒烟测试"
sleep 8
# 逐个候选域名试：必须 HTTP 200 且页面标题含 "AI Town"，否则就是撞名的陌生项目（假通过）。
CANDIDATES=()
DEPLOYED_HOST="$(grep -oE '[a-zA-Z0-9._-]+\.pages\.dev' /tmp/aitown-pages.log | tail -1)"
if [[ -n "$DEPLOYED_HOST" ]]; then
  CANDIDATES+=("$DEPLOYED_HOST")
  CANDIDATES+=("${DEPLOYED_HOST#*.}")   # <hash>.ai-town-cbn.pages.dev → ai-town-cbn.pages.dev（生产别名）
fi
maybe="$(get_state PAGES_HOST 2>/dev/null || true)"
[[ -n "$maybe" ]] && CANDIDATES+=("$maybe")
for host in "${CANDIDATES[@]}"; do
  [[ -n "$host" ]] || continue
  BODY="$(curl -s -m 15 "https://${host}" || true)"
  CODE="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://${host}" || echo 000)"
  if [[ "$CODE" == "200" && "$BODY" == *"AI Town"* ]]; then
    save_state "PAGES_HOST" "$host"
    ok "前端可访问：https://${host}"
    break
  fi
  warn "https://${host} → HTTP ${CODE}（内容不匹配已跳过）"
done
