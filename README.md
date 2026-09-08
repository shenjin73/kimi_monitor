# kimi_monitor

macOS 原生 app，实时监控本机所有 Kimi Code / Claude Code CLI 会话的工作状态，同时展示套餐用量、Claude token 消耗和系统资源。主窗口 + 菜单栏图标，面板化设计，方便扩展。

![KimiMonitor 截图](screenshot.png)

## 界面

单页仪表盘（无侧栏，窗口可自由缩放），从上到下若干 section：

### Kimi / Claude 会话

每个 session 一个瓦片，内容：状态灯、状态描述、最后更新时间、工作目录。

- **动态栅格**：每行最多 4 个瓦片，瓦片宽度按数量自适应——1 个占满整行，2 个各半，3 个各 1/3，4 个及以上各 1/4 后换行
- **自动隐藏**：某类会话没有活跃 session 时，整个 section 消失；重新检测到会话再显示
- **Claude 瓦片**额外在右侧显示 token 用量：今日 / 近 7 天各一行，箭头图标区分输入（↓）和输出（↑）

| 状态 | 颜色 | 触发事件 |
| --- | --- | --- |
| 🔵 工作中 | 蓝 | `TurnStarted` / `UserPromptSubmit` / `UserPromptQueued` / `PreToolUse` / `SubagentStart` / `PermissionResult` |
| 🟠 等待用户 | 橙（呼吸灯动画） | `PermissionRequest` / `PreToolUse: AskUserQuestion` |
| 🟢 空闲 | 绿 | `Stop` / `StopFailure` / `Interrupt` / `SessionStart` |

- "等待用户"是呼吸灯效果（0.9s 周期缩放 + 透明度脉动），一眼定位在等你的会话
- CLI 每 60 秒发一次 `SessionHeartbeat`；**150 秒无心跳视为死会话**，自动从列表移除并清理状态文件（正常退出走 `SessionEnd` 立即移除）
- 右键瓦片：在 Finder 中打开工作目录 / 复制 Session ID；悬停显示完整会话标题

### 套餐用量

- **5 小时滚动窗口** 和 **每周配额** 各一张卡片：大号百分比（>70% 橙、>90% 红）+ 18pt 进度条 + 重置倒计时
- 右上角手动刷新按钮 + 最后更新时间

### 系统状态

CPU / GPU / 内存 / 风扇&温度四个环形仪表（线宽固定 25pt，圆环直径 150pt，单色 3D 管状描边 + 粗体标题），CPU/GPU/内存瓦片下方实时显示**该资源占用 Top 3 的进程及用量**（2 秒刷新）：

- CPU：Mach `host_processor_info` tick 差分；进程 Top3 来自 `ps -Aco … -r`；环中心下方小字显示**当前时钟频率**（IOReport 性能状态驻留加权，取最快集群）
- GPU：IOKit `IOAccelerator` PerformanceStatistics（Apple Silicon，免 sudo）；进程 Top3 遍历 `AGXAccelerator` 下的 `AGXDeviceUserClient`，按 `accumulatedGPUTime` 差分后归一化分摊到系统总利用率（与 mactop 同口径）；环中心下方小字显示 GPU 频率（`GPUPH` 通道加权）
- 内存：`host_statistics64`，active + wired + compressed，环中心显示百分比 + `已用/总量 GB`；进程 Top3 用 `top -l 1 -o mem` 的 **phys_footprint**（与活动监视器同口径，含 root 进程，无需权限）
- 风扇 / 温度：SMC 直读（AppleSMC，免 sudo）。环 = 全部风扇平均 RPM / 5500；下方三行显示 CPU 温度（`TCMb` Die 传感器）、GPU 温度（`Tg*` 组最热键，启动时探测后缓存）、**系统功耗**（IOKit `AppleSmartBattery` 的 `PowerTelemetryData`，取 `SystemPowerIn`/`BatteryPower`，>50 W 标红）；无风扇机型显示"无风扇"
- 进程名做友好化映射（如 `wdavdaemon*` → "Microsoft Defender"，`com.apple.WebKit*` → "WebKit …"）

### 菜单栏

图标聚合显示最需要关注的状态 + 会话数（如 `🟠 2`）；下拉菜单列出各会话状态，第一项"打开主窗口"。

## 数据来源与架构

```
Kimi CLI   ──hook事件(stdin JSON)──▶ report_status.py ──原子写入──▶ ~/.kimi-code/status/<session_id>.json
Claude CLI ──hook事件─────────────▶ claude_report_status.py ─────▶ ~/.claude/status/<session_id>.json
                                                                          ▲
KimiMonitor.app ──Session/ClaudeSessionMonitor 每 1s 轮询─────────────────┘
云端 API   ──GET {apiBase}/usages (Bearer token)──▶ QuotaMonitor 每 60s 刷新
~/.claude/projects/**/*.jsonl ────────────────────▶ ClaudeTokenMonitor 每 60s 统计 token
Mach / IOKit ─────────────────────────────────────▶ SystemMonitor 每 2s 采样
```

- **用量 token** 来自 `~/.kimi-code/credentials/kimi-code.json`（与 CLI 共享，只读 + 原子写回）。access_token 约 15 分钟过期，app 自动用 refresh_token 调 `{oauthHost}/api/oauth/token` 刷新；region 由 `~/.kimi-code/region` 决定（`cn`→kimi.com，其他→kimi.ai）。与 CLI 并发刷新偶发失败会在下一轮自愈。
- **Claude token 统计**：扫描 `~/.claude/projects/**/*.jsonl`，累加 assistant 消息的 `usage.input_tokens` / `output_tokens`，按 `timestamp` 分入今日 / 近 7 天两档。
- **扩展**：新增面板 = 加一个 `Monitor`（ObservableObject 单例）+ 一个 Section View，并在 `MainView` 里挂上。

## 使用

```bash
./install.sh          # 安装 hook 到 ~/.kimi-code/hooks/ 并追加 config.toml 规则（幂等）
./build.sh            # swiftc 编译打包为 KimiMonitor.app（需 Xcode CLT，macOS 13+）
open KimiMonitor.app
```

安装 hook 后需**重启 CLI 会话**让配置生效。开机自启：系统设置 → 通用 → 登录项中添加 `KimiMonitor.app`。

## 文件结构

```
hooks/report_status.py            # Kimi 状态上报 hook（事件→状态映射，含 AskUserQuestion 特判）
app/KimiMonitorApp.swift          # @main 入口：WindowGroup + 注入各 monitor
app/AppDelegate.swift             # 菜单栏 status item（聚合适配 + 下拉菜单）
app/Models.swift                  # 数据模型（SessionState / UsageResponse）与共享 helper
app/Monitors/
  SessionMonitor.swift            # 轮询 Kimi 状态目录，死会话剔除
  ClaudeSessionMonitor.swift      # 轮询 Claude 状态目录（~/.claude/status）
  ClaudeTokenMonitor.swift        # 扫描 ~/.claude/projects 统计 token（今日 / 近 7 天）
  QuotaMonitor.swift              # OAuth token 刷新 + /usages 拉取
  SystemMonitor.swift             # CPU / GPU / 内存 / SMC 传感器 / 系统功耗采样
  FrequencyReader.swift           # IOReport 时钟频率（CPU/GPU 性能状态驻留加权）
  SMC.swift                       # AppleSMC 读取（风扇 RPM / 温度键枚举）
app/Views/
  MainView.swift                  # 单页骨架（ScrollView + 各 Section）
  SessionsView.swift              # 会话瓦片（呼吸灯 + 动态栅格 + Claude token 列）
  QuotaView.swift                 # 配额卡片
  SystemView.swift                # 环形仪表 + 风扇温度功耗卡片
build.sh / install.sh
```
