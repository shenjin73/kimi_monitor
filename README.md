# kimi_monitor

macOS 原生 app，实时监控本机所有 Kimi Code / Claude Code / DeepSeek Harness (dsh) CLI 会话的工作状态，同时展示套餐用量、DeepSeek 账户（余额 / token）、Claude token 消耗和系统资源。主窗口 + 菜单栏图标，面板化设计，方便扩展。

![KimiMonitor 截图](screenshot.png)

## 界面

单页仪表盘（无侧栏，窗口可自由缩放），从上到下若干 section：

### 会话（Kimi / Claude / DSH 合并）

三类 CLI 的会话**合并成一个 section**，不再各占一块。每个 session 一个瓦片，内容：工具徽标、状态灯、状态描述、最后更新时间、会话标题、工作目录。

- **只显示需要关注的**：🔵 工作中 与 🟠 等待用户；**空闲（🟢）和离线（⚪）完全不展示**
- **全空闲时留占位**：section 不消失，显示 `✓ 无进行中的会话` + `N 个空闲会话已隐藏`，一眼确认是"真没在跑"而不是面板坏了
- **工具徽标**：瓦片左上角标出 `Kimi` / `Claude` / `DSH`（青 / 紫 / 靛，刻意避开状态色，不会被误读成状态）
- **动态栅格**：每行最多 4 个瓦片，瓦片宽度按数量自适应——1 个占满整行，2 个各半，3 个各 1/3，4 个及以上各 1/4 后换行
- **排序**：等待用户的最前，其余按最后活动时间倒序；标题右侧显示"N 个在等你"
- **右侧数字**：Claude 瓦片显示今日 / 近 7 天 token（项目级）；DSH 瓦片显示该会话累计 token（投影缓存的 `tokenUsage.totals`，输入含 cache read）+ DeepSeek **账户余额**（同一账号，明细在 tooltip 里）；Kimi 暂无额外数字

| 状态 | 颜色 | 触发事件 |
| --- | --- | --- |
| 🔵 工作中 | 蓝 | `TurnStarted` / `UserPromptSubmit` / `UserPromptQueued` / `PreToolUse` / `SubagentStart` / `PermissionResult` |
| 🟠 等待用户 | 橙（呼吸灯动画） | `PermissionRequest` / `PreToolUse: AskUserQuestion` |
| 🟢 空闲 | 绿 | `Stop` / `StopFailure` / `Interrupt` / `SessionStart`（不展示）|

- "等待用户"是呼吸灯效果（0.9s 周期缩放 + 透明度脉动），一眼定位在等你的会话
- CLI 每 60 秒发一次 `SessionHeartbeat`；**150 秒无心跳视为死会话**，自动从列表移除并清理状态文件（正常退出走 `SessionEnd` 立即移除）
- **DSH 没有心跳也没有 `SessionEnd`**，改用内核事实判活：dsh 在整个会话生命周期内对 `session.lock` 持有 `flock(2)`，锁随进程消失，app 每秒探测一次；进程已退出且状态陈旧即移除
- 右键瓦片：在 Finder 中打开工作目录 / 复制 Session ID；悬停显示完整会话标题

DSH 会话的状态判读（`DshSessionMonitor`）合并两个来源，哪个能拿到就用哪个：

| 现象 | 判定 | 来源 |
| --- | --- | --- |
| hook 写了 `waiting_user` 且没有正在生成的 step | 🟠 等待用户 | `~/.dsh/status/*.json` |
| `sessionStats.openStep != null` | 🔵 工作中（模型正在生成） | 投影缓存 |
| `sessionStats.pendingCalls` 非空 | 🔵 工作中（工具执行中） | 投影缓存 |
| `pendingCalls` 非空**且会话日志末尾有未应答的 `approval/asked`** | 🟠 等待用户（审批弹窗） | 会话日志 |
| 其余 | 🟢 空闲 | 两者 |

> **"工具 pending 多久"不能用来猜审批。** dsh 没有任何事件或投影行表示"正在等审批"，而桥接的 `PreToolUse` 在审批询问**之前**触发，所以审批阻塞和慢工具在 hook 和投影里完全同形（hook 说 `working` + 一个 pending call + `openStep` 为空）。曾经用「pending 超过 12 秒 = 在等审批」去猜，结果**任何超过 12 秒的工具**（编译、跑测试、几分钟的 sub-agent）都被误判成"等待用户"。
>
> 现在审批改由**会话日志**判断：dsh 把 `approval/asked{id}` / `approval/decided{id}` 写进 `~/.dsh/sessions/**/session.v3.jsonl.zstd`，而弹窗挂着时日志不再追加任何东西，所以"没配对的 asked"一定落在最后几条记录里。日志虽是 zstd，但 dsh 每次追加都 flush 成一个**独立帧**（实测 858KB = 401 帧），因此只读末尾 64KB、从帧边界（zstd magic）开始解压就够（~6ms），结论再按 (size, mtime) 缓存——弹窗挂着期间日志不变，等于零开销。其余工具执行期间一律「工作中」；`ask_user_question` 仍走 hook 的 `waiting_user`。找不到 `zstd` 命令时探测自动降级为"不亮红灯"，不会误报。

> 投影缓存（`~/.dsh/storages/session_projcache/sessions/*.json`）由 dsh 自己在会话创建、`turn/end`、会话释放以及最多 5s 一次的节流点写入，**零配置即可用**；hook 只是让 `ask_user_question` 这类"等待用户"提前几秒精确落地。
>
> **monitor 层的空闲保留期是 10 分钟**（界面本来就不显示空闲，这一层只是给 session 列表封顶）：dsh 只要把会话加载在进程里就一直持锁，所以"打开过"的旧会话不会像 Kimi/Claude 那样心跳超时消失。判定用的不是检查点文件的 mtime（dsh 会周期性重写它，即使什么都没发生），而是语义时间戳（最后提问 / step 起点 / 工具调用 / hook 事件），并在观察到状态真正变化时重置为"现在"。工作中 / 等待用户的会话不受此限制。

### DeepSeek 账户

DeepSeek 的数字出现在两个地方：**DSH 会话瓦片右侧**一行 `余额 ¥15.51`（≤¥5 橙、≤¥1 或不可用红并带警告图标，悬停看该币种的赠送 / 充值明细；**没有工作中/等待用户的 DSH 会话时瓦片不出现，这行也就看不到**），以及**套餐用量里的 DeepSeek 瓦片**（与配额卡片同排，余额 + token 用量，见下节）。

余额来自官方 API，消费与 token 来自开放平台，两者独立：

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| 余额 | `GET api.deepseek.com/user/balance` | key 复用 dsh 凭据库 `~/.dsh/.credentials.yaml` 的 `refs.DEEPSEEK_API_KEY`（支持字面量、`env:NAME` 间接引用、`DEEPSEEK_API_KEY` 环境变量），每 5 分钟 + 手动刷新 |
| 累计消费 / 累计 token / 今日用量 / 请求次数 | `platform.deepseek.com` 的 `/api/v0/users/get_user_summary`、`/api/v0/usage/by_api_key/{amount,cost}` | 与开放平台「用量」页同一套数字；**只认网页登录的 `userToken`，API key 会被拒（`40003 Authorization Failed`）**，所以是可选的 |

### 套餐用量

- **Kimi5小时窗口** 和 **Kimi每周配额** 各一张卡片：大号百分比（>70% 橙、>90% 红）+ 18pt 进度条 + 重置倒计时
- **DeepSeek 账户瓦片**：**和两张配额卡片排在同一行，各占 1/3 宽度**（配额接口失败时它独占整行）。瓦片上只显示 **余额（大号数字）+ 累计token使用量 + 今日token使用量**，平台来源时再多一行请求次数。因为只有 1/3 宽，数字是**上下排列的 label/value 行**，不是横向铺开；三张卡片底边对齐（配额卡的重置倒计时、DeepSeek 的 token 按钮都贴底）
- **"今日"两种来源都拿得到**：平台模式直接读开放平台的当日口径（GMT+8）；**本机模式回放 dsh 会话日志算**——投影缓存只有会话生命周期的 `totals` 和最后一个 step 的 `last`，没有按天分桶，但 `~/.dsh/sessions/<cwd>/<id>/session.v3.jsonl.zstd` 里有**每条 assistant 消息的时间戳和完整 usage**，按本地时区归日求和即可（全部会话合计）。日志是 zstd 压缩、系统和 Foundation 都不带 zstd，所以走一个 `zstd` 命令解压（homebrew / conda 常见路径都试，找不到就显示 `今日token使用量 —` 并在 tooltip 说明）
- 右上角手动刷新按钮 + 最后更新时间：**一次点击同时刷新配额和 DeepSeek 两个数据源**，时间取两者较新的

DeepSeek 瓦片默认走**本机统计**：

- **本机统计（默认）**：token 用量汇总本机全部 dsh 会话的投影缓存 `tokenUsage.totals`（**精确**，输入 = 未命中缓存 + 缓存命中），今日用量由 `DshTokenLog` 回放会话日志得到
- **开放平台（可选，界面里没有开关）**：代码里保留了平台私有接口的实现，想要账户口径（今日消费金额、请求次数、跨机器汇总）时，手动提供 `userToken` 即可自动切换——取法：登录 platform.deepseek.com → 开发者工具 Console 执行 `localStorage.getItem('userToken')` 复制其中的 `value`，然后写进 `~/.kimi-monitor/deepseek.json`（`{"platformToken":"…"}`，权限 600，**不碰 dsh 的凭据库**）或设环境变量 `DEEPSEEK_PLATFORM_TOKEN`。拿不到就回退到本机统计（瓦片上不再显示数据来源标记）
- 平台侧累计 token 的统计区间是 **2026-08-01 起**（平台保留期），查询按 **≤31 天分窗累加**，所以日期再往后也不会因为区间过宽而失败
- 悬停各数字看口径：余额看赠送 / 充值明细，token 看输入 / 缓存命中 / 输出的拆分与统计区间

### 系统状态

CPU / GPU / 内存 / 风扇&温度四个环形仪表（线宽固定 25pt，圆环直径 150pt，单色 3D 管状描边 + 粗体标题），CPU/GPU/内存瓦片下方实时显示**该资源占用 Top 3 的进程及用量**（2 秒刷新）：

- CPU：Mach `host_processor_info` tick 差分；进程 Top3 来自 `ps -Aco … -r`；环中心下方小字显示**当前时钟频率**（IOReport 性能状态驻留加权，取最快集群）
- GPU：IOKit `IOAccelerator` PerformanceStatistics（Apple Silicon，免 sudo）；进程 Top3 遍历 `AGXAccelerator` 下的 `AGXDeviceUserClient`，按 `accumulatedGPUTime` 差分后归一化分摊到系统总利用率（与 mactop 同口径）；环中心下方小字显示 GPU 频率（`GPUPH` 通道加权）
- 内存：`host_statistics64`，active + wired + compressed，环中心显示百分比 + `已用/总量 GB`；进程 Top3 用 `top -l 1 -o mem` 的 **phys_footprint**（与活动监视器同口径，含 root 进程，无需权限）
- 风扇 / 温度：SMC 直读（AppleSMC，免 sudo）。环 = 全部风扇平均 RPM / 5500；下方三行显示 CPU 温度（`TCMb` Die 传感器）、GPU 温度（`Tg*` 组最热键，启动时探测后缓存）、**系统功耗**（IOKit `AppleSmartBattery` 的 `PowerTelemetryData`，取 `SystemPowerIn`/`BatteryPower`，>50 W 标红）；无风扇机型显示"无风扇"
- 进程名做友好化映射（如 `wdavdaemon*` → "Microsoft Defender"，`com.apple.WebKit*` → "WebKit …"）

### 菜单栏

与主窗口同一套规则：只统计**工作中 / 等待用户**的会话，图标显示最需要关注的状态 + 数量（如 `🟠 2`），覆盖 Kimi / Claude / DSH 三类；下拉菜单每行是 `🟠 DSH · 会话标题 — 等待用户`，第一项"打开主窗口"。没有工作中的会话时显示 `◦ 无会话`。

## 数据来源与架构

```
Kimi CLI   ──hook事件(stdin JSON)──▶ report_status.py ──原子写入──▶ ~/.kimi-code/status/<session_id>.json
Claude CLI ──hook事件─────────────▶ claude_report_status.py ─────▶ ~/.claude/status/<session_id>.json
dsh        ──hook桥接(Claude方言)──▶ dsh_report_status.py ──────▶ ~/.dsh/status/<session_id>.json
dsh 内部   ──投影检查点(自我写入)──────────────────────────────▶ ~/.dsh/storages/session_projcache/sessions/*.json
dsh 内核   ──flock(session.lock)──────────────────────────────▶ ~/.dsh/sessions/<cwd>/<session_id>/session.lock
                                                                          ▲
KimiMonitor.app ──Session/ClaudeSession/DshSessionMonitor 每 1s 轮询───────┘
云端 API   ──GET {apiBase}/usages (Bearer token)──▶ QuotaMonitor 每 60s 刷新
DeepSeek   ──GET api.deepseek.com/user/balance───▶ DeepSeekMonitor 每 5min 刷新
平台用量   ──GET platform.deepseek.com/api/v0/…──▶ └ 需 userToken；无则回退本机统计
~/.claude/projects/**/*.jsonl ────────────────────▶ ClaudeTokenMonitor 每 60s 统计 token
Mach / IOKit ─────────────────────────────────────▶ SystemMonitor 每 2s 采样
```

- **用量 token** 来自 `~/.kimi-code/credentials/kimi-code.json`（与 CLI 共享，只读 + 原子写回）。access_token 约 15 分钟过期，app 自动用 refresh_token 调 `{oauthHost}/api/oauth/token` 刷新；region 由 `~/.kimi-code/region` 决定（`cn`→kimi.com，其他→kimi.ai）。与 CLI 并发刷新偶发失败会在下一轮自愈。
- **Claude token 统计**：扫描 `~/.claude/projects/**/*.jsonl`，累加 assistant 消息的 `usage.input_tokens` / `output_tokens`，按 `timestamp` 分入今日 / 近 7 天两档。
- **dsh 状态**：`DshSessionMonitor` 合并 hook 状态文件、投影缓存与 `flock` 存活探测，**没有 hook 也能工作**（见上文"DSH 会话的状态判读"）。
- **DeepSeek 账户**：`DeepSeekMonitor` 用一个 API key 查余额、用可选的平台 `userToken` 查累计消费与 token；没有 token 时读 `~/.dsh/storages/session_projcache/sessions/*.json` 汇总本机 token，并由 `DshTokenLog` 回放 `~/.dsh/sessions/*/*/session*.jsonl.zstd` 得到今日用量（zstd 由外部 `zstd` 命令解压，约 0.5s/次）。平台接口是私有的、面向网页的，请求带浏览器 UA 与 `origin`/`referer`，否则会被风控挡成 HTML 而不是 JSON。
- **扩展**：新增面板 = 加一个 `Monitor`（ObservableObject 单例）+ 一个 Section View，并在 `MainView` 里挂上。

## 使用

```bash
./install.sh          # 安装 Kimi hook 与 dsh hook 桥接（幂等）
./build.sh            # swiftc 编译打包为 KimiMonitor.app（需 Xcode CLT，macOS 13+）
open KimiMonitor.app
```

`install.sh` 做三件事：

1. 把 `hooks/report_status.py` 装到 `~/.kimi-code/hooks/` 并追加 `config.toml` 规则
2. 把 `hooks/dsh_report_status.py` 装到 `$DSH_HOME/hooks/`，写一份只属于本 app 的 `$DSH_HOME/kimi-monitor-hooks.json`
3. 在 home 级 patch 层 `$DSH_HOME/cordis.patch.yml` 里挂载 `@deepseek-ai/dsh-hooks-claude-code`（dsh 自带、无需安装依赖），让上面那份 hooks.json 在会话/提示/工具/停止时刻触发

`cordis.patch.yml` 已有你自己的 patch 条目时脚本不会改写，只打印要粘贴的片段。

安装后需**重启 CLI 会话**让 Kimi 配置生效；dsh 侧 `patchReload: live` 会热加载，重启 dsh 最保险。开机自启：系统设置 → 通用 → 登录项中添加 `KimiMonitor.app`。

> **dsh hook 的沙箱前提**：hook 命令通过 `ctx.shell` 执行，受 dsh 的**部署**文件沙箱约束，root = dsh 进程启动目录。因此只有从 `$HOME`（或 `~/.dsh` 的上级目录）启动 dsh，hook 才写得进 `~/.dsh/status`——`dsh web` 默认就在 `$HOME` 下启动，符合条件。若从其他目录启动，hook 写入会被拒（不影响会话），app 自动退回纯投影缓存判读。

## 文件结构

```
hooks/report_status.py            # Kimi 状态上报 hook（事件→状态映射，含 AskUserQuestion 特判）
hooks/dsh_report_status.py        # dsh 状态上报 hook（Claude Code 方言，经 dsh-hooks-claude-code 桥接触发）
app/KimiMonitorApp.swift          # @main 入口：WindowGroup + 注入各 monitor
app/AppDelegate.swift             # 菜单栏 status item（聚合适配 + 下拉菜单）
app/Models.swift                  # 数据模型（SessionState / DshProjection / DeepSeekBalance / 平台用量 / UsageResponse）
app/Monitors/
  SessionMonitor.swift            # 轮询 Kimi 状态目录，死会话剔除
  ClaudeSessionMonitor.swift      # 轮询 Claude 状态目录（~/.claude/status）
  DshSessionMonitor.swift         # dsh：hook 状态 + 投影缓存 + flock 存活探测
  ClaudeTokenMonitor.swift        # 扫描 ~/.claude/projects 统计 token（今日 / 近 7 天）
  DeepSeekMonitor.swift           # DeepSeek 余额 + 开放平台累计消费/token（可选 userToken）+ 本机回退
  DshTokenLog.swift               # 回放 zstd 会话日志，按本地日期汇总 token（今日用量）
  DshApprovalLog.swift            # 读会话日志尾部的 approval/asked 配对，判定审批弹窗
  QuotaMonitor.swift              # OAuth token 刷新 + /usages 拉取
  SystemMonitor.swift             # CPU / GPU / 内存 / SMC 传感器 / 系统功耗采样
  FrequencyReader.swift           # IOReport 时钟频率（CPU/GPU 性能状态驻留加权）
  SMC.swift                       # AppleSMC 读取（风扇 RPM / 温度键枚举）
app/Views/
  MainView.swift                  # 单页骨架（ScrollView + 各 Section）
  SessionsView.swift              # 合并会话瓦片（工具徽标 + 呼吸灯 + 动态栅格 + token/余额列）
  QuotaView.swift                 # 套餐用量：配额卡片 + DeepSeek 账户瓦片（含刷新）
  DeepSeekCard.swift              # DeepSeek 账户瓦片 + userToken 输入
  SystemView.swift                # 环形仪表 + 风扇温度功耗卡片
build.sh / install.sh
```
