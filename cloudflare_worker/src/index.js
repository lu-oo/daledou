import { DEFAULT_CONFIG } from "./config.js";
import {
  Client,
  ConfigResolver,
  DaLeDou,
  DateTime,
  RequestError,
  TaskModule,
  getModuleTasks,
  getTaskNames,
} from "./runtime.js";
import "./tasks/noon.js";
import "./tasks/evening.js";

const CRON_TO_MODULE = {
  "1 5 * * *": TaskModule.noon,
  "1 12 * * *": TaskModule.evening,
};

const MODULE_CRONS = {
  [TaskModule.noon]: { cron: "1 5 * * *", beijing: "每天 13:01" },
  [TaskModule.evening]: { cron: "1 12 * * *", beijing: "每天 20:01" },
};

const QUEUE_SEND_BATCH_SIZE = 100;

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function textResponse(text, status = 200) {
  return new Response(text, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

function envText(env, key, fallback = "") {
  const value = env?.[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value).trim();
  if (!text || text === "undefined" || text === "null" || text === "None") {
    return fallback;
  }
  return text;
}

async function safeEqual(left, right) {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(String(left ?? ""))),
    crypto.subtle.digest("SHA-256", encoder.encode(String(right ?? ""))),
  ]);
  const leftBytes = new Uint8Array(leftHash);
  const rightBytes = new Uint8Array(rightHash);
  let diff = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    diff |= leftBytes[index] ^ rightBytes[index];
  }
  return diff === 0;
}

function tokenFromRequest(request, url) {
  const headerToken = request.headers.get("x-run-token");
  if (headerToken) {
    return headerToken.trim();
  }

  const authorization = request.headers.get("authorization") || "";
  if (authorization.toLowerCase().startsWith("bearer ")) {
    return authorization.slice(7).trim();
  }
  if (authorization.trim()) {
    return authorization.trim();
  }

  return url.searchParams.get("token") || "";
}

function parseCookieLine(cookie) {
  const result = {};
  for (const part of String(cookie).split(";")) {
    const index = part.indexOf("=");
    if (index === -1) {
      continue;
    }
    const key = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (key) {
      result[key] = value;
    }
  }
  return result;
}

function loadCookies(env, qq = null) {
  const raw = envText(env, "DALEDOU_COOKIES");
  if (!raw) {
    return new Map();
  }

  let items;
  const stripped = raw.trim();
  if (stripped.startsWith("[")) {
    try {
      items = JSON.parse(stripped);
    } catch (error) {
      items = stripped
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line && !line.startsWith("#"));
    }
    if (!Array.isArray(items)) {
      items = [];
    }
  } else {
    items = stripped
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#"));
  }

  const accounts = new Map();
  for (const item of items) {
    const cookie = parseCookieLine(item);
    if (!cookie.newuin) {
      continue;
    }
    if (qq && cookie.newuin !== qq) {
      continue;
    }
    accounts.set(cookie.newuin, cookie);
  }
  return accounts;
}

function loadAccountOverrides(env) {
  const raw = envText(env, "DALEDOU_ACCOUNT_CONFIG");
  if (!raw) {
    return {};
  }
  const stripped = raw.trim();
  if (!stripped) {
    return {};
  }
  if (!stripped.startsWith("{")) {
    throw new Error("DALEDOU_ACCOUNT_CONFIG 仅支持 JSON 对象格式");
  }
  return JSON.parse(stripped);
}

function moduleFromString(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === TaskModule.noon || normalized === TaskModule.evening) {
    return normalized;
  }
  throw new Error(`未知模块 '${value}'，可用模块：noon, evening`);
}

function moduleFromCron(cron) {
  const moduleName = CRON_TO_MODULE[cron];
  if (!moduleName) {
    throw new Error(`未知 Cron 表达式：${cron}`);
  }
  return moduleName;
}

function resolveTask(moduleName, taskName) {
  const registry = getModuleTasks(moduleName);
  if (!taskName) {
    return null;
  }
  const task = registry.get(taskName);
  if (!task) {
    throw new Error(`模块 '${moduleName}' 未注册 '${taskName}' 任务。可用任务：${getTaskNames(moduleName).join(", ")}`);
  }
  return task;
}

function buildQueueBody(moduleName, qq, taskName, taskIndex = null) {
  const body = {
    module: moduleName,
    qq,
    task: taskName,
  };
  if (taskIndex !== null && taskIndex !== undefined) {
    body.taskIndex = taskIndex;
  }
  return body;
}

async function sendQueueMessages(queue, bodies) {
  let calls = 0;
  for (let start = 0; start < bodies.length; start += QUEUE_SEND_BATCH_SIZE) {
    const batch = bodies.slice(start, start + QUEUE_SEND_BATCH_SIZE).map((body) => ({ body }));
    await queue.sendBatch(batch);
    calls += 1;
  }
  return calls;
}

async function enqueueOrRun(env, moduleName, { taskName = null, qq = null } = {}) {
  const taskNames = getTaskNames(moduleName);
  if (taskNames.length === 0) {
    throw new Error(`${moduleName} 模块没有注册任务`);
  }
  resolveTask(moduleName, taskName);

  const accounts = loadCookies(env, qq);
  if (accounts.size === 0) {
    throw new Error(qq ? `DALEDOU_COOKIES 中未找到账号 ${qq}` : "未设置 DALEDOU_COOKIES Secret 或 Cookie 中缺少 newuin");
  }

  if (!env.DALEDOU_QUEUE) {
    const results = [];
    for (const accountId of accounts.keys()) {
      if (taskName) {
        results.push(await runAccountTask(env, moduleName, accountId, taskName));
      } else {
        for (const name of taskNames) {
          results.push(await runAccountTask(env, moduleName, accountId, name));
        }
      }
    }
    return { module: moduleName, task: taskName, queued: 0, ranInline: results.length, results };
  }

  const bodies = [];
  if (taskName) {
    for (const accountId of accounts.keys()) {
      bodies.push(buildQueueBody(moduleName, accountId, taskName, null));
    }
  } else {
    for (const accountId of accounts.keys()) {
      bodies.push(buildQueueBody(moduleName, accountId, taskNames[0], 0));
    }
  }

  const queueSendCalls = await sendQueueMessages(env.DALEDOU_QUEUE, bodies);
  return {
    module: moduleName,
    task: taskName,
    taskCount: taskName ? 1 : taskNames.length,
    queued: bodies.length,
    queueSendCalls,
    accounts: [...accounts.keys()],
  };
}

async function runAccountTask(env, moduleName, qq, taskName) {
  const accounts = loadCookies(env, qq);
  const cookie = accounts.get(qq);
  if (!cookie) {
    throw new Error(`DALEDOU_COOKIES 中未找到账号 ${qq}`);
  }

  const task = resolveTask(moduleName, taskName);
  const startedAt = Date.now();
  const client = new Client(qq, cookie);
  const configResolver = new ConfigResolver(qq, moduleName, DEFAULT_CONFIG, loadAccountOverrides(env));
  const d = new DaLeDou(qq, client, configResolver);

  const indexHtml = await d.get("cmd=index&style=1");
  if (!indexHtml.includes("邪神秘宝")) {
    throw new RequestError("非大乐斗首页（可能繁忙、维护或 Cookie 失效）");
  }

  if (!indexHtml.includes(`>${taskName}<`)) {
    d.log("首页未出现该任务入口，跳过", taskName);
    return {
      module: moduleName,
      qq,
      task: taskName,
      skipped: true,
      elapsed: DateTime.format_timedelta(Date.now() - startedAt),
    };
  }

  d.task_name = taskName;
  try {
    await task(d);
  } catch (error) {
    if (error instanceof RequestError) {
      throw error;
    }
    const message = error instanceof Error ? `${error.stack || error.message}` : String(error);
    d.log(message, taskName);
  }

  return {
    module: moduleName,
    qq,
    task: taskName,
    skipped: false,
    elapsed: DateTime.format_timedelta(Date.now() - startedAt),
  };
}

async function handleQueueMessage(env, body) {
  const moduleName = moduleFromString(body?.module || TaskModule.noon);
  const qq = String(body?.qq || "");
  const taskName = body?.task ? String(body.task) : null;
  const taskIndex = body?.taskIndex === undefined || body?.taskIndex === null ? null : Number.parseInt(String(body.taskIndex), 10);
  if (!qq) {
    throw new Error("Queue 消息缺少 qq");
  }
  if (!taskName) {
    throw new Error("Queue 消息缺少 task");
  }

  const result = await runAccountTask(env, moduleName, qq, taskName);
  if (taskIndex !== null) {
    const tasks = getTaskNames(moduleName);
    const nextIndex = taskIndex + 1;
    if (nextIndex < tasks.length) {
      await env.DALEDOU_QUEUE.send(buildQueueBody(moduleName, qq, tasks[nextIndex], nextIndex));
    } else {
      console.log(JSON.stringify({ event: "queue-sequence-complete", module: moduleName, qq, tasks: tasks.length }));
    }
  }
  return result;
}

function healthPayload(env) {
  let accountCount = 0;
  let cookieStatus = "ok";
  try {
    accountCount = loadCookies(env).size;
  } catch (error) {
    cookieStatus = error instanceof Error ? error.message : String(error);
  }

  return {
    ok: true,
    service: "daledou-cloudflare-worker",
    runtime: "javascript-worker",
    queue: env.DALEDOU_QUEUE ? "enabled" : "missing",
    accounts: accountCount,
    cookies: cookieStatus,
    tasks: {
      noon: getTaskNames(TaskModule.noon).length,
      evening: getTaskNames(TaskModule.evening).length,
    },
    beijingNow: DateTime.current_date(),
    timezone: "Cloudflare Cron 使用 UTC；北京时间 UTC+8。北京时间 08:00 对应 Cloudflare/UTC 00:00。",
    crons: MODULE_CRONS,
    manual: "/run?module=noon with X-Run-Token or Authorization: Bearer <RUN_TOKEN>",
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/health") {
      return jsonResponse(healthPayload(env));
    }

    if (url.pathname !== "/run") {
      return textResponse("Not Found", 404);
    }

    const expectedToken = envText(env, "RUN_TOKEN");
    if (!expectedToken) {
      return textResponse("RUN_TOKEN secret is not configured", 503);
    }
    if (!(await safeEqual(tokenFromRequest(request, url), expectedToken))) {
      return textResponse("Unauthorized", 401);
    }

    try {
      const moduleName = moduleFromString(url.searchParams.get("module") || TaskModule.noon);
      const taskName = url.searchParams.get("task");
      const qq = url.searchParams.get("qq");
      const result = await enqueueOrRun(env, moduleName, { taskName, qq });
      return jsonResponse({ ok: true, result });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return jsonResponse({ ok: false, error: message }, 400);
    }
  },

  async scheduled(controller, env) {
    const moduleName = moduleFromCron(controller.cron);
    console.log(JSON.stringify({ event: "scheduled", cron: controller.cron, module: moduleName }));
    await enqueueOrRun(env, moduleName);
  },

  async queue(batch, env) {
    for (const message of batch.messages) {
      try {
        const result = await handleQueueMessage(env, message.body);
        console.log(JSON.stringify({ event: "queue-message-complete", result }));
        message.ack();
      } catch (error) {
        const messageText = error instanceof Error ? error.stack || error.message : String(error);
        console.log(JSON.stringify({ event: "queue-message-failed", error: messageText }));
        message.retry();
      }
    }
  },
};
