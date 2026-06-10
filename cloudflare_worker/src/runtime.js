export const TaskModule = Object.freeze({
  noon: "noon",
  evening: "evening",
});

export class RequestError extends Error {
  constructor(message) {
    super(message);
    this.name = "RequestError";
  }
}

const TASKS_REGISTRY = {
  [TaskModule.noon]: new Map(),
  [TaskModule.evening]: new Map(),
};

export class Registry {
  constructor(moduleName) {
    if (!TASKS_REGISTRY[moduleName]) {
      TASKS_REGISTRY[moduleName] = new Map();
    }
    this.moduleName = moduleName;
  }

  register(taskName, taskFunc) {
    const registry = TASKS_REGISTRY[this.moduleName];
    if (registry.has(taskName)) {
      throw new Error(`任务 '${taskName}' 在模块 '${this.moduleName}' 中重复注册`);
    }
    registry.set(taskName, taskFunc);
    return taskFunc;
  }
}

export function getModuleTasks(moduleName) {
  const registry = TASKS_REGISTRY[moduleName];
  if (!registry) {
    throw new Error(`未知模块：${moduleName}`);
  }
  return registry;
}

export function getTaskNames(moduleName) {
  return [...getModuleTasks(moduleName).keys()];
}

export function pyTruthy(value) {
  if (value === null || value === undefined || value === false) {
    return false;
  }
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") {
    return value !== 0 && !Number.isNaN(value);
  }
  if (typeof value === "string" || Array.isArray(value)) {
    return value.length > 0;
  }
  if (value instanceof Set || value instanceof Map) {
    return value.size > 0;
  }
  if (typeof value === "object") {
    return Object.keys(value).length > 0;
  }
  return true;
}

export function pyInt(value) {
  if (typeof value === "number") {
    return Math.trunc(value);
  }
  const result = Number.parseInt(String(value), 10);
  if (Number.isNaN(result)) {
    throw new Error(`无法转换为整数：${value}`);
  }
  return result;
}

export function pyStr(value) {
  return String(value);
}

export function pyLen(value) {
  if (value === null || value === undefined) {
    return 0;
  }
  if (typeof value === "string" || Array.isArray(value)) {
    return value.length;
  }
  if (value instanceof Set || value instanceof Map) {
    return value.size;
  }
  if (typeof value === "object") {
    return Object.keys(value).length;
  }
  return 0;
}

export function pyRange(start, stop = null, step = 1) {
  let begin = pyInt(start);
  let end = stop === null ? begin : pyInt(stop);
  const stride = pyInt(step);
  if (stop === null) {
    begin = 0;
  }
  if (stride === 0) {
    throw new Error("range step 不能为 0");
  }

  const values = [];
  if (stride > 0) {
    for (let value = begin; value < end; value += stride) {
      values.push(value);
    }
  } else {
    for (let value = begin; value > end; value += stride) {
      values.push(value);
    }
  }
  return values;
}

export function pyEnumerate(iterable, start = 0) {
  return [...iterable].map((value, index) => [index + pyInt(start), value]);
}

export function pyItems(value) {
  if (value instanceof Map) {
    return [...value.entries()];
  }
  if (value === null || value === undefined) {
    return [];
  }
  return Object.entries(value);
}

export function pyGet(value, key, fallback = null) {
  if (value instanceof Map) {
    return value.has(key) ? value.get(key) : fallback;
  }
  if (value === null || value === undefined) {
    return fallback;
  }
  const objectKey = String(key);
  if (Object.prototype.hasOwnProperty.call(value, key)) {
    return value[key];
  }
  if (Object.prototype.hasOwnProperty.call(value, objectKey)) {
    return value[objectKey];
  }
  return fallback;
}

export function pyDict(pairs) {
  const result = {};
  for (const pair of pairs || []) {
    if (!Array.isArray(pair) || pair.length < 2) {
      continue;
    }
    result[pair[0]] = pair[1];
  }
  return result;
}

export function pySet(iterable = []) {
  return new Set(iterable || []);
}

export function contains(container, item) {
  if (container === null || container === undefined) {
    return false;
  }
  if (typeof container === "string") {
    return container.includes(String(item));
  }
  if (Array.isArray(container)) {
    return container.some((value) => pyEquals(value, item));
  }
  if (container instanceof Set) {
    return container.has(item);
  }
  if (container instanceof Map) {
    return container.has(item);
  }
  if (typeof container === "object") {
    return Object.prototype.hasOwnProperty.call(container, item)
      || Object.prototype.hasOwnProperty.call(container, String(item));
  }
  return false;
}

export function pyIsSubset(left, right) {
  const rightSet = right instanceof Set ? right : pySet(right);
  for (const item of left instanceof Set ? left : pySet(left)) {
    if (!rightSet.has(item)) {
      return false;
    }
  }
  return true;
}

export function pyAny(iterable, predicate = (value) => value) {
  for (const value of iterable || []) {
    if (pyTruthy(predicate(value))) {
      return true;
    }
  }
  return false;
}

export function pyDivmod(left, right) {
  const divisor = pyInt(right);
  const quotient = Math.floor(pyInt(left) / divisor);
  return [quotient, pyInt(left) - quotient * divisor];
}

export function pyAdd(left, right) {
  if (Array.isArray(left)) {
    return left.concat(right || []);
  }
  return left + right;
}

export function pySlice(value, start = null, end = null) {
  const begin = start === null ? undefined : pyInt(start);
  const finish = end === null ? undefined : pyInt(end);
  return value.slice(begin, finish);
}

export function pyCount(container, needle) {
  if (typeof container === "string") {
    if (needle === "") {
      return container.length + 1;
    }
    let count = 0;
    let index = 0;
    const text = String(needle);
    while ((index = container.indexOf(text, index)) !== -1) {
      count += 1;
      index += text.length;
    }
    return count;
  }
  if (Array.isArray(container)) {
    return container.filter((value) => pyEquals(value, needle)).length;
  }
  return 0;
}

export function pySorted(iterable, keyFn = null) {
  return [...(iterable || [])].sort((left, right) => {
    const leftValue = keyFn ? keyFn(left) : left;
    const rightValue = keyFn ? keyFn(right) : right;
    return pyCompare(leftValue, rightValue);
  });
}

export function pyMin(iterable, keyFn = null) {
  const values = [...(iterable || [])];
  if (values.length === 0) {
    throw new Error("min() arg is an empty sequence");
  }
  return values.reduce((best, value) => {
    const bestKey = keyFn ? keyFn(best) : best;
    const valueKey = keyFn ? keyFn(value) : value;
    return pyCompare(valueKey, bestKey) < 0 ? value : best;
  });
}

export function pyMax(iterable, keyFn = null) {
  const values = [...(iterable || [])];
  if (values.length === 0) {
    throw new Error("max() arg is an empty sequence");
  }
  return values.reduce((best, value) => {
    const bestKey = keyFn ? keyFn(best) : best;
    const valueKey = keyFn ? keyFn(value) : value;
    return pyCompare(valueKey, bestKey) > 0 ? value : best;
  });
}

function pyCompare(left, right) {
  if (Array.isArray(left) && Array.isArray(right)) {
    const length = Math.min(left.length, right.length);
    for (let index = 0; index < length; index += 1) {
      const result = pyCompare(left[index], right[index]);
      if (result !== 0) {
        return result;
      }
    }
    return left.length - right.length;
  }
  if (left === right) {
    return 0;
  }
  return left < right ? -1 : 1;
}

function pyEquals(left, right) {
  if (Array.isArray(left) && Array.isArray(right)) {
    return left.length === right.length && left.every((value, index) => pyEquals(value, right[index]));
  }
  return left === right;
}

export function randomChoice(values) {
  if (!values || values.length === 0) {
    throw new Error("Cannot choose from an empty sequence");
  }
  return values[Math.floor(Math.random() * values.length)];
}

export function randomSample(values, count) {
  const pool = [...values];
  const result = [];
  for (let index = 0; index < count && pool.length > 0; index += 1) {
    const position = Math.floor(Math.random() * pool.length);
    result.push(pool.splice(position, 1)[0]);
  }
  return result;
}

export function sleep(seconds) {
  const milliseconds = Math.max(0, Number(seconds) || 0) * 1000;
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function shanghaiDate() {
  return new Date(Date.now() + 8 * 60 * 60 * 1000);
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

function formatDate(date) {
  return `${date.getUTCFullYear()}-${pad2(date.getUTCMonth() + 1)}-${pad2(date.getUTCDate())}`;
}

export const DateTime = {
  now() {
    return shanghaiDate();
  },
  current_date() {
    return formatDate(shanghaiDate());
  },
  year() {
    return shanghaiDate().getUTCFullYear();
  },
  month() {
    return shanghaiDate().getUTCMonth() + 1;
  },
  day() {
    return shanghaiDate().getUTCDate();
  },
  week() {
    const day = shanghaiDate().getUTCDay();
    return day === 0 ? 7 : day;
  },
  format_timedelta(milliseconds) {
    const totalSeconds = Math.abs(Math.floor(milliseconds / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    return `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
  },
  get_offset_date(year, month, day, daysOffset = 1) {
    const utc = Date.UTC(pyInt(year), pyInt(month) - 1, pyInt(day));
    return formatDate(new Date(utc - pyInt(daysOffset) * 24 * 60 * 60 * 1000));
  },
};

export class ConfigResolver {
  constructor(qq, moduleName, defaultConfig, accountOverrides = {}) {
    this.qq = qq;
    this.moduleName = moduleName;
    this.defaultConfig = defaultConfig || {};
    this.accountConfig = this.resolveAccountConfig(accountOverrides || {});
  }

  resolveAccountConfig(overrides) {
    if (overrides[this.qq] && typeof overrides[this.qq] === "object") {
      return overrides[this.qq];
    }
    if (Object.values(TaskModule).some((moduleName) => Object.prototype.hasOwnProperty.call(overrides, moduleName))) {
      return overrides;
    }
    return {};
  }

  get(key) {
    const keys = key.split(".");
    const accountValue = this.deepGet(this.accountConfig?.[this.moduleName], keys);
    if (accountValue.found) {
      return accountValue.value;
    }
    const defaultValue = this.deepGet(this.defaultConfig?.[this.moduleName], keys);
    if (defaultValue.found) {
      return defaultValue.value;
    }
    throw new Error(`配置键 '${this.moduleName}.${key}' 未找到`);
  }

  deepGet(data, keys) {
    let current = data;
    for (const key of keys) {
      if (current === null || typeof current !== "object") {
        return { found: false, value: undefined };
      }
      if (!Object.prototype.hasOwnProperty.call(current, key)) {
        return { found: false, value: undefined };
      }
      current = current[key];
    }
    return { found: true, value: current };
  }
}

export class Client {
  static BASE_URL = "https://dld.qzapp.z.qq.com/qpet/cgi-bin/phonepk?";

  static HEADERS = {
    "User-Agent":
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
  };

  constructor(qq, cookies) {
    this.qq = qq;
    this.cookieHeader = Object.entries(cookies || {})
      .map(([name, value]) => `${name}=${value}`)
      .join("; ");
    this.html = "";
  }

  async get(path) {
    const url = `${Client.BASE_URL}${path}`;
    const headers = { ...Client.HEADERS };
    if (this.cookieHeader) {
      headers.Cookie = this.cookieHeader;
    }

    try {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const response = await fetch(url, {
          method: "GET",
          headers,
          redirect: "follow",
        });
        this.html = await boundedResponseText(response);
        if (this.html.includes("系统繁忙")) {
          await sleep(0.2);
          continue;
        }
        return this.html;
      }
      return this.html;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("redirect")) {
        throw new RequestError(`超过最大重定向次数（可能Cookie失效）: ${url}`);
      }
      throw new RequestError(`请求异常: ${message}`);
    }
  }
}

async function boundedResponseText(response, maxBytes = 1024 * 1024) {
  if (!response.body || !response.body.getReader) {
    return response.text();
  }

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.byteLength;
    if (total > maxBytes) {
      throw new RequestError(`响应超过 ${maxBytes} 字节，已停止读取`);
    }
    chunks.push(value);
  }

  const buffer = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    buffer.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(buffer);
}

export class DaLeDou {
  constructor(qq, client, configResolver) {
    this.qq = qq;
    this.client = client;
    this.configResolver = configResolver;
    this.html = "";
    this.task_name = null;
  }

  config(key) {
    return this.configResolver.get(key);
  }

  find(regex = "<br />(.*?)<") {
    if (!this.html) {
      return null;
    }
    const match = new RegExp(regex, "s").exec(this.html);
    return match && match.length > 1 ? match[1] : null;
  }

  findall(regex, html = null) {
    const content = html || this.html;
    if (!content) {
      return [];
    }
    const pattern = new RegExp(regex, "gs");
    const results = [];
    for (const match of content.matchAll(pattern)) {
      if (match.length === 2) {
        results.push(match[1]);
      } else if (match.length > 2) {
        results.push(match.slice(1));
      } else {
        results.push(match[0]);
      }
    }
    return results;
  }

  async get(path) {
    this.html = await this.client.get(path);
    return this.html;
  }

  log(message, taskName = null) {
    console.log(
      JSON.stringify({
        event: "task-log",
        qq: this.qq,
        task: taskName || this.task_name,
        message: message === undefined ? null : String(message),
      }),
    );
  }
}
