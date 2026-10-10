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
    # systemd 拉起的进程没有 CF 凭据：只挑这两行加载，不整文件 source
    export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-<cf-account-id>}"
    set -a; source <(grep -E '^(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)=' "${HOME}/.hermes/.env" 2>/dev/null); set +a
    REDEPLOY_LOG="$(dirname "$0")/worker-redeploy.log"
    (cd "$(dirname "$0")/../edge" && npx wrangler deploy --config wrangler.toml --name aitown-edge >>"$REDEPLOY_LOG" 2>&1) \
      && echo "[$LOG_TAG] Worker 已重新部署" \
      || echo "[$LOG_TAG] Worker 部署失败，需手动处理（详见 $REDEPLOY_LOG）"
  fi
}

# ⚠️ 必须显式给 --config：cloudflared 默认会读 ~/.cloudflared/config.yml，
# 而那个文件里的 ingress（peer-service → 127.0.0.1:7360）会盖掉 --url，
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
