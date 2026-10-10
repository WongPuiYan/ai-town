#!/usr/bin/env bash
# deploy/lib.sh — 公共函数库（所有 deploy 脚本 source 这个文件）
# 注意：本文件不会打印任何密钥值。

set -euo pipefail

# ---------- 常量 ----------
readonly CF_ACCOUNT_ID_DEFAULT="<cf-account-id>"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly STATE_FILE="${PROJECT_ROOT}/deploy/.state.env"
readonly HERMES_ENV="${HOME}/.hermes/.env"

readonly ENGINE_PORT="8080"
readonly EDGE_NAME="aitown-edge"
readonly PAGES_NAME="ai-town"
readonly D1_NAME="aitown-shadow"
readonly R2_NAME="aitown-assets"
readonly KV_NAME="aitown-config"
readonly TUNNEL_NAME="aitown-engine"

# ── v1.1 决策（2026-09-30）：默认【不】使用 Vectorize ──────────────
# 依据 docs/ARCHITECTURE.md §5.4.2：
#   · 本镇向量规模仅几千条，Go 本地暴力余弦只要 2-4ms
#   · Vectorize 免费档 5M 存储维度 = 只够 4,882 条 (1024维)，反而成了硬墙
#   · 且官方文档对「Free 档能否用 Vectorize」自相矛盾，无法从文档确认
# 想回到旧方案：export AITOWN_USE_VECTORIZE=1
readonly VECTOR_INDEX="aitown-memory"                  # legacy，默认不创建
readonly USE_VECTORIZE="${AITOWN_USE_VECTORIZE:-0}"

# bge-m3 输出维度（embedding 仍走 Workers AI，免费额度实耗 <1%）
readonly EMBED_DIMS="1024"

# ---------- 输出 ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

log()  { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
step() { printf '\n%s══ %s ══%s\n' "$C_BLU" "$*" "$C_OFF"; }

# ---------- 凭据 ----------
# 优先级：已导出的环境变量 > ~/.hermes/.env
# 绝不 echo 出 token 本身
load_cf_token() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    ok "CLOUDFLARE_API_TOKEN 来自当前环境"
  elif [[ -f "$HERMES_ENV" ]] && grep -q '^CLOUDFLARE_API_TOKEN=' "$HERMES_ENV"; then
    # shellcheck disable=SC1090
    set -a; source <(grep -E '^(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)=' "$HERMES_ENV"); set +a
    ok "CLOUDFLARE_API_TOKEN 来自 ~/.hermes/.env"
  else
    die "找不到 CLOUDFLARE_API_TOKEN。请执行：echo 'CLOUDFLARE_API_TOKEN=xxx' >> ~/.hermes/.env"
  fi
  export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$CF_ACCOUNT_ID_DEFAULT}"
  log "Account ID: ${CLOUDFLARE_ACCOUNT_ID}"
}

# ---------- CF API ----------
# cf_api METHOD PATH [JSON_BODY]  → stdout 为响应体
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="https://api.cloudflare.com/client/v4${path}"
  if [[ -n "$body" ]]; then
    curl -sS -m 30 -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -m 30 -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

# 判断 CF 响应是否成功；失败时打印 errors
cf_ok() {
  local resp="$1" what="$2"
  local success
  success=$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("success",False))' 2>/dev/null || echo False)
  if [[ "$success" != "True" ]]; then
    local errs
    errs=$(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get("errors",[]),ensure_ascii=False))' 2>/dev/null || echo "$resp")
    warn "$what 失败: $errs"
    return 1
  fi
  return 0
}

# ---------- 状态文件 ----------
# 保存创建出来的资源 ID，供后续脚本复用（幂等的关键）
save_state() {
  local key="$1" val="$2"
  # 绝不把 lib.sh 里 readonly 的键写进状态文件：以后 load_state source 它会因为
  # 「readonly variable」把脚本直接打死（曾经真实踩过）
  if declare -p "$key" 2>/dev/null | grep -qE '^declare -[A-Za-z]*r'; then
    warn "跳过 $key（lib.sh 已 readonly 定义，不该写进状态文件）"
    return 0
  fi
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    # 用 python 做原地替换，避免 sed 的转义坑
    python3 - "$STATE_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out, seen = [], False
for ln in lines:
    if ln.startswith(key + "="):
        out.append(f"{key}={val}"); seen = True
    else:
        out.append(ln)
if not seen:
    out.append(f"{key}={val}")
open(path, "w").write("\n".join(out) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$STATE_FILE"
  fi
  ok "已记录 $key"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "找不到 $STATE_FILE —— 请先跑 01-cf-resources.sh"
  # 逐行 export，跳过 lib.sh 已 readonly 定义的键。
  # 直接 `source` 会在遇到 readonly 键时打印错误并终止脚本（历史 bug）。
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    local key="${line%%=*}"
    if declare -p "$key" 2>/dev/null | grep -qE '^declare -[A-Za-z]*r'; then
      warn "状态文件里的 $key 与 lib.sh 的 readonly 定义冲突，已忽略"
      continue
    fi
    export "$line"
  done < "$STATE_FILE"
}

has_state() { [[ -f "$STATE_FILE" ]] && grep -q "^$1=" "$STATE_FILE"; }
get_state() { grep "^$1=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---------- 引擎 ↔ edge 共享口令 ----------
# 单一真相源：engine.env 里的 AITOWN_EDGE_TOKEN（引擎启动时读它）。
# .state.env 只做镜像，方便脚本之间传递。
# 为什么必须有这个函数：02 曾经自己 `openssl rand` 造一个口令塞给 Worker，
# 而引擎从没拿到过它 → Worker 转发时带的 X-Edge-Token 与引擎期望值永不相等。
ensure_edge_token() {
  local env_file="${PROJECT_ROOT}/engine.env"
  local tok=""
  if [[ -f "$env_file" ]]; then
    tok="$(grep -E '^AITOWN_EDGE_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)"
  fi
  [[ -n "$tok" ]] || tok="${EDGE_SHARED_TOKEN:-}"
  if [[ -z "$tok" ]]; then
    tok="$(openssl rand -hex 24)"
    if [[ -f "$env_file" ]]; then
      printf 'AITOWN_EDGE_TOKEN=%s\n' "$tok" >> "$env_file"
      chmod 600 "$env_file"
    fi
  fi
  export EDGE_SHARED_TOKEN="$tok"
  save_state "EDGE_SHARED_TOKEN" "$tok" >/dev/null 2>&1 || true
}


# ---------- 前置检查 ----------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1（$2）"
}
