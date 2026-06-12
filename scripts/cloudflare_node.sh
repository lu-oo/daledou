#!/usr/bin/env bash

CLOUDFLARE_NODE_MIN_VERSION="${CLOUDFLARE_NODE_MIN_VERSION:-22.0.0}"
CLOUDFLARE_TARGET_CONFIG_DEFAULT="${ROOT:-$(pwd)}/deploy/cloudflare-targets.local.json"
CLOUDFLARE_TOKEN_ENV_FILE_DEFAULT="${ROOT:-$(pwd)}/.env.deploy.local"
CLOUDFLARE_TOKEN_ENV_DEFAULT="CF_API_TOKEN_PRIMARY"

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

load_cloudflare_deploy_target() {
  local target_config="${CLOUDFLARE_TARGET_CONFIG:-$CLOUDFLARE_TARGET_CONFIG_DEFAULT}"
  local target_name="${CLOUDFLARE_TARGET:-primary}"
  local output=""
  local key=""
  local value=""

  if [ ! -f "$target_config" ]; then
    return 1
  fi

  output="$(node - "$target_config" "$target_name" <<'JS'
const fs = require("node:fs");

const [configPath, targetName] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const targets = Array.isArray(config.targets) ? config.targets : [];
const target = targets.find((item) => item.name === targetName)
  || targets.find((item) => item.enabled !== false)
  || targets[0];

if (!target) {
  process.exit(1);
}

function validIdentifier(value) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(String(value || ""));
}

function validAccountId(value) {
  return /^[a-f0-9]{32}$/i.test(String(value || ""));
}

if (target.accountId && validAccountId(target.accountId)) {
  console.log(`CLOUDFLARE_ACCOUNT_ID=${target.accountId}`);
}

if (target.apiTokenEnv && validIdentifier(target.apiTokenEnv)) {
  console.log(`CLOUDFLARE_TOKEN_ENV=${target.apiTokenEnv}`);
}

if (target.name && validIdentifier(String(target.name).replace(/-/g, "_"))) {
  console.log(`CLOUDFLARE_TARGET=${target.name}`);
}
JS
)"

  while IFS='=' read -r key value; do
    case "$key" in
      CLOUDFLARE_ACCOUNT_ID)
        if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
          export CLOUDFLARE_ACCOUNT_ID="$value"
        fi
        ;;
      CLOUDFLARE_TOKEN_ENV)
        if [ -z "${CLOUDFLARE_TOKEN_ENV:-}" ]; then
          export CLOUDFLARE_TOKEN_ENV="$value"
        fi
        ;;
      CLOUDFLARE_TARGET)
        if [ -z "${CLOUDFLARE_TARGET:-}" ]; then
          export CLOUDFLARE_TARGET="$value"
        fi
        ;;
    esac
  done <<< "$output"
}

load_cloudflare_api_token() {
  local env_file="${CLOUDFLARE_TOKEN_ENV_FILE:-$CLOUDFLARE_TOKEN_ENV_FILE_DEFAULT}"
  local token_env="${CLOUDFLARE_TOKEN_ENV:-$CLOUDFLARE_TOKEN_ENV_DEFAULT}"
  local line=""
  local key=""
  local value=""
  local env_value=""

  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    return 0
  fi

  env_value="${!token_env:-}"
  if [ -n "$env_value" ]; then
    export CLOUDFLARE_API_TOKEN="$env_value"
    return 0
  fi

  if [ ! -f "$env_file" ]; then
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*)
        continue
        ;;
    esac

    key="${line%%=*}"
    if [ "$key" = "$line" ]; then
      continue
    fi

    key="$(printf "%s" "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$key" != "$token_env" ]; then
      continue
    fi

    value="${line#*=}"
    value="$(printf "%s" "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
      value="${value#\"}"
      value="${value%\"}"
    elif [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ]; then
      value="${value#\'}"
      value="${value%\'}"
    fi

    if [ -n "$value" ]; then
      export CLOUDFLARE_API_TOKEN="$value"
      return 0
    fi
  done < "$env_file"

  return 1
}

ensure_cloudflare_api_token() {
  local env_file="${CLOUDFLARE_TOKEN_ENV_FILE:-$CLOUDFLARE_TOKEN_ENV_FILE_DEFAULT}"
  local token_env=""

  load_cloudflare_deploy_target >/dev/null 2>&1 || true
  token_env="${CLOUDFLARE_TOKEN_ENV:-$CLOUDFLARE_TOKEN_ENV_DEFAULT}"

  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "==> Cloudflare API Token 已加载：CLOUDFLARE_API_TOKEN"
    return 0
  fi

  if ! load_cloudflare_api_token; then
    echo "未找到 Cloudflare API Token。请在 ${env_file} 中配置 ${token_env}，或直接导出 CLOUDFLARE_API_TOKEN。" >&2
    return 1
  fi

  echo "==> Cloudflare API Token 已加载：${token_env}"
}

ensure_cloudflare_account_id() {
  local target_config="${CLOUDFLARE_TARGET_CONFIG:-$CLOUDFLARE_TARGET_CONFIG_DEFAULT}"
  local masked_account_id=""

  load_cloudflare_deploy_target >/dev/null 2>&1 || true

  if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    echo "未找到有效的 Cloudflare Account ID。请在 ${target_config} 中配置 32 位十六进制 targets[0].accountId，或直接导出 CLOUDFLARE_ACCOUNT_ID。" >&2
    return 1
  fi

  masked_account_id="${CLOUDFLARE_ACCOUNT_ID:0:6}...${CLOUDFLARE_ACCOUNT_ID: -4}"
  echo "==> Cloudflare Account ID 已加载：${masked_account_id}"
}

ensure_cloudflare_auth() {
  ensure_cloudflare_api_token
  ensure_cloudflare_account_id
}

configured_queue_names() {
  local config_path="${1:-wrangler.jsonc}"

  node - "$config_path" <<'JS'
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

ensure_wrangler_queue() {
  local queue_name="$1"

  if run_wrangler queues create "$queue_name"; then
    return 0
  fi

  echo "==> Queue 创建返回非 0，检查是否已存在：$queue_name"
  if run_wrangler queues list | grep -Fq "$queue_name"; then
    echo "==> Queue 已存在：$queue_name"
    return 0
  fi

  echo "Queue 创建失败，且未在列表中找到：$queue_name" >&2
  return 1
}

ensure_configured_queues() {
  local config_path="${1:-wrangler.jsonc}"

  configured_queue_names "$config_path" | while IFS= read -r queue_name; do
    if [ -n "$queue_name" ]; then
      ensure_wrangler_queue "$queue_name"
    fi
  done
}

run_wrangler() {
  local npm_cache="${CLOUDFLARE_NPM_CACHE:-}"
  local cache_root=""

  if [ -z "$npm_cache" ]; then
    cache_root="${ROOT:-$(pwd)}"
    npm_cache="$cache_root/.cache/cloudflare-npm"
    export CLOUDFLARE_NPM_CACHE="$npm_cache"
  fi

  mkdir -p "$npm_cache"
  load_cloudflare_deploy_target >/dev/null 2>&1 || true
  load_cloudflare_api_token >/dev/null 2>&1 || true
  NPM_CONFIG_CACHE="$npm_cache" npx --yes wrangler "$@"
}
