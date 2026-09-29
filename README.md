# dsh-windows-launcher

A Windows desktop launcher for [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (`dsh web`)
with a startup progress window, plus a dsh plugin that shuts the instance down after the browser disconnects.

面向 Windows 的 DeepSeek Harness 桌面启动套件，两部分一次装好：

| 部分 | 是什么 | 运行在哪 |
| --- | --- | --- |
| **启动进度窗**（`launcher/`） | 桌面快捷方式 → 无黑窗启动 `dsh web`，显示带阶段文字、计时和进度条的小卡片，就绪后在 Edge 新窗口打开并置前 | 启动器进程（dsh 起来**之前**） |
<img width="892" height="250" alt="image" src="https://github.com/user-attachments/assets/63d8ade9-d955-4708-819a-88b41ba90153" />


进度窗必须在 dsh 启动前就出现，所以它做不成 dsh 插件（插件要等服务起来才会加载）。
两者放在同一个仓库里，由 `install.ps1` 一次装好。

配合起来的效果：**点图标 → 进度窗 → 浏览器打开；关掉浏览器 → 5 秒后后台服务自动退出；再点图标 → 冷启动。**
后台不会留一个没人用的 node 进程。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1（系统自带）
- Node.js，并已全局安装 dsh：`npm i -g @deepseek-ai/dsh`
- 推荐 Microsoft Edge（没有 Edge 时退回默认浏览器，但不保证窗口置前）

## 安装

```powershell
git clone https://github.com/xy-12177/dsh-windows-launcher.git
cd dsh-windows-launcher
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` 会：

1. `dsh plugin --profile web add <本仓库>` —— 以**链接**方式注册插件，所以克隆目录别删、别挪（挪了就重跑一次）
2. 把 `launcher/` 复制到 `%LOCALAPPDATA%\DeepSeekHarness\`，并写入 `dsh-launcher.json`
3. 在桌面创建 “DeepSeek Harness” 快捷方式

可选参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-WorkDir` | `%USERPROFILE%\dsh-workspace` | dsh 的工作目录（它的沙箱工作区） |
| `-Port` | `4080` | 监听端口 |
| `-DshProfile` | `web` | 插件装进哪个 dsh profile |
| `-AppWindow` | 关 | 用 Edge `--app` 无地址栏窗口打开 |
| `-SkipPlugin` / `-SkipLauncher` | — | 只装其中一半 |

装完如果已经有 dsh web 在跑，先停掉它再点图标，插件才会加载：

```powershell
powershell -File "$env:LOCALAPPDATA\DeepSeekHarness\stop-dsh.ps1"
```

> **WorkDir 注意**：dsh 沙箱会给工作区打 Low 完整性标签。
> - 不要把 WorkDir 设成 `%LOCALAPPDATA%\DeepSeekHarness` 或它的上级，否则快捷方式图标会变空白（安装脚本会拦）。
> - 放在非系统盘（如 `D:\work`）时，若 dsh 报 `SetNamedSecurityInfoW failed (Win32 5)`，给自己授完全控制即可，无需管理员：
>   `icacls D:\work /grant "%USERNAME%:(OI)(CI)F"`

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1            # 全部移除
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepPlugin # 只移除启动器
```

工作目录不会被删除。

## 启动器是怎么工作的

- `start-dsh.vbs` 以窗口样式 0 启动 PowerShell，全程没有控制台黑窗。
- `start-dsh.ps1` 直接用 `node.exe` 跑 dsh 的 `bin.js web --no-open`，输出重定向到 `.run\`。
  从日志里读回带 token 的 URL，再用 `msedge --new-window` 打开，并主动抢前台。
  （dsh 自己的 ShellExecute 在 Edge 已开时只会塞一个后台标签页。）
- token 和 PID 缓存在 `.run\state.json`。服务还活着时再点图标，会复用它直接打开，不会重复启动。
- 进度窗是编译进脚本的 C# WinForms，跑在独立 STA 线程上，90 秒等待期间也不会“未响应”。
  它跟随系统深浅色，支持高 DPI，Win11 下是圆角加阴影。
- 任何失败都会弹 MessageBox，附上服务端日志末尾。
- `stop-dsh.ps1`：结束占用端口的进程，并清掉缓存的 token。

## 自动关闭插件

每个浏览器页面都会通过 `/api/remote.mux` 保持一条 `$events` 流。
插件轮询 `ctx.typertGateway.remoteEventClients`：数量为 0 且持续 `disconnectGraceMs` 后，调用 `ctx.appExit(0)`。
同时它会挂一个 `unref()` 的 8 秒 `process.exit(0)` 兜底，因为 dispose 成功后进程并不保证会退出。

在 profile 的 `cordis.patch.yml` 里可以覆盖以下配置：

| key | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `pollMs` | `1000` | 采样间隔 |
| `disconnectGraceMs` | `5000` | 断开多久才退出；能盖住刷新标签页、短暂睡眠。`0` = 一断就退 |
| `requireEverConnected` | `true` | 至少连上过一次 UI 才开始计时（`--no-open` 这类启动不会被误杀） |

```yaml
- id: auto-shutdown
  config:
    disconnectGraceMs: 30000
```

已知边界：

- 机器休眠、网络硬断时，要靠 mux 心跳（2 秒 ping，丢 2 次 pong）才能发现，会晚几秒。
- 计数单位是 `$events` 流，不是页面。事件源被注销或出错时，网关会一次清空所有流，这时页面还开着也会被判定为 0。
- 多个标签页时，任意一个还活着就不会退出。

## 说明

非 DeepSeek 官方项目。图标为自绘，不是官方素材。

## License

MIT
