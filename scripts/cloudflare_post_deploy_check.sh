#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
用法：
  bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN

也可以设置环境变量：
  WORKER_URL="https://你的-worker地址" RUN_TOKEN="你的RUN_TOKEN" bash scripts/cloudflare_post_deploy_check.sh

说明：
  该检查不会投递真实任务，只确认健康接口、Queue 绑定、Cron 映射、RUN_TOKEN 和 Cookie Secret 基础状态。
EOF
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

WORKER_URL="${1:-${WORKER_URL:-}}"
RUN_TOKEN_VALUE="${2:-${RUN_TOKEN:-}}"

if [ -z "${WORKER_URL//[[:space:]]/}" ]; then
  usage
  exit 1
fi

if [ -z "${RUN_TOKEN_VALUE//[[:space:]]/}" ]; then
  echo "RUN_TOKEN 不能为空" >&2
  exit 1
fi

WORKER_URL="${WORKER_URL%/}"
TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> 检查健康接口"
curl -fsS "$WORKER_URL/health" -o "$TMP_DIR/health.json"
python3 - "$TMP_DIR/health.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if data.get("ok") is not True:
    raise SystemExit(f"health ok 字段异常：{data}")
if data.get("queue") != "enabled":
    raise SystemExit(f"Queue 未绑定或不可用：{data}")
crons = data.get("crons") or {}
if crons.get("noon", {}).get("cron") != "1 5 * * *":
    raise SystemExit(f"noon Cron 异常：{crons}")
if crons.get("evening", {}).get("cron") != "1 12 * * *":
    raise SystemExit(f"evening Cron 异常：{crons}")
print("health match")
PY

echo "==> 检查未授权保护"
unauthorized_status="$(
  curl -sS -o "$TMP_DIR/unauthorized.txt" -w "%{http_code}" \
    "$WORKER_URL/run?module=noon&qq=__cloudflare_post_deploy_check__"
)"
if [ "$unauthorized_status" != "401" ]; then
  echo "未授权请求应返回 401，实际为 $unauthorized_status" >&2
  cat "$TMP_DIR/unauthorized.txt" >&2
  exit 1
fi
echo "unauthorized match"

echo "==> 检查 Secret 和账号校验"
invalid_account_status="$(
  curl -sS -o "$TMP_DIR/invalid-account.json" -w "%{http_code}" \
    -H "X-Run-Token: $RUN_TOKEN_VALUE" \
    "$WORKER_URL/run?module=noon&qq=__cloudflare_post_deploy_check__"
)"
if [ "$invalid_account_status" != "400" ]; then
  echo "带 token 的未知账号请求应返回 400，实际为 $invalid_account_status" >&2
  cat "$TMP_DIR/invalid-account.json" >&2
  echo >&2
  echo "如果这里是 503，请检查 RUN_TOKEN Secret；如果是 500，请检查 DALEDOU_COOKIES Secret。" >&2
  exit 1
fi
echo "secret validation match"

echo "==> 线上基础检查通过。现在可以用 wrangler tail 观察下一次 Cron 或手动触发。"
