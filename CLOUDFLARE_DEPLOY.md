# Cloudflare 云端挂机部署指南

本文档说明如何把本项目部署到 Cloudflare Worker，让 `noon` 和 `evening` 每天在云端自动运行，不再依赖本地电脑挂机。

## 1. 当前云端方案

当前正式方案是标准 JavaScript Worker，不再使用 Python Worker。

核心文件：

```text
cloudflare/
└── wrangler.jsonc
cloudflare_worker/
├── package.json
└── src/
    ├── index.js
    ├── runtime.js
    ├── config.js
    └── tasks/
        ├── common.js
        ├── noon.js
        └── evening.js
scripts/
├── generate_cloudflare_worker_js.py
├── cloudflare_verify.sh
├── cloudflare_first_deploy.sh
├── cloudflare_update_deploy.sh
├── cloudflare_update_secret.sh
└── cloudflare_post_deploy_check.sh
```

实现方式：

- `src/tasks/common.py`、`src/tasks/noon.py`、`src/tasks/evening.py` 仍是任务源码。
- `scripts/generate_cloudflare_worker_js.py` 会把 Python 任务和 `config/default.yaml` 生成到 `cloudflare_worker/src/`。
- `cloudflare_worker/src/index.js` 提供 `/health`、`/run`、Cron 和 Queue 消费者。
- Cron 只负责投递任务，真实执行由 Queue 按“账号 + 单个任务”链式执行。
- Cookie 使用 Cloudflare Secret，不写入仓库，不依赖本地 `config/dld_cookie.yaml`。
- 日期、星期、月份判断统一按北京时间 UTC+8。

## 2. 时间换算

Cloudflare Cron 使用 UTC。你特别提醒的“北京时间早上 8 点，Cloudflare 才是 0 点”就是这个规则：

```text
北京时间 = UTC + 8 小时
北京时间 08:00 = UTC 00:00
```

项目需要：

```text
noon    每天 13:01 北京时间
evening 每天 20:01 北京时间
```

写入 Cloudflare 的 Cron：

```text
1 5 * * *   -> 北京时间 13:01
1 12 * * *  -> 北京时间 20:01
```

配置位于 `cloudflare/wrangler.jsonc`。代码里的 `DateTime` 也按 UTC+8 计算，不依赖 Cloudflare 默认 UTC 日期。

## 3. 环境要求

需要本机已有：

```text
Node.js >= 22.0.0
uv
Cloudflare 账号
Cloudflare API Token
```

确认 Node：

```bash
node --version
```

应输出 `v22.x.x` 或更高版本，例如：

```text
v22.0.0
```

脚本只检查当前 shell 中的 `node` 是否满足最低版本要求，不会安装 Node，也不会强制切换到某个具体小版本。Wrangler 4.x 当前要求 Node.js `>=22.0.0`。

如果 `node --version` 低于 22，请先用你自己的版本管理工具切换到任意 22+ 版本，或把对应 `node` 放到当前 shell 的 `PATH` 后再执行脚本。

部署脚本默认从以下文件读取 Cloudflare API Token：

```text
.env.deploy.local
```

默认变量名是：

```text
CF_API_TOKEN_PRIMARY
```

脚本会先读取当前 shell 中的 `CF_API_TOKEN_PRIMARY`，如果没有，再读取 `.env.deploy.local`。

部署目标默认从以下本地配置读取：

```text
deploy/cloudflare-targets.local.json
```

首次使用时可以从示例复制：

```bash
cp deploy/cloudflare-targets.example.json deploy/cloudflare-targets.local.json
```

然后把 `accountId` 填成当前 Cloudflare 账号 ID。也可以直接导出 `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`，或用 `CLOUDFLARE_TARGET_CONFIG`、`CLOUDFLARE_TOKEN_ENV_FILE`、`CLOUDFLARE_TOKEN_ENV` 覆盖默认位置和变量名。脚本不会调用 `wrangler login`。

## 4. 首次部署

推荐直接运行首次部署向导：

```bash
bash scripts/cloudflare_first_deploy.sh
```

它会执行：

1. 检查 Node 版本。
2. 生成 JS Worker 任务代码。
3. 校验任务数、Cron、北京时间、Queue 链式执行和 Wrangler dry-run。
4. 读取 Cloudflare API Token 和 Account ID。
5. 创建 `daledou-cloud-queue` 和 `daledou-cloud-dlq`。
6. 部署 Worker。
7. 上传 `DALEDOU_COOKIES` 和 `RUN_TOKEN` Secret。

输入 Cookie 时，一行一个 Cookie；输入完成后单独输入 `END` 回车。

Cookie 示例：

```text
openId=...; accessToken=...; newuin=123456789
openId=...; accessToken=...; newuin=987654321
END
```

必须包含 `newuin`，项目用它识别账号。

`RUN_TOKEN` 至少 16 个字符，用于保护 `/run` 手动触发接口。

## 5. 手动部署命令

如果不用向导，也可以手动执行：

```bash
cd cloudflare
export CLOUDFLARE_API_TOKEN=你的API_TOKEN
export CLOUDFLARE_ACCOUNT_ID=你的ACCOUNT_ID
npx --yes wrangler queues create daledou-cloud-queue
npx --yes wrangler queues create daledou-cloud-dlq
cd ..
bash scripts/cloudflare_verify.sh
cd cloudflare
npx --yes wrangler deploy --config wrangler.jsonc
npx --yes wrangler secret put DALEDOU_COOKIES --config wrangler.jsonc
npx --yes wrangler secret put RUN_TOKEN --config wrangler.jsonc
```

上面 Queue 名称对应默认 `cloudflare/wrangler.jsonc`。如果你改过 Queue 名称，请按配置中的 `queues.producers[].queue`、`queues.consumers[].queue` 和 `dead_letter_queue` 创建。

## 6. 后续代码更新

首次部署成功后，后续改代码不需要重新走首次部署流程。更新脚本会幂等确认 `wrangler.jsonc` 中的 Queue 已存在；如果刚迁移到新账号且队列不存在，会自动创建。

先 dry-run：

```bash
bash scripts/cloudflare_update_deploy.sh --dry-run
```

正式发布：

```bash
bash scripts/cloudflare_update_deploy.sh
```

该脚本不会重新创建 Queue，也不会重新要求输入 Cookie 或 `RUN_TOKEN`。已有 Secret、Queue、Cron 会继续沿用。

## 7. 只更新 Secret

Cookie 失效时：

```bash
bash scripts/cloudflare_update_secret.sh cookies
```

轮换手动触发 Token：

```bash
bash scripts/cloudflare_update_secret.sh run-token
```

可选账号覆盖配置：

```bash
bash scripts/cloudflare_update_secret.sh account-config
bash scripts/cloudflare_update_secret.sh account-config /path/to/account-config.json
```

Secret 更新后无需重新部署代码，下一次请求和下一次 Cron 会自动使用新值。

## 8. 手动触发

部署后可手动投递任务：

```bash
curl -H "X-Run-Token: 你的RUN_TOKEN" "https://你的-worker地址/run?module=noon"
curl -H "X-Run-Token: 你的RUN_TOKEN" "https://你的-worker地址/run?module=evening"
```

指定任务：

```bash
curl -H "X-Run-Token: 你的RUN_TOKEN" "https://你的-worker地址/run?module=noon&task=每日奖励"
```

指定账号：

```bash
curl -H "X-Run-Token: 你的RUN_TOKEN" "https://你的-worker地址/run?module=noon&qq=123456789&task=每日奖励"
```

也支持：

```bash
Authorization: Bearer 你的RUN_TOKEN
```

不建议把 token 放到 URL 查询参数里。

## 9. 部署后检查

首次部署后运行：

```bash
bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN
```

生产环境建议优先使用自定义域名作为 Worker 地址。如果 `*.workers.dev` 原生域名访问出现 `1101`，但自定义域名 `/health` 正常返回 200，通常说明问题在 Cloudflare 的 `workers.dev` 子域路由或平台映射层，不是项目代码、Cookie、Cron、Queue 或 Secret 配置问题。

```bash
bash scripts/cloudflare_post_deploy_check.sh https://你的自定义域名 你的RUN_TOKEN
```

它不会投递真实任务，只检查：

- `/health` 返回 200。
- Queue 绑定存在。
- Cron 是 `1 5 * * *` 和 `1 12 * * *`。
- 未授权 `/run` 返回 401。
- 带 token 的未知账号返回 400，证明 `RUN_TOKEN` 和 `DALEDOU_COOKIES` 生效。

查看实时日志：

```bash
cd cloudflare
npx --yes wrangler tail
```

## 10. 本地验证

完整验证：

```bash
bash scripts/cloudflare_verify.sh
```

当前验证覆盖：

- Node 必须满足 `>= v22.0.0`。
- `wrangler.jsonc` 使用 JS Worker，不包含 `python_workers`。
- Cron 映射为北京时间 13:01 和 20:01。
- 配置中不包含 `cpu_ms`。
- Python 源任务列表与 JS Worker 生成后的任务列表一致。
- Cookie Secret 格式校验。
- JS Worker `/health`、`/run` 鉴权、Cron 投递、Queue 链式下一任务。
- Wrangler `deploy --dry-run` 可打包。

本地启动 Worker：

```bash
cd cloudflare
npx --yes wrangler dev --test-scheduled --config wrangler.jsonc
```

本地 Secret 可放入 `cloudflare/.dev.vars`，该文件已被忽略：

```dotenv
DALEDOU_COOKIES="openId=...; accessToken=...; newuin=123456789"
RUN_TOKEN="本地测试token至少16位"
```

## 11. 修改任务或默认配置

如果修改了：

- `src/tasks/common.py`
- `src/tasks/noon.py`
- `src/tasks/evening.py`
- `config/default.yaml`

执行：

```bash
bash scripts/cloudflare_verify.sh
```

验证脚本会自动重新生成：

```text
cloudflare_worker/src/config.js
cloudflare_worker/src/tasks/common.js
cloudflare_worker/src/tasks/noon.js
cloudflare_worker/src/tasks/evening.js
```

验证通过后再部署：

```bash
bash scripts/cloudflare_update_deploy.sh
```

## 12. 免费计划说明

当前方案按 Cloudflare Workers 免费计划整理：

- 不配置 `cpu_ms`。
- 不使用付费计划专属配置。
- 使用 Cron Triggers 和 Queues。
- Queue 消费者设置 `max_batch_size: 1`，一次只处理一个账号的一个任务。

Queues 在免费计划有每日免费操作额度。链式执行下，一个账号一个具体任务通常会产生写入、消费、确认等操作；账号很多、Cookie 长期失效或频繁重试时，需要关注 Cloudflare 控制台的 Queues 用量。

## 13. 故障排查

`/health` 不是 200：

- 先执行 `bash scripts/cloudflare_update_deploy.sh --dry-run`。
- 再确认线上部署是否使用 `cloudflare/wrangler.jsonc`。

`/run` 返回 401：

- `RUN_TOKEN` 不正确。
- 优先使用 `X-Run-Token` 或 `Authorization: Bearer`。

`/run` 返回 400 且提示找不到账号：

- `DALEDOU_COOKIES` 中没有该 `newuin`。
- 重新执行 `bash scripts/cloudflare_update_secret.sh cookies`。

任务进入重试或死信队列：

- Cookie 失效。
- 游戏维护或页面临时繁忙。
- 某个任务页面结构变化，需要更新正则或注册链接文本。

## 14. 最短流程

首次部署：

```bash
bash scripts/cloudflare_first_deploy.sh
bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN
```

后续改代码：

```bash
bash scripts/cloudflare_update_deploy.sh --dry-run
bash scripts/cloudflare_update_deploy.sh
```

只换 Cookie：

```bash
bash scripts/cloudflare_update_secret.sh cookies
```
