#!/usr/bin/env bash
# deploy/05-tunnel-setup.sh
# 目的：把本机 127.0.0.1:8080 的引擎通过 cloudflared 隧道暴露给 Cloudflare edge。
# 服务器全程不开公网端口 —— 隧道是纯出站连接。
#
# 两种模式（脚本自动判断 + 可手动指定）：
#   A. named  —— 需要有域名托管在 Cloudflare。URL 永久固定，推荐。
#   B. quick  —— 无域名时的选择。URL 每次重启都变，需自动同步到 Worker。
#
# 用法：  ./05-tunnel-setup.sh              # 自动判断
#         ./05-tunnel-setup.sh --mode=quick
#         ./05-tunnel-setup.sh --mode=named --domain=ai.你的域名.com

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cf_token

MODE=""
DOMAIN=""
for arg in "$@"; do
  case "$arg" in
    --mode=*)   MODE="${arg#*=}" ;;
    --domain=*) DOMAIN="${arg#*=}" ;;
    *) die "未知参数：$arg" ;;
  esac
done

step "05  配置隧道暴露"

need_cmd cloudflared "cloudflared 未安装"

# ── 探测：账号里有没有域名 ────────────────────────────────
step "5.1  探测可用模式"
ZONES_RESP=$(cf_api GET "/zones?per_page=50")
ZONE_COUNT=$(printf '%s' "$ZONES_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('result') or []))
" 2>/dev/null || echo 0)

if [[ -z "$MODE" ]]; then
  if (( ZONE_COUNT > 0 )); then
    MODE="named"
    log "账号下有 ${ZONE_COUNT} 个域名 → 使用 named tunnel 模式"
  else
    MODE="quick"
    warn "账号下没有域名 → 只能用 quick tunnel（URL 会变，需自动同步）"
    warn "建议：买一个便宜域名托管到 CF，能把这个问题一次解决。"
  fi
fi

# 确认引擎在跑
if curl -s -o /dev/null -m 5 "http://127.0.0.1:${ENGINE_PORT}/health" 2>/dev/null; then
  ok "引擎在 127.0.0.1:${ENGINE_PORT} 响应正常"
else
  warn "引擎在本机 ${ENGINE_PORT} 无响应（可能代码未就绪）。隧道仍会建好，引擎起来后自动通。"
fi

# ══════════════════════════════════════════ 模式 A：named tunnel
if [[ "$MODE" == "named" ]]; then
  step "5.2  Named tunnel"

  if [[ -z "$DOMAIN" ]]; then
    # 用账号里第一个域名 + 子域约定
    FIRST_ZONE=$(printf '%s' "$ZONES_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin); r = d.get('result') or []
print(r[0]['name'] if r else '')
" 2>/dev/null || true)
    [[ -n "$FIRST_ZONE" ]] || die "无法确定域名，请用 --domain=xxx 指定"
    DOMAIN="ai-town.${FIRST_ZONE}"
    log "未指定 --domain，自动选用：${DOMAIN}"
  fi
  HOSTNAME_ONLY="${DOMAIN#*.}"
  [[ "$DOMAIN" == *.*.* ]] || warn "域名 ${DOMAIN} 看起来不太对，确认一下"

  step "5.2.1  创建/复用 tunnel"
  TUNNELS=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false")
  TUNNEL_ID=$(printf '%s' "$TUNNELS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in (d.get('result') or []):
    if t.get('name') == '${TUNNEL_NAME}':
        print(t['id']); break
" 2>/dev/null || true)

  if [[ -n "$TUNNEL_ID" ]]; then
    ok "tunnel ${TUNNEL_NAME} 已存在 (${TUNNEL_ID})"
  else
    log "创建 tunnel ${TUNNEL_NAME} ..."
    RESP=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
      "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"$(openssl rand -base64 32 | tr -d '\n')\"}")
    TUNNEL_ID=$(printf '%s' "$RESP" | python3 -c "
import sys, json; print((json.load(sys.stdin).get('result') or {}).get('id',''))" 2>/dev/null || true)
    [[ -n "$TUNNEL_ID" ]] && ok "tunnel 创建成功 (${TUNNEL_ID})" || die "创建失败：$(printf '%s' "$RESP" | head -c 300)"
  fi
  save_state "TUNNEL_ID" "$TUNNEL_ID"
  save_state "TUNNEL_DOMAIN" "$DOMAIN"

  step "5.2.2  配置 ingress（独立 tunnel，不与同机其它项目的 ingress 共用）"
  RESP=$(cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"${DOMAIN}\",\"service\":\"http://localhost:${ENGINE_PORT}\"},{\"service\":\"http_status:404\"}]}}")
  cf_ok "$RESP" "ingress 配置" && ok "ingress 已指向 localhost:${ENGINE_PORT}"

  step "5.2.3  创建 DNS 路由（CNAME → tunnel）"
  ZONE_ID=$(printf '%s' "$ZONES_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for z in (d.get('result') or []):
    if '${HOSTNAME_ONLY}' == z['name']:
        print(z['id']); break
" 2>/dev/null || true)
  if [[ -z "$ZONE_ID" ]]; then
    warn "在账号域名列表里找不到 ${HOSTNAME_ONLY}，跳过 DNS 配置"
    warn "手动添加：CNAME ${DOMAIN} → ${TUNNEL_ID}.cfargotunnel.com （必须开橙色云）"
  else
    SUB="${DOMAIN%.${HOSTNAME_ONLY}}"
    DNS_RESP=$(cf_api POST "/zones/${ZONE_ID}/dns_records" \
      "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}")
    if cf_ok "$DNS_RESP" "DNS 记录"; then
      ok "DNS 已创建：${DOMAIN} → ${TUNNEL_ID}.cfargotunnel.com"
    else
      warn "DNS 创建失败（可能已存在）。手动确认一下。"
    fi
  fi

  step "5.2.4  写 connector 凭据 + systemd 服务"
  mkdir -p "${HOME}/.cloudflared"
  TOKEN_RESP=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
  TOKEN=$(printf '%s' "$TOKEN_RESP" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null || true)

  if [[ -z "$TOKEN" ]]; then
    warn "拿不到 tunnel token（token 权限可能缺 Cloudflare Tunnel→Edit），跳过服务安装"
  else
    # 凭据写进独立文件，权限 600
    printf '%s' "$TOKEN" > "${HOME}/.cloudflared/aitown-tunnel-token"
    chmod 600 "${HOME}/.cloudflared/aitown-tunnel-token"
    ok "token 已保存到 ~/.cloudflared/aitown-tunnel-token (600)"

    sudo tee /etc/systemd/system/cloudflared-aitown.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel for AI Town engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
ExecStart=/usr/local/bin/cloudflared tunnel run --token-file ${HOME}/.cloudflared/aitown-tunnel-token
Restart=always
RestartSec=5
# ⚠️ 不要用 quick tunnel 的 --url 参数，token 模式不能同时给 --url
NoNewPrivileges=true
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now cloudflared-aitown
    sleep 6
    if systemctl is-active --quiet cloudflared-aitown; then
      ok "cloudflared-aitown 服务已启动"
    else
      warn "服务未起来，日志："
      sudo journalctl -u cloudflared-aitown -n 20 --no-pager | sed 's/^/       /'
    fi
  fi

  step "5.2.5  外网可达性验证"
  sleep 5
  CODE=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://${DOMAIN}/health" || echo 000)
  log "https://${DOMAIN}/health → HTTP ${CODE}"
  case "$CODE" in
    200) ok "隧道全链路打通！" ;;
    502|503) ok "隧道通了，但引擎还没起来（引擎起来后自动恢复）" ;;
    000) warn "不可达。检查：DNS 是否开橙色云 / ingress hostname 是否匹配 / 凭据文件路径" ;;
    *) warn "返回 ${CODE}，需要排查" ;;
  esac

  save_state "ENGINE_ORIGIN" "https://${DOMAIN}"
  echo
  ok "把下面这行填进 edge 的 ENGINE_ORIGIN（02 脚本会自动读 .state.env）："
  echo "       ENGINE_ORIGIN = \"https://${DOMAIN}\""

# ══════════════════════════════════════════ 模式 B：quick tunnel
else
  step "5.2  Quick tunnel（无域名模式）"
  warn "已知代价：URL 每次重启都会变，必须靠自动同步把新 URL 推给 Worker。"

  cat > "${PROJECT_ROOT}/deploy/quick-tunnel.sh" <<'EOF'
#!/usr/bin/env bash
# quick tunnel 包装脚本：起隧道 + 监听 URL 变化 + 自动同步到 Worker
set -uo pipefail
STATE="$(dirname "$0")/.state.env"
PORT="8080"
LOG_TAG="aitown-quick-tunnel"

get_url_from_state() { grep '^ENGINE_ORIGIN=http' "$STATE" 2>/dev/null | head -1 | cut -d= -f2-; }

sync_url() {
  local url="$1"
  [[ -z "$url" ]] && return
  local old; old="$(get_url_from_state)"
  [[ "$url" == "$old" ]] && return
  echo "[$LOG_TAG] 隧道 URL 变化: $old → $url"
  # 更新 .state.env
  if grep -q '^ENGINE_ORIGIN=' "$STATE" 2>/dev/null; then
    sed -i "s|^ENGINE_ORIGIN=.*|ENGINE_ORIGIN=$url|" "$STATE"
  else
    echo "ENGINE_ORIGIN=$url" >> "$STATE"
  fi
  # 推送到 Worker
  if [[ -f "$(dirname "$0")/../edge/wrangler.toml" ]]; then
    # 单引号拼接写法：这种写法里没有 \" 这类转义，放在（带引号的）heredoc 里最安全。
    # 早先用 \"$url\" 的双引号嵌套，转义在生成时被吃掉了 → sed 表达式坏掉 → URL 漂移后
    # 静默不更新，Worker 一直指着旧隧道（页面表现为永远"重连中"）。
    sed -i 's|^ENGINE_ORIGIN.*|ENGINE_ORIGIN  = "'"$url"'"|' "$(dirname "$0")/../edge/wrangler.toml"
    echo "[$LOG_TAG] 已更新 wrangler.toml → 触发重新部署"
    # ⚠️ 本段处于「带引号的 heredoc」里：必须写成运行时该有的样子，
    #    写 $HOME / ${HOME} —— 写成 \$HOME 会变成字面量 "$HOME"，永远匹配不到
    #    （2026-10-10 实测：CF 凭据没加载 + npx 兜底不生效 → Worker 部署失败）。
    if ! command -v npx >/dev/null 2>&1; then
      for d in "$HOME"/.nvm/versions/node/*/bin; do
        [[ -x "$d/npx" ]] && export PATH="$d:$PATH" && break
      done
    fi
    # systemd 拉起的进程没有 CF 凭据：只挑这两行加载，不整文件 source。
    # 账号 ID / Token 都放本机密钥文件（不进版本库；CI 里走 GitHub Secrets）。
    set -a; source <(grep -E '^(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)=' "${AITOWN_SECRETS_ENV:-${HOME}/.hermes/.env}" 2>/dev/null); set +a
    if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" || -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      echo "[$LOG_TAG] 缺少 CF 凭据（CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN 应在本机密钥文件）→ 跳过 Worker 重部署"
      return
    fi
    REDEPLOY_LOG="$(dirname "$0")/worker-redeploy.log"
    (cd "$(dirname "$0")/../edge" && npx wrangler deploy --config wrangler.toml --name aitown-edge >>"$REDEPLOY_LOG" 2>&1) \
      && echo "[$LOG_TAG] Worker 已重新部署" \
      || echo "[$LOG_TAG] Worker 部署失败，需手动处理（详见 $REDEPLOY_LOG）"
  fi
}

# ⚠️ 必须显式给 --config：cloudflared 默认会读 ~/.cloudflared/config.yml，
# 而那个文件里的 catch-all ingress（指向同机另一个本地服务）会盖掉 --url，
# 于是新 quick tunnel 的全部请求都被转发到 7360（2026-10-10 实测踩到，
# 表现为「URL 通了但返回别人的页面」）。空配置即屏蔽。
CFG="$(dirname "$0")/cloudflared-aitown-empty.yml"
[[ -f "$CFG" ]] || printf '# 空配置：屏蔽 ~/.cloudflared/config.yml 的 ingress\n' > "$CFG"

# 后台跑 cloudflared，同时从输出里抓 URL
cloudflared tunnel --config "$CFG" --url "http://127.0.0.1:${PORT}" --no-autoupdate 2>&1 | \
while IFS= read -r line; do
  echo "$line"
  if [[ "$line" =~ https://[a-z0-9-]+\.trycloudflare\.com ]]; then
    sync_url "${BASH_REMATCH[0]}"
  fi
done
EOF
  chmod +x "${PROJECT_ROOT}/deploy/quick-tunnel.sh"
  ok "已生成 quick-tunnel 包装脚本（含 URL 变化自动同步）"

  sudo tee /etc/systemd/system/cloudflared-aitown.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Quick Tunnel for AI Town engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
ExecStart=${PROJECT_ROOT}/deploy/quick-tunnel.sh
Restart=always
RestartSec=10
NoNewPrivileges=true
# systemd 默认 PATH 里没有 nvm 的 node/npx；缺了它，URL 漂移时的
# `npx wrangler deploy` 会 command not found（2026-10-10 实测），
# 于是「隧道 URL 自动同步」在 systemd 下名存实亡。
Environment=PATH=$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now cloudflared-aitown
  ok "cloudflared-aitown (quick) 已启动"
  echo
  warn "强烈建议：搞个域名走 named 模式。quick tunnel 的 URL 漂移是个长期维护负担。"
fi

step "5.3  确认没影响现有隧道"
if [[ -n "${AITOWN_PEER_SERVICES:-}" ]]; then
  for s in ${AITOWN_PEER_SERVICES}; do
    systemctl is-active --quiet "$s" && ok "$s 仍正常（两条隧道互相独立）" || warn "⚠️ $s 异常，请检查"
  done
else
  log "未指定 AITOWN_PEER_SERVICES，跳过同机服务复查"
fi

echo
ok "下一步：把 ENGINE_ORIGIN 填进 edge 后重跑 02-edge-deploy.sh"
