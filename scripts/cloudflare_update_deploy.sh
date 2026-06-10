#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDFLARE_DIR="$ROOT/cloudflare"
NODE_VERSION_REQUIRED="v22.12.0"
NODE_2212_BIN="$HOME/.nvm/versions/node/v22.12.0/bin"
DRY_RUN="false"

usage() {
  cat >&2 <<'EOF'
用法：
  bash scripts/cloudflare_update_deploy.sh
  bash scripts/cloudflare_update_deploy.sh --dry-run

说明：
  默认会验证并发布代码更新，沿用已有 Secret、Queue 和 Cron。
  --dry-run 只验证打包，不更新线上 Worker。
EOF
}

case "${1:-}" in
  "")
    ;;
  --dry-run)
    DRY_RUN="true"
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

echo "==> 代码更新部署前验证"
cd "$ROOT"
bash scripts/cloudflare_verify.sh

cd "$CLOUDFLARE_DIR"

echo "==> Cloudflare 登录检查"
npx --yes wrangler whoami >/dev/null || npx --yes wrangler login

if [ "$DRY_RUN" = "true" ]; then
  echo "==> dry-run：只验证打包，不更新线上 Worker"
  npx --yes wrangler deploy --dry-run --config wrangler.jsonc
  exit 0
fi

echo "==> 发布代码更新（不重新创建 Queue，不重新写入 Secret）"
npx --yes wrangler deploy --config wrangler.jsonc

echo "==> 完成。已有 DALEDOU_COOKIES、RUN_TOKEN、Queue 和 Cron 配置会继续沿用。"
echo "可使用以下命令查看日志："
echo "cd cloudflare && nvm use && npx --yes wrangler tail"
