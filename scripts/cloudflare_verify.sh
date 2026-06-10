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
  echo "请先使用已有 Node 22.12.0，例如：cd cloudflare && nvm use" >&2
  exit 1
fi

cd "$ROOT"

uv run python -m py_compile \
  scripts/generate_cloudflare_worker_js.py \
  scripts/validate_cloudflare_cookies.py \
  src/tasks/common.py \
  src/tasks/noon.py \
  src/tasks/evening.py \
  src/tasks/register.py

uv run python scripts/generate_cloudflare_worker_js.py

uv run python - <<'PY'
import json
from pathlib import Path

config = json.loads(Path("cloudflare/wrangler.jsonc").read_text(encoding="utf-8"))
assert config["main"] == "../cloudflare_worker/src/index.js"
assert "python_workers" not in json.dumps(config)
assert config["triggers"]["crons"] == ["1 5 * * *", "1 12 * * *"]
forbidden_config_key = "lim" + "its"
forbidden_cpu_key = "cpu" + "_ms"
assert forbidden_config_key not in config
assert forbidden_cpu_key not in json.dumps(config)
consumer = config["queues"]["consumers"][0]
assert consumer["max_batch_size"] == 1
assert consumer["max_retries"] == 2
assert consumer["dead_letter_queue"] == "daledou-cloud-dlq"
print("cloudflare js config match")
PY

DALEDOU_COOKIES_VALUE="openId=dummy; accessToken=dummy; newuin=123456789" \
  uv run python "$ROOT/scripts/validate_cloudflare_cookies.py"
(
  cd "$CLOUDFLARE_DIR"
  DALEDOU_COOKIES_VALUE="openId=dummy; accessToken=dummy; newuin=123456789" \
    uv run python "$ROOT/scripts/validate_cloudflare_cookies.py"
)
if DALEDOU_COOKIES_VALUE="openId=dummy; accessToken=dummy" \
  uv run python "$ROOT/scripts/validate_cloudflare_cookies.py" >/dev/null 2>&1; then
  echo "缺少 newuin 的 Cookie 不应通过校验" >&2
  exit 1
fi
echo "cookie validation match"

TMP_DIR="$(mktemp -d)"
ROOT_TASKS_FILE="$TMP_DIR/root-tasks.json"
WORKER_TASKS_FILE="$TMP_DIR/worker-tasks.json"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export ROOT_TASKS_FILE WORKER_TASKS_FILE
uv run python - <<'PY'
import json
import os

from src.tasks.register import TaskModule, get_module_tasks
import src.tasks.noon  # noqa: F401
import src.tasks.evening  # noqa: F401

tasks = {
    module.value: list(get_module_tasks(module).keys())
    for module in (TaskModule.noon, TaskModule.evening)
}
assert len(tasks["noon"]) == 64
assert len(tasks["evening"]) == 71
with open(os.environ["ROOT_TASKS_FILE"], "w", encoding="utf-8") as fp:
    json.dump(tasks, fp, ensure_ascii=False, indent=2)
print(f"python task list noon={len(tasks['noon'])} evening={len(tasks['evening'])}")
PY

node --input-type=module - "$WORKER_TASKS_FILE" <<'JS'
import assert from "node:assert/strict";
import fs from "node:fs";

import worker from "./cloudflare_worker/src/index.js";
import {
  DateTime,
  TaskModule,
  getTaskNames,
} from "./cloudflare_worker/src/runtime.js";

const tasks = {
  noon: getTaskNames(TaskModule.noon),
  evening: getTaskNames(TaskModule.evening),
};
assert.equal(tasks.noon.length, 64);
assert.equal(tasks.evening.length, 71);
fs.writeFileSync(process.argv[2], JSON.stringify(tasks, null, 2));
console.log(`js task list noon=${tasks.noon.length} evening=${tasks.evening.length}`);

const originalDateNow = Date.now;
Date.now = () => Date.UTC(2026, 5, 9, 16, 0, 0);
assert.equal(DateTime.current_date(), "2026-06-10");
assert.equal(DateTime.day(), 10);
assert.equal(DateTime.week(), 3);
Date.now = originalDateNow;
console.log("beijing time match");

class FakeQueue {
  constructor() {
    this.batches = [];
    this.sent = [];
  }

  async sendBatch(batch) {
    this.batches.push(batch);
  }

  async send(body) {
    this.sent.push(body);
  }
}

const env = {
  DALEDOU_COOKIES: "openId=dummy; accessToken=dummy; newuin=123456789",
  RUN_TOKEN: "local-verify-token",
  DALEDOU_QUEUE: new FakeQueue(),
};

let response = await worker.fetch(new Request("https://worker.test/health"), env);
assert.equal(response.status, 200);
let payload = await response.json();
assert.equal(payload.ok, true);
assert.equal(payload.runtime, "javascript-worker");
assert.equal(payload.queue, "enabled");
assert.equal(payload.tasks.noon, 64);
assert.equal(payload.tasks.evening, 71);
assert.equal(payload.crons.noon.cron, "1 5 * * *");
assert.equal(payload.crons.evening.cron, "1 12 * * *");

response = await worker.fetch(new Request("https://worker.test/run?module=noon"), env);
assert.equal(response.status, 401);

response = await worker.fetch(
  new Request("https://worker.test/run?module=noon&qq=999999", {
    headers: { "X-Run-Token": "local-verify-token" },
  }),
  env,
);
assert.equal(response.status, 400);

response = await worker.fetch(
  new Request("https://worker.test/run?module=noon&qq=123456789&task=每日奖励", {
    headers: { Authorization: "Bearer local-verify-token" },
  }),
  env,
);
assert.equal(response.status, 200);
payload = await response.json();
assert.equal(payload.ok, true);
assert.equal(payload.result.queued, 1);
assert.equal(env.DALEDOU_QUEUE.batches.at(-1)[0].body.qq, "123456789");
assert.equal(env.DALEDOU_QUEUE.batches.at(-1)[0].body.task, "每日奖励");

await worker.scheduled({ cron: "1 5 * * *" }, env);
const scheduledBody = env.DALEDOU_QUEUE.batches.at(-1)[0].body;
assert.equal(scheduledBody.module, "noon");
assert.equal(scheduledBody.task, "邪神秘宝");
assert.equal(scheduledBody.taskIndex, 0);
console.log("fetch scheduled queue match");

const queueEnv = {
  DALEDOU_COOKIES: "openId=dummy; accessToken=dummy; newuin=123456789",
  RUN_TOKEN: "local-verify-token",
  DALEDOU_QUEUE: new FakeQueue(),
};

const originalFetch = globalThis.fetch;
globalThis.fetch = async (url) => {
  const textUrl = String(url);
  if (textUrl.includes("cmd=index")) {
    return new Response("<a>邪神秘宝</a><a>华山论剑</a>");
  }
  if (textUrl.includes("cmd=tenlottery")) {
    return new Response("】</p>抽奖成功<br />");
  }
  return new Response("<br />ok<");
};

const message = {
  body: {
    module: "noon",
    qq: "123456789",
    task: "邪神秘宝",
    taskIndex: 0,
  },
  acked: false,
  retried: false,
  ack() {
    this.acked = true;
  },
  retry() {
    this.retried = true;
  },
};

await worker.queue({ messages: [message] }, queueEnv);
globalThis.fetch = originalFetch;
assert.equal(message.acked, true);
assert.equal(message.retried, false);
assert.equal(queueEnv.DALEDOU_QUEUE.sent.length, 1);
assert.equal(queueEnv.DALEDOU_QUEUE.sent[0].taskIndex, 1);
assert.equal(queueEnv.DALEDOU_QUEUE.sent[0].task, "华山论剑");
console.log("queue sequence match");
JS

if ! cmp -s "$ROOT_TASKS_FILE" "$WORKER_TASKS_FILE"; then
  echo "Python 任务列表与 JS Worker 任务列表不一致：" >&2
  diff -u "$ROOT_TASKS_FILE" "$WORKER_TASKS_FILE" >&2 || true
  exit 1
fi
echo "task list match"

if rg -n "await pyGet\\(d|pyGet\\(d,|\\bself\\b|asyncio|random\\." cloudflare_worker/src/tasks; then
  echo "生成的 JS 任务仍存在未正确转换的 Python 语义" >&2
  exit 1
fi
echo "generated task syntax match"

cd "$CLOUDFLARE_DIR"
npx --yes wrangler deploy --dry-run --config wrangler.jsonc
