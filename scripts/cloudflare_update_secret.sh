#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDFLARE_DIR="$ROOT/cloudflare"
# shellcheck source=cloudflare_node.sh
. "$ROOT/scripts/cloudflare_node.sh"

ensure_cloudflare_node

usage() {
  cat >&2 <<'EOF'
用法：
  bash scripts/cloudflare_update_secret.sh cookies
  bash scripts/cloudflare_update_secret.sh run-token
  bash scripts/cloudflare_update_secret.sh account-config
  bash scripts/cloudflare_update_secret.sh account-config /path/to/account-config.json

说明：
  cookies        更新 DALEDOU_COOKIES，一行一个 Cookie，输入 END 结束
  run-token      更新 RUN_TOKEN
  account-config 更新可选的 DALEDOU_ACCOUNT_CONFIG；不传文件时自动导出 config/accounts/*.yaml
EOF
}

read_multiline_secret() {
  local value=""
  local line=""

  echo "请输入一行一个 Cookie，或 JSON 字符串数组。" >&2
  echo "输入完成后，单独输入 END 并回车。" >&2
  while IFS= read -r line; do
    if [ "$line" = "END" ]; then
      break
    fi
    value+="$line"$'\n'
  done

  if [ -z "${value//[[:space:]]/}" ]; then
    echo "DALEDOU_COOKIES 不能为空" >&2
    exit 1
  fi

  printf "%s" "$value"
}

ensure_cloudflare_token_context() {
  cd "$CLOUDFLARE_DIR"
  ensure_cloudflare_auth
}

update_cookies() {
  local value=""
  value="$(read_multiline_secret)"

  echo "==> 校验 DALEDOU_COOKIES"
  export DALEDOU_COOKIES_VALUE="$value"
  cd "$ROOT"
  uv run python "$ROOT/scripts/validate_cloudflare_cookies.py"
  unset DALEDOU_COOKIES_VALUE

  echo "==> 上传 DALEDOU_COOKIES Secret"
  ensure_cloudflare_token_context
  printf "%s" "$value" | run_wrangler secret put DALEDOU_COOKIES --config wrangler.jsonc
}

update_run_token() {
  local value=""

  read -r -s -p "请输入新的 RUN_TOKEN：" value
  echo
  if [ -z "${value//[[:space:]]/}" ]; then
    echo "RUN_TOKEN 不能为空" >&2
    exit 1
  fi
  if [ "${#value}" -lt 16 ]; then
    echo "RUN_TOKEN 至少需要 16 个字符，请使用更长的随机字符串" >&2
    exit 1
  fi

  echo "==> 上传 RUN_TOKEN Secret"
  ensure_cloudflare_token_context
  printf "%s" "$value" | run_wrangler secret put RUN_TOKEN --config wrangler.jsonc
}

update_account_config() {
  local file_path="${1:-}"
  local tmp_dir=""
  if [ -z "$file_path" ]; then
    tmp_dir="$(mktemp -d)"
    file_path="$tmp_dir/account-config.json"
    echo "==> 从 config/accounts/*.yaml 导出 DALEDOU_ACCOUNT_CONFIG"
    cd "$ROOT"
    uv run python "$ROOT/scripts/export_cloudflare_account_config.py" "$file_path"
  fi
  if [ ! -f "$file_path" ]; then
    echo "账号覆盖配置文件不存在：$file_path" >&2
    exit 1
  fi

  file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"

  cd "$ROOT"
  uv run python - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit("DALEDOU_ACCOUNT_CONFIG 必须是 JSON 对象")
print("account config json match")
PY

  echo "==> 上传 DALEDOU_ACCOUNT_CONFIG Secret"
  ensure_cloudflare_token_context
  run_wrangler secret put DALEDOU_ACCOUNT_CONFIG --config wrangler.jsonc < "$file_path"

  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}

case "${1:-}" in
  cookies)
    update_cookies
    ;;
  run-token)
    update_run_token
    ;;
  account-config)
    update_account_config "${2:-}"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "==> Secret 更新完成。代码无需重新部署，新的 Secret 会被后续请求和 Cron 使用。"
