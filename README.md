# kimi_monitor

macOS 原生 app，监控本机 Kimi Code CLI 状态。主窗口 + 菜单栏图标，面板化设计，方便扩展。

## 面板

单页仪表盘（无侧栏，自适应窗口宽度）：

- **Kimi 会话** — 所有 session 的实时状态：🔵 工作中 / 🟠 等待用户 / 🟢 空闲；150 秒无心跳视为死会话，自动从列表移除并清理状态文件
- **套餐用量** — 5 小时滚动窗口、每周配额（百分比 + 进度条 + 重置倒计时）
- **系统状态** — CPU / GPU / 内存环形仪表（GPU 走 IOKit，免 sudo；内存口径与活动监视器一致）

菜单栏图标保留：聚合显示最需要关注的状态 + 会话数，菜单第一项"打开主窗口"。

## 数据来源

```
Kimi CLI ──hook事件──▶ report_status.py ──▶ ~/.kimi-code/status/<session_id>.json ──▶ SessionMonitor(1s 轮询)
云端 API ──GET {apiBase}/usages(Bearer token)──────────────────────────────────────▶ QuotaMonitor(60s 轮询)
Mach host_processor_info / host_statistics64 / IOKit IOAccelerator ────────────────▶ SystemMonitor(2s 采样)
```

- 用量 token 来自 `~/.kimi-code/credentials/kimi-code.json`（与 CLI 共享）。access_token 15 分钟过期，app 自动用 refresh_token 调 `{oauthHost}/api/oauth/token` 刷新并原子写回；region 由 `~/.kimi-code/region` 决定（cn→kimi.com / global→kimi.ai）。与 CLI 并发刷新偶发失败会在下一轮自愈。
- 新增面板 = 加一个 `Monitor`(ObservableObject 单例) + 一个 Section View，并在 `MainView` 里挂上。

## 使用

```bash
./install.sh          # 安装 hook + 追加 config.toml（幂等）
./build.sh            # swiftc 编译打包（需 Xcode CLT，macOS 13+）
open KimiMonitor.app
```

## 文件结构

```
hooks/report_status.py        # 状态上报 hook
app/KimiMonitorApp.swift      # @main 入口，WindowGroup + 注入各 monitor
app/AppDelegate.swift         # 菜单栏 status item
app/Models.swift              # 数据模型与共享 helper
app/Monitors/SessionMonitor.swift
app/Monitors/QuotaMonitor.swift
app/Monitors/SystemMonitor.swift
app/Views/MainView.swift      # 单页仪表盘骨架（ScrollView + 各 Section）
app/Views/SessionsView.swift / QuotaView.swift / SystemView.swift
build.sh / install.sh
```
