#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDFLARE_DIR="$ROOT/cloudflare"
# shellcheck source=cloudflare_node.sh
. "$ROOT/scripts/cloudflare_node.sh"

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

ensure_cloudflare_node

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

configured_queue_names() {
  node - "$CLOUDFLARE_DIR/wrangler.jsonc" <<'JS'
const fs = require("node:fs");

const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const queues = new Set();

for (const producer of config.queues?.producers ?? []) {
  if (producer.queue) {
    queues.add(producer.queue);
  }
}

for (const consumer of config.queues?.consumers ?? []) {
  if (consumer.queue) {
    queues.add(consumer.queue);
  }
  if (consumer.dead_letter_queue) {
    queues.add(consumer.dead_letter_queue);
  }
}

for (const queue of queues) {
  console.log(queue);
}
JS
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

echo "==> 按 wrangler.jsonc 创建 Queue（如果已存在，Cloudflare 会提示，可继续后续步骤）"
configured_queue_names | while IFS= read -r queue_name; do
  if [ -n "$queue_name" ]; then
    ensure_queue "$queue_name"
  fi
done

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
echo "cd cloudflare && npx --yes wrangler tail"
echo "也建议立即运行部署后基础检查："
echo "bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN"
