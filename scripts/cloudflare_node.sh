#!/usr/bin/env bash

CLOUDFLARE_NODE_MIN_VERSION="${CLOUDFLARE_NODE_MIN_VERSION:-22.0.0}"

ensure_cloudflare_node() {
  local node_version=""

  if ! command -v node >/dev/null 2>&1; then
    echo "未找到 Node.js。请先准备 Node.js >= v${CLOUDFLARE_NODE_MIN_VERSION} 后重试。" >&2
    return 1
  fi

  node_version="$(node --version 2>/dev/null | sed 's/^v//')"
  if ! node - "$CLOUDFLARE_NODE_MIN_VERSION" "$node_version" <<'JS'
const [required, current] = process.argv.slice(2);

function parseVersion(value) {
  const match = String(value).match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!match) {
    return null;
  }
  return match.slice(1).map(Number);
}

const requiredParts = parseVersion(required);
const currentParts = parseVersion(current);

if (!requiredParts || !currentParts) {
  process.exit(2);
}

const ok = currentParts[0] > requiredParts[0]
  || (currentParts[0] === requiredParts[0] && currentParts[1] > requiredParts[1])
  || (currentParts[0] === requiredParts[0] && currentParts[1] === requiredParts[1] && currentParts[2] >= requiredParts[2]);

process.exit(ok ? 0 : 1);
JS
  then
    echo "Node 版本不满足要求：当前 ${node_version:-未找到}，需要 >= v${CLOUDFLARE_NODE_MIN_VERSION}" >&2
    echo "本脚本不会安装或切换 Node。请先在当前 shell 中准备合适版本后重试。" >&2
    return 1
  fi

  echo "==> Node 版本检查通过：v${node_version} >= v${CLOUDFLARE_NODE_MIN_VERSION}"
}
