# Q宠大乐斗自动化助手完整使用指南

本文档面向第一次部署、本地日常运行、多账号维护和二次开发扩展。内容基于当前项目源码与默认配置梳理，覆盖项目能力、执行机制、安装配置、命令用法、任务清单、账号覆盖配置、日志排障和扩展规范。

## 1. 项目定位

本项目是一个 Q宠大乐斗文字版自动化脚本，主要用于自动完成日常、周常、月度赛季、限时活动和礼包领取类任务。

核心特性：

- 支持多账号 Cookie 配置。
- 支持最多 5 个账号并发执行。
- 支持午间任务和晚间任务两个模块。
- 支持无参数启动每日定时调度。
- 支持按模块、任务名、QQ 号精确手动执行。
- 支持全局默认配置和单账号覆盖配置。
- 每个账号独立输出日志，日志保留 30 天。
- 任务会先检查大乐斗老版首页是否存在对应入口，入口不存在则自动跳过。

项目适合放在本地电脑、服务器、NAS、长期在线环境或 Cloudflare Worker 云端定时环境中运行。

如果希望脱离本地挂机，部署到 Cloudflare Worker 云端定时运行，请查看根目录的 [CLOUDFLARE_DEPLOY.md](CLOUDFLARE_DEPLOY.md)。

## 2. 技术栈与目录结构

### 2.1 技术栈

- Python：要求 `>=3.13`
- 依赖管理：`uv`
- HTTP 客户端：`httpx`
- 日志：`loguru`
- 配置文件：`PyYAML`
- 定时调度：`schedule`
- Cloudflare 部署：`Node.js >= 22.0.0`，用于运行 Wrangler

### 2.2 目录结构

```text
daledou/
├── main.py                  # 程序主入口
├── pyproject.toml           # 项目元信息与依赖声明
├── README.md                # 完整使用指南
├── CLOUDFLARE_DEPLOY.md     # Cloudflare Worker 云端挂机部署指南
├── cloudflare/              # Cloudflare Worker 配置目录
│   └── wrangler.jsonc       # Worker、Cron、Queue 配置
├── cloudflare_worker/       # 标准 JS Worker 运行时代码
│   ├── package.json         # ESM 标记
│   └── src/
│       ├── index.js         # Worker 入口：health/run/Cron/Queue
│       ├── runtime.js       # JS 运行时、请求、配置、北京时间工具
│       ├── config.js        # 由 config/default.yaml 生成
│       └── tasks/           # 由 src/tasks/*.py 生成的 JS 任务
├── config/
│   └── default.yaml         # 全局默认任务配置
├── scripts/
│   ├── cloudflare_first_deploy.sh    # Cloudflare 首次部署向导
│   ├── cloudflare_update_deploy.sh   # Cloudflare 后续代码更新部署
│   ├── cloudflare_update_secret.sh   # Cloudflare 后续 Secret 更新
│   ├── cloudflare_verify.sh          # Cloudflare 部署前验证
│   ├── cloudflare_post_deploy_check.sh # Cloudflare 部署后基础检查
│   └── generate_cloudflare_worker_js.py # 生成 JS Worker 任务和配置
├── src/
│   ├── cli.py               # 命令行参数解析与帮助输出
│   ├── run.py               # 多账号并发任务执行器
│   ├── timing.py            # 定时任务调度
│   ├── tasks/
│   │   ├── register.py      # 任务模块与任务注册表
│   │   ├── common.py        # 午间/晚间复用任务逻辑
│   │   ├── noon.py          # 午间任务模块
│   │   └── evening.py       # 晚间任务模块
│   └── utils/
│       ├── client.py        # HTTP 请求封装
│       ├── config.py        # Cookie、默认配置、账号配置加载
│       ├── daledou.py       # 任务执行上下文对象
│       ├── date_time.py     # 日期时间工具
│       └── log.py           # 控制台和账号日志
├── log/                     # 运行后生成，账号日志目录
└── config/accounts/         # 运行后生成，账号覆盖配置目录
```

`.gitignore` 已忽略以下敏感或运行产物：

- `.venv`
- `.env*`
- `.dev.vars*`
- `secrets*.json`
- `log/`
- `config/accounts/*.yaml`
- `config/dld_cookie.yaml`
- `config/run_token.yaml`
- `node_modules/`
- `cloudflare/.wrangler/`
- `cloudflare/.venv/`
- `cloudflare/node_modules/`
- `cloudflare/.dev.vars*`
- `cloudflare/secrets*.json`
- `cloudflare_worker/.dev.vars*`
- `cloudflare_worker/secrets*.json`

因此 Cookie、运行 token、单账号配置和 Cloudflare 本地 Secret 不会默认提交到仓库。

## 3. 核心执行机制

### 3.1 任务模块

当前只有两个模块：

| 模块 | 含义 | 默认定时执行时间 |
| --- | --- | --- |
| `noon` | 午间任务 | 每天 `13:01:00` |
| `evening` | 晚间任务 | 每天 `20:01:00` |

日期、星期和月份判断统一使用上海时间 `Asia/Shanghai`。本地运行不再依赖系统时区，Cloudflare Worker 云端运行也不会受 UTC 默认时区影响。

### 3.2 任务入口校验

每个任务通过 `@register()` 注册，注册名必须与大乐斗老版首页中的链接文本一致。

执行时流程如下：

1. 访问老版首页：`cmd=index&style=1`
2. 判断首页是否包含 `>任务名<`
3. 包含则执行任务
4. 不包含则静默跳过

这意味着：

- 限时活动入口未出现时，对应任务不会执行。
- 即使手动运行 `uv run main.py evening.某活动`，如果首页没有该活动链接，也会跳过。
- 如果游戏页面改版、链接文本变化，任务可能不会再触发，需要更新注册名。

### 3.3 多账号并发

`TaskRunner` 会把所有 Cookie 账号放入队列，最多 5 个账号并发执行。

每个账号的执行流程：

1. 创建独立 HTTP 客户端。
2. 加载该账号配置解析器。
3. 访问大乐斗首页确认页面有效。
4. 按注册顺序逐个执行当前模块任务。
5. 单个任务异常会记录日志并继续后续任务。
6. 如果 Cookie 失效、首页异常或请求异常，会计入失败统计。

### 3.4 请求机制

请求基础地址：

```text
https://dld.qzapp.z.qq.com/qpet/cgi-bin/phonepk?
```

请求封装特点：

- 使用 Cookie 进行身份认证。
- 自动跟随重定向。
- 单次请求超时 10 秒。
- 遇到页面包含 `系统繁忙` 时最多重试 3 次。
- 重定向过多通常表示 Cookie 失效或登录状态异常。

### 3.5 日志机制

控制台会输出所有账号的简要执行信息。

每个账号还会生成独立日志：

```text
log/<QQ号>/<YYYY-MM-DD>.log
```

日志保留 30 天，每天轮转一次。

## 4. 安装与初始化

### 4.1 获取项目

```bash
git clone https://github.com/lu-oo/daledou.git
cd daledou
```

### 4.2 安装 uv

如果本机未安装 `uv`，请先安装：

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

安装后确认：

```bash
uv --version
```

### 4.3 安装依赖

在项目根目录执行：

```bash
uv sync
```

也可以直接运行命令，`uv` 会自动创建 `.venv` 并安装依赖：

```bash
uv run main.py -h
```

### 4.4 创建 Cookie 配置

手动创建文件：

```text
config/dld_cookie.yaml
```

内容格式：

```yaml
DALEDOU_COOKIES:
  - openId=你的openId; accessToken=你的accessToken; newuin=你的QQ号
  - openId=第二个账号openId; accessToken=第二个账号accessToken; newuin=第二个QQ号
```

注意事项：

- 每一行是一个账号完整 Cookie 字符串。
- 必须包含 `newuin`，项目用它识别 QQ 号。
- 多账号就继续添加多行。
- `config/dld_cookie.yaml` 是敏感文件，不要公开。

### 4.5 获取 Cookie

常见方式：

1. 手机安装 Via 浏览器，并设为默认浏览器。
2. 打开大乐斗文字版链接：

```text
https://dld.qzapp.z.qq.com/qpet/cgi-bin/phonepk?cmd=index&style=1
```

3. 选择一键登录。
4. 登录成功后等待几秒。
5. 在 Via 中查看当前页面 Cookie。
6. 复制 Cookie 到 `config/dld_cookie.yaml`。

### 4.6 验证安装

查看帮助：

```bash
uv run main.py -h
```

测试执行一个任务：

```bash
uv run main.py noon.邪神秘宝
```

如果没有配置 Cookie，会提示：

```text
请在 config/dld_cookie.yaml 中配置大乐斗 Cookie
```

## 5. 运行命令完整说明

### 5.1 启动定时任务

```bash
uv run main.py
```

无参数启动后，会按模块元数据自动注册定时任务：

- `noon`：每天 `13:01:00`
- `evening`：每天 `20:01:00`

建议长期运行时使用 `tmux`、`screen`、系统服务或进程守护工具。

### 5.2 查看帮助

```bash
uv run main.py -h
uv run main.py --help
uv run main.py help
```

### 5.3 执行某个模块的所有任务

执行所有账号的午间任务：

```bash
uv run main.py noon
```

执行所有账号的晚间任务：

```bash
uv run main.py evening
```

### 5.4 执行某个模块的单个任务

执行所有账号的午间 `邪神秘宝`：

```bash
uv run main.py noon.邪神秘宝
```

执行所有账号的晚间 `背包`：

```bash
uv run main.py evening.背包
```

### 5.5 指定账号执行整个模块

```bash
uv run main.py 123456789.noon
uv run main.py 123456789.evening
```

### 5.6 指定账号执行单个任务

```bash
uv run main.py 123456789.noon.矿洞
uv run main.py 123456789.evening.背包
```

### 5.7 命令格式总结

| 格式 | 含义 | 示例 |
| --- | --- | --- |
| `module` | 所有账号执行该模块所有任务 | `noon` |
| `module.task` | 所有账号执行该模块指定任务 | `evening.背包` |
| `qq.module` | 指定账号执行该模块所有任务 | `123456789.noon` |
| `qq.module.task` | 指定账号执行指定模块指定任务 | `123456789.noon.矿洞` |

## 6. 配置系统详解

### 6.1 配置文件位置

```text
config/
├── default.yaml             # 全局默认配置
├── dld_cookie.yaml          # Cookie 配置，需手动创建
└── accounts/
    ├── 123456789.yaml       # 单账号覆盖配置，自动创建
    └── 987654321.yaml
```

### 6.2 配置优先级

配置读取优先级：

```text
账号配置 config/accounts/<QQ号>.yaml
↓ 未找到
默认配置 config/default.yaml
↓ 未找到
抛出 ConfigKeyError
```

重要细节：

- 第一次运行某个账号时，会自动创建 `config/accounts/<QQ号>.yaml`。
- 自动创建的账号配置通常只有顶层模块：

```yaml
noon: null
evening: null
```

- 当账号配置中被读取的完整路径存在时，即使值是 `null`，也会覆盖默认配置。
- 当账号配置没有被读取的完整路径时，才会回退到 `default.yaml`。
- 例如任务读取 `矿洞.floor` 时，只有账号配置里存在 `noon.矿洞.floor` 才会覆盖；只写 `noon.矿洞: null` 不会覆盖 `floor`，会继续回退到默认配置。

### 6.3 单账号覆盖配置示例

例如只想让 QQ `123456789` 的矿洞打开第 5 层困难模式，可以编辑：

```text
config/accounts/123456789.yaml
```

写入：

```yaml
noon:
  矿洞:
    floor: 5
    mode: 3
evening: null
```

例如想让某个账号晚间背包只使用包含 `锦囊` 和 `周年福袋` 的物品：

```yaml
noon: null
evening:
  背包:
    使用:
      - 锦囊
      - 周年福袋
```

### 6.4 常用配置项说明

`config/default.yaml` 已包含大量注释，建议优先按默认注释修改。

常见配置项：

| 配置路径 | 含义 |
| --- | --- |
| `noon.华山论剑.战阵调整` | 华山论剑使用的侠士编队和挑战次数 |
| `noon.好友.乐斗次数` | 好友任务每日乐斗次数，默认 20 次用于补足活跃度 |
| `noon.好友.贡献药水.count` | 好友任务使用贡献药水次数 |
| `noon.侠侣.情师徒拜.enabled` | 是否包含情师徒拜相关对象 |
| `noon.群侠.设置战队` | 群侠报名使用的 5 名侠士 |
| `noon.巅峰之战进行中.id` | 巅峰之战报名阵营 |
| `noon.矿洞.floor` | 矿洞副本层数 |
| `noon.矿洞.mode` | 矿洞难度 |
| `noon.十二宫.id` | 十二宫目标宫殿 |
| `noon.历练` | 历练 BOSS ID 和挑战次数 |
| `noon.幻境.id` | 幻境副本 ID |
| `noon.门派.*.enabled` | 是否兑换门派高香、门派战书 |
| `noon.问鼎天下.region` | 问鼎天下攻占区域 |
| `noon.问鼎天下.count` | 问鼎天下 1 级资源点攻占次数 |
| `noon.飞升大作战.type` | 飞升报名模式 |
| `noon.飞升大作战.id` | 备战天赋激活目标 |
| `evening.江湖长梦.*.enabled` | 晚间江湖长梦副本是否自动运行 |
| `evening.背包.使用` | 背包自动使用物品名称匹配规则 |
| `evening.吉利兑.exchange` | 吉利兑截止日前一天兑换清单 |
| `evening.儿童节.id` | 儿童节疯狂许愿目标 |
| `evening.开学季.id` | 开学季疯狂许愿目标 |
| `evening.登录商店.id` | 登录商店兑换目标 |
| `evening.微信兑换.兑换码` | 微信兑换码 |
| `evening.生肖福卡.QQ` | 分享福卡目标 QQ |
| `evening.爱的同心结.QQ` | 赠送同心结目标 QQ 列表 |

### 6.5 配置键与任务名关系

YAML 中的任务键名必须与任务注册名一致。

正确示例：

```yaml
noon:
  矿洞:
    floor: 1
    mode: 1
```

错误示例：

```yaml
noon:
  noon.矿洞:
    floor: 1
```

代码内部读取配置时会自动限定当前模块，不需要在任务键里重复写 `noon` 或 `evening`。

## 7. 功能全景分析

### 7.1 午间模块功能

午间模块注册时间为 `13:01:00`，更偏向日常战斗、周常赛制、帮派、门派、资源、副本和活跃度任务。

已注册任务：

```text
邪神秘宝、华山论剑、分享、好友、帮友、侠侣、武林、群侠、结拜、巅峰之战进行中、矿洞、掠夺、踢馆、竞技场、十二宫、许愿、抢地盘、历练、镖行天下、幻境、群雄逐鹿、画卷迷踪、门派、门派邀请赛、会武、梦想之旅、问鼎天下、帮派商会、帮派远征军、帮派黄金联赛、任务派遣中心、武林盟主、全民乱斗、侠士客栈、江湖长梦、大侠回归、飞升大作战、深渊之潮、侠客岛、时空遗迹、世界树、龙凰之境、任务、我的帮派、帮派祭坛、每日奖励、领取徒弟经验、今日活跃度、仙武修真、乐斗黄历、器魂附魔、兵法、万圣节、乐斗能量、大笨钟、幸运金蛋、客栈同福、反向历练、节日福利、双旦福利、金秋福利、春节福利、多倍福利、新春拜年
```

主要能力拆解：

| 类别 | 代表任务 | 自动化行为 |
| --- | --- | --- |
| 日常领取 | 每日奖励、领取徒弟经验、乐斗黄历、器魂附魔 | 领取每日奖励、占卜、活动任务奖励 |
| 活跃度 | 今日活跃度、任务 | 完成或补足部分日常任务，领取活跃礼包 |
| 好友战斗 | 好友、帮友、侠侣、抢地盘 | 乐斗好友/帮友/侠侣 BOSS，随机攻占地盘 |
| 赛制报名 | 武林、群侠、结拜、巅峰之战、武林盟主 | 按星期或日期自动报名、竞猜、助威、领奖 |
| 副本挑战 | 矿洞、十二宫、历练、幻境、画卷迷踪、时空遗迹 | 根据配置选择副本、关卡或 BOSS 自动挑战 |
| 门派系统 | 门派、门派邀请赛、会武 | 上香、训练、兑换、挑战、领奖 |
| 帮派系统 | 我的帮派、帮派商会、帮派远征军、帮派黄金联赛、帮派祭坛 | 供奉、帮派任务、商会交易、远征、联赛、防守、祭坛 |
| 资源兑换 | 华山论剑、竞技场、问鼎天下、江湖长梦、深渊之潮、龙凰之境 | 按配置和日期兑换物品 |
| 派遣系统 | 任务派遣中心、侠客岛、侠士客栈 | 自动领取、筛选奖励、快速委派、处理客栈事件 |
| 赛季活动 | 飞升大作战、世界树、仙武修真、兵法 | 报名、温养、寻访、助威、奖励领取 |
| 限时活动 | 节日福利、双旦福利、金秋福利、春节福利、多倍福利、万圣节、乐斗能量、新春拜年 | 根据首页入口和日期自动运行活动逻辑 |

午间任务中的日期规则示例：

- `华山论剑`：每月 1-25 日挑战，26 日领奖和荣誉兑换。
- `竞技场`：每月 1-25 日挑战和领取奖励。
- `门派邀请赛`：周一、周二报名和领奖，其余日可按配置兑换并挑战。
- `会武`：周一至周三试炼，周四助威和兑换，周六领奖。
- `梦想之旅`：普通旅行每日执行，周四按配置进行梦幻旅行和礼包领取。
- `问鼎天下`：周一领奖兑换，周六淘汰赛助威，周日排名赛助威。
- `江湖长梦`：午间模块只在每月 20 日按配置兑换。
- `龙凰之境`：每月 1-3 日报名，4-25 日挑战，27 日领奖兑换。
- `万圣节`、`乐斗能量` 等活动：只有首页入口存在时才会触发。

### 7.2 晚间模块功能

晚间模块注册时间为 `20:01:00`，更偏向背包整理、合成升级、礼包领取、限时节日活动、免费抽奖和晚间活动。

已注册任务：

```text
邪神秘宝、星盘、帮派商会、任务派遣中心、侠士客栈、江湖长梦、深渊之潮、侠客岛、龙凰之境、背包、镶嵌、神匠坊、每日宝箱、猜单双、煮元宵、元宵节、刮刮卡、娃娃机、吉利兑、激运牌、回忆录、愚人节、儿童节、开学季、大笨钟、幸运金蛋、客栈同福、节日福利、双旦福利、金秋福利、春节福利、多倍福利、新春拜年、神魔转盘、乐斗驿站、幸运转盘、冰雪企缘、甜蜜夫妻、乐斗菜单、周周礼包、登录有礼、活跃礼包、清明上香、徽章战令、生肖福卡、长安盛会、深渊秘宝、中秋礼盒、双节签到、斗境探秘、春联大赛、预热礼包、豪侠出世、乐斗游记、喜从天降、微信兑换、浩劫宝箱、端午有礼、圣诞有礼、新春礼包、登录商店、盛世巡礼、5.1礼包、五一预订、好礼提升、周年祝福、周年预热、年兽大作战、新春登录礼、爱的同心结、重阳太白诗会
```

主要能力拆解：

| 类别 | 代表任务 | 自动化行为 |
| --- | --- | --- |
| 免费抽奖 | 邪神秘宝、神魔转盘、深渊秘宝、幸运金蛋、幸运转盘、刮刮卡 | 优先执行免费抽奖或已有抽奖次数 |
| 背包整理 | 背包、镶嵌、神匠坊、每日宝箱 | 使用匹配物品、魂珠升级、符石合成分解打造、开箱 |
| 晚间副本 | 江湖长梦、深渊之潮、侠客岛、龙凰之境 | 消耗配置中的材料或次数完成副本、领奖、挑战 |
| 常规领取 | 周周礼包、登录有礼、活跃礼包、徽章战令、乐斗驿站 | 自动领取礼包和活动奖励 |
| 节日活动 | 元宵节、愚人节、儿童节、开学季、清明上香、端午有礼、圣诞有礼、新春礼包等 | 根据首页入口执行活动逻辑 |
| 截止日兑换 | 吉利兑、双节签到、登录商店、盛世巡礼 | 按结束日期或周四触发兑换和领奖 |
| 互动分享 | 生肖福卡、爱的同心结、新春拜年 | 领取、分享、赠送、合卡、抽奖 |
| 答题活动 | 春联大赛 | 使用配置题库自动匹配上下联并领奖 |
| 特殊活动 | 年兽大作战、长安盛会、乐斗游记、喜从天降 | 按活动页面自动选择、挑战、兑换或领取 |

晚间任务中的日期规则示例：

- `星盘`：仅周四合成 2、3、4 级材料。
- `镶嵌`：仅周四升级魂珠。
- `神匠坊`：仅周四进行普通合成、符石分解和符石打造。
- `每日宝箱`：仅周四开箱，最多按逻辑开 10 次。
- `回忆录`：仅周四领取礼包。
- `吉利兑`：每日领取任务奖励，截止日前一天按配置兑换。
- `微信兑换`：仅周四使用配置中的兑换码。
- `端午有礼`：仅周四兑换礼包。
- `登录商店`：仅周四按配置 ID 兑换。
- `生肖福卡`：日常领取和分享，周四再合卡和抽奖。
- `喜从天降`：源码注释标注适合活动时间 `20:00-22:00`。

### 7.3 复用任务能力

`src/tasks/common.py` 提供午间和晚间复用能力：

- `邪神秘宝`：高级秘宝、极品秘宝抽奖。
- `帮派商会`：帮派宝库领取、交易会所交易、兑换商店兑换。
- `任务派遣中心`：领取完成奖励、筛选并接受任务、快速委派。
- `侠士客栈`：领取奖励、处理捣乱、按配置与黑市商人交换。
- `深渊秘境`：兑换副本次数、进入副本并挑战。
- `龙凰论武`：每月 4-25 日随机挑战。
- `客栈同福`：出现配置奖励时献酒。
- `幸运金蛋`、`大笨钟`：领取或执行对应活动操作。

## 8. 重要风险与使用建议

### 8.1 Cookie 安全

Cookie 等同于登录凭证，请注意：

- 不要把 `config/dld_cookie.yaml` 发给任何人。
- 不要提交到公开仓库。
- 如果怀疑泄露，应重新登录刷新 Cookie。

### 8.2 道具与资源消耗

项目多数逻辑优先领取免费奖励、免费抽奖或使用已有次数，但仍有任务会消耗游戏内道具、次数或活动材料，例如：

- 背包自动使用匹配物品。
- 历练、斗神塔、矿洞、副本挑战次数。
- 江湖长梦香炉。
- 飞升大作战玄铁令兑换。
- 门派高香、门派战书、试炼书等兑换。
- 各类活动截止日前兑换。
- 配置中 `quantity > 0` 的兑换项。

建议第一次使用时：

1. 先只执行单个账号。
2. 先只执行单个任务。
3. 查看日志确认行为符合预期。
4. 再开启全模块或定时任务。

### 8.3 首页入口决定任务是否执行

很多限时活动任务即使在源码中存在，也只有当大乐斗首页出现对应链接时才会执行。

如果某任务没有输出，常见原因：

- 首页当前没有该入口。
- 任务名与首页链接文本不一致。
- 活动已结束。
- 当前日期或星期不满足任务内部条件。
- 账号等级、帮派、战力、侠士、道具等条件不足。

### 8.4 系统时间

日期、星期和月份判断已经统一使用北京时间 `Asia/Shanghai`，代码会按 UTC+8 计算。

本地运行时仍建议确认系统时间没有明显漂移：

```bash
date
```

Cloudflare Worker 云端运行时不依赖机器所在时区；Cloudflare Cron 使用 UTC，所以北京时间早上 8 点等于 UTC 0 点。当前云端配置已经换算为：

```text
1 5 * * *   -> 北京时间 13:01
1 12 * * *  -> 北京时间 20:01
```

## 9. 推荐使用流程

### 9.1 第一次部署

```bash
uv sync
```

创建 Cookie：

```text
config/dld_cookie.yaml
```

查看帮助：

```bash
uv run main.py -h
```

测试一个低风险任务：

```bash
uv run main.py 你的QQ号.noon.每日奖励
```

查看日志：

```text
log/你的QQ号/<当天日期>.log
```

### 9.2 调整配置

先根据自己的账号情况修改：

```text
config/default.yaml
```

如果某个账号需要特殊设置，修改：

```text
config/accounts/<QQ号>.yaml
```

### 9.3 手动执行完整模块

```bash
uv run main.py 你的QQ号.noon
uv run main.py 你的QQ号.evening
```

确认没问题后执行所有账号：

```bash
uv run main.py noon
uv run main.py evening
```

### 9.4 长期定时运行

```bash
uv run main.py
```

长期部署时建议使用后台工具，例如：

```bash
tmux new -s daledou
uv run main.py
```

退出 tmux 会话：

```text
Ctrl+B 然后按 D
```

重新进入：

```bash
tmux attach -t daledou
```

## 10. 常见问题排查

### 10.1 提示 Cookie 文件不存在

现象：

```text
config/dld_cookie.yaml 不存在
```

处理：

创建 `config/dld_cookie.yaml`，并按格式写入：

```yaml
DALEDOU_COOKIES:
  - openId=...; accessToken=...; newuin=123456789
```

### 10.2 指定 QQ 运行时提示账号不存在

现象：

```text
账号 123456789 不存在或未配置 Cookie
```

检查：

- Cookie 中是否包含 `newuin=123456789`
- 命令中的 QQ 是否和 `newuin` 完全一致
- YAML 缩进是否正确

### 10.3 某任务手动执行也没有动作

原因通常是首页没有对应入口。

项目执行任务前会检查：

```text
>任务名<
```

如果当前首页不存在这个链接，任务会跳过。

### 10.4 提示非大乐斗首页

现象：

```text
非大乐斗首页（可能繁忙或者维护）
```

可能原因：

- Cookie 失效。
- 游戏维护。
- 大乐斗页面临时异常。
- 网络访问异常。

处理：

1. 浏览器打开文字版链接确认能否正常进入。
2. 重新获取 Cookie。
3. 稍后重试。

### 10.5 YAML 解析错误

常见原因：

- 缩进错误。
- 中文冒号 `：` 被用于 YAML 键值分隔。
- 列表项 `-` 缩进不一致。
- Cookie 中特殊字符未作为字符串处理。

建议 Cookie 行保持如下格式：

```yaml
DALEDOU_COOKIES:
  - openId=...; accessToken=...; newuin=...
```

### 10.6 配置键找不到

现象：

```text
ConfigKeyError: 配置键 'noon.xxx' 未找到
```

处理：

- 确认该任务配置存在于 `config/default.yaml` 或账号配置。
- 确认任务键名与注册任务名一致。
- 不要在模块内部重复写 `noon.` 或 `evening.` 前缀。

### 10.7 日志在哪里

日志文件路径：

```text
log/<QQ号>/<YYYY-MM-DD>.log
```

例如：

```text
log/123456789/2026-06-09.log
```

## 11. 二次开发指南

### 11.1 新增任务的基本步骤

如果新增午间任务，编辑：

```text
src/tasks/noon.py
```

如果新增晚间任务，编辑：

```text
src/tasks/evening.py
```

新增任务示例：

```python
@register()
async def 新活动(d: DaLeDou):
    await d.get("cmd=newAct&subtype=xxx")
    d.log(d.find())
```

如果首页链接文本不是合法 Python 函数名，例如 `5.1礼包`，使用显式注册：

```python
@register("5.1礼包")
async def 五一礼包(d: DaLeDou):
    await d.get("cmd=newAct&subtype=113&op=1&id=0")
    d.log(d.find())
```

### 11.2 注册名要求

注册名必须与大乐斗老版首页链接文本一致。

正确：

```python
@register()
async def 邪神秘宝(d: DaLeDou):
    ...
```

错误：

```python
@register("邪神宝藏")
async def 邪神秘宝(d: DaLeDou):
    ...
```

如果首页实际显示的是 `邪神秘宝`，注册成 `邪神宝藏` 会导致任务永远不会执行。

### 11.3 读取配置

任务中使用：

```python
value = d.config("矿洞.floor")
```

不要写：

```python
value = d.config("noon.矿洞.floor")
```

因为配置解析器已经知道当前模块。

### 11.4 请求与日志

请求页面：

```python
await d.get("cmd=some_command")
```

读取当前 HTML：

```python
d.html
```

查找首个匹配：

```python
result = d.find(r"奖励：(.*?)<")
```

查找所有匹配：

```python
items = d.findall(r'id=(\d+)">领取')
```

写日志：

```python
d.log("领取成功")
```

### 11.5 异常处理建议

任务内部异常会被 `TaskRunner` 捕获并写入日志，然后继续执行后续任务。

开发新任务时建议：

- 页面结构不确定时，先判断 `find()` 是否为 `None`。
- 兑换或消耗类任务要检查配置开关和数量。
- 免费次数相关任务要先判断页面是否存在免费入口。
- 日期和星期相关逻辑使用 `DateTime` 工具。
- 不要在任务中直接退出程序。

## 12. 维护建议

### 12.1 更新依赖

```bash
uv sync
```

### 12.2 查看当前任务清单

```bash
uv run main.py -h
```

这是最准确的任务清单，因为它来自当前源码注册表。

### 12.3 检查运行状态

定时运行时重点看：

- 控制台是否还在输出。
- `log/<QQ号>/` 是否生成当天日志。
- 是否有大量 Cookie、重定向、非首页错误。
- 是否有任务因为配置键缺失而失败。

### 12.4 配置修改原则

建议遵循：

- 先改单账号配置，再扩大到默认配置。
- 涉及兑换数量时先设小数量测试。
- 不想兑换的配置项设为 `0` 或 `enabled: false`。
- 不想让某账号执行某类兑换或消耗时，优先使用源码已经支持的 `enabled: false`、`quantity: 0`、`count: 0` 等配置；只有确认任务代码会读取并处理某个完整路径的 `null` 时，才建议用 `null` 覆盖。

## 13. 快速命令备忘

```bash
# 安装依赖
uv sync

# 查看帮助
uv run main.py -h

# 启动定时任务
uv run main.py

# 所有账号执行午间任务
uv run main.py noon

# 所有账号执行晚间任务
uv run main.py evening

# 所有账号执行单个任务
uv run main.py noon.每日奖励
uv run main.py evening.背包

# 指定账号执行模块
uv run main.py 123456789.noon
uv run main.py 123456789.evening

# 指定账号执行单个任务
uv run main.py 123456789.noon.矿洞
uv run main.py 123456789.evening.吉利兑

# Cloudflare 云端版部署前验证
bash scripts/cloudflare_verify.sh

# Cloudflare 首次部署向导：验证、读取 API Token、创建队列、设置 Secret、部署
bash scripts/cloudflare_first_deploy.sh

# Cloudflare 后续代码更新部署：不重新输入 Cookie / RUN_TOKEN
bash scripts/cloudflare_update_deploy.sh

# Cloudflare 后续只更新 Cookie / RUN_TOKEN / 帐号配置
bash scripts/cloudflare_update_secret.sh cookies
bash scripts/cloudflare_update_secret.sh run-token
bash scripts/cloudflare_update_secret.sh account-config
bash scripts/cloudflare_update_secret.sh account-config /path/to/account-config.json

# Cloudflare 部署后基础检查：不投递真实任务
bash scripts/cloudflare_post_deploy_check.sh https://你的-worker地址 你的RUN_TOKEN
```

## 14. 最小可用配置模板

只需要先创建 Cookie 文件即可运行：

```yaml
DALEDOU_COOKIES:
  - openId=...; accessToken=...; newuin=123456789
```

如果希望单账号只覆盖少量配置，可以这样写：

```yaml
noon:
  矿洞:
    floor: 1
    mode: 1
  十二宫:
    id: 1011
evening:
  背包:
    使用:
      - 锦囊
      - 周年福袋
```

## 15. 总结
1. 先配置 Cookie。
2. 用帮助命令确认任务存在。
3. 单账号、单任务测试。
4. 根据日志调整配置。
5. 再运行完整模块。
6. 本地使用 `uv run main.py` 开启长期定时调度；云端使用 `bash scripts/cloudflare_first_deploy.sh` 部署到 Cloudflare Worker 后由 Cron 自动触发。

只要维护好 Cookie、系统时间和配置文件，大部分日常、周常、赛季和活动任务都可以自动完成。
