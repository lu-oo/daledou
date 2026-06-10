#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDFLARE_DIR="$ROOT/cloudflare"
NODE_VERSION_REQUIRED="v22.12.0"
NODE_2212_BIN="$HOME/.nvm/versions/node/v22.12.0/bin"

if [ -x "$NODE_2212_BIN/node" ]; then
  export PATH="$NODE_2212_BIN:$PATH"
elif [ -s "$HOME/.nvm/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.nvm/nvm.sh"
  nvm use 22.12.0 >/dev/null
fi

NODE_VERSION="$(node --version 2>/dev/null || true)"
if [ "$NODE_VERSION" != "$NODE_VERSION_REQUIRED" ]; then
  echo "Node 版本不正确：当前 ${NODE_VERSION:-未找到}，需要 $NODE_VERSION_REQUIRED" >&2
  echo "本脚本不会安装 Node。请先准备已有 Node 22.12.0 后重试。" >&2
  exit 1
fi

usage() {
  cat >&2 <<'EOF'
用法：
  bash scripts/cloudflare_update_secret.sh cookies
  bash scripts/cloudflare_update_secret.sh run-token
  bash scripts/cloudflare_update_secret.sh account-config /path/to/account-config.json

说明：
  cookies        更新 DALEDOU_COOKIES，一行一个 Cookie，输入 END 结束
  run-token      更新 RUN_TOKEN
  account-config 更新可选的 DALEDOU_ACCOUNT_CONFIG，要求 JSON 对象文件
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

ensure_login() {
  cd "$CLOUDFLARE_DIR"
  npx --yes wrangler whoami >/dev/null || npx --yes wrangler login
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
  ensure_login
  printf "%s" "$value" | npx --yes wrangler secret put DALEDOU_COOKIES --config wrangler.jsonc
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
  ensure_login
  printf "%s" "$value" | npx --yes wrangler secret put RUN_TOKEN --config wrangler.jsonc
}

update_account_config() {
  local file_path="${1:-}"
  if [ -z "$file_path" ]; then
    usage
    exit 1
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
  ensure_login
  npx --yes wrangler secret put DALEDOU_ACCOUNT_CONFIG --config wrangler.jsonc < "$file_path"
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
