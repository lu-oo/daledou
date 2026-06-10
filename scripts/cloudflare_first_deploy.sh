#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDFLARE_DIR="$ROOT/cloudflare"
NODE_VERSION_REQUIRED="v22.12.0"
NODE_2212_BIN="$HOME/.nvm/versions/node/v22.12.0/bin"

usage() {
  cat >&2 <<'EOF'
用法：
  bash scripts/cloudflare_first_deploy.sh

说明：
  首次部署向导会验证项目、登录 Cloudflare、创建 Queue、录入 Cookie 和 RUN_TOKEN，并部署 Worker。
  如果已经首次部署过，普通代码更新请使用：bash scripts/cloudflare_update_deploy.sh
  如果只更新 Cookie 或 RUN_TOKEN，请使用：bash scripts/cloudflare_update_secret.sh cookies/run-token
EOF
}

case "${1:-}" in
  "")
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

ensure_queue() {
  local queue_name="$1"
  if npx --yes wrangler queues create "$queue_name"; then
    return 0
  fi

  echo "==> Queue 创建返回非 0，检查是否已存在：$queue_name"
  if npx --yes wrangler queues list | grep -Fq "$queue_name"; then
    echo "==> Queue 已存在：$queue_name"
    return 0
  fi

  echo "Queue 创建失败，且未在列表中找到：$queue_name" >&2
  exit 1
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

echo "==> 部署前验证"
echo "==> 如果已经首次部署过，只更新代码请改用：bash scripts/cloudflare_update_deploy.sh"
cd "$ROOT"
bash scripts/cloudflare_verify.sh

cd "$CLOUDFLARE_DIR"

echo "==> Cloudflare 登录检查"
npx --yes wrangler whoami >/dev/null || npx --yes wrangler login

echo "==> 创建 Queue（如果已存在，Cloudflare 会提示，可继续后续步骤）"
ensure_queue daledou-cloud-queue
ensure_queue daledou-cloud-dlq

echo "==> 准备 DALEDOU_COOKIES Secret"
DALEDOU_COOKIES_VALUE="$(read_multiline_secret)"

echo "==> 校验 DALEDOU_COOKIES Secret"
export DALEDOU_COOKIES_VALUE
uv run python "$ROOT/scripts/validate_cloudflare_cookies.py"

echo "==> 准备 RUN_TOKEN Secret"
read -r -s -p "请输入 RUN_TOKEN：" RUN_TOKEN_VALUE
echo
if [ -z "${RUN_TOKEN_VALUE//[[:space:]]/}" ]; then
  echo "RUN_TOKEN 不能为空" >&2
  exit 1
fi
if [ "${#RUN_TOKEN_VALUE}" -lt 16 ]; then
  echo "RUN_TOKEN 至少需要 16 个字符，请使用更长的随机字符串" >&2
  exit 1
fi

echo "==> 部署 Worker"
cd "$CLOUDFLARE_DIR"
npx --yes wrangler deploy --config wrangler.jsonc

echo "==> 上传 DALEDOU_COOKIES Secret"
printf "%s" "$DALEDOU_COOKIES_VALUE" | npx --yes wrangler secret put DALEDOU_COOKIES --config wrangler.jsonc

echo "==> 上传 RUN_TOKEN Secret"
printf "%s" "$RUN_TOKEN_VALUE" | npx --yes wrangler secret put RUN_TOKEN --config wrangler.jsonc
unset DALEDOU_COOKIES_VALUE RUN_TOKEN_VALUE

echo "==> 完成。可使用以下命令查看日志："
echo "cd cloudflare && nvm use && npx --yes wrangler tail"
echo "也建议立即运行部署后基础检查："
echo "bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN"
