# dsh-windows-launcher

A Windows desktop launcher for [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (`dsh web`) with a startup progress window.

面向 Windows 的 DeepSeek Harness 桌面启动器，提供带有阶段文字、计时和进度条的无黑窗启动体验：

| 部分 | 是什么 | 运行在哪 |
| --- | --- | --- |
| **启动进度窗**（`launcher/`） | 桌面快捷方式 → 无黑窗启动 `dsh web`，显示带阶段文字、计时和进度条的小卡片，就绪后在 Edge 新窗口打开并置前 | 启动器进程（dsh 起来**之前**） |

![启动进度窗截图](images/validation-native-preview.png)

启动进度窗采用横向品牌卡片：左侧为 DeepSeek 标志、蓝紫渐变手写艺术字产品名，以及加大的楷体渐变阶段与计时字样和底部进度条，右侧为保持原站姿的开心鲸鱼女仆。真实启动和 `-Preview` 都使用这张静态立绘；预览不会启动 `dsh` 或浏览器，也不会创建工作目录或 `.run` 状态文件。窗口跟随 Windows 浅色或深色主题并按 DPI 缩放。

卡片右缘沿角色外轮廓裁切，角色身体和鞋留在底板内，头饰与头发可越过卡片上缘；透明窗口区域与桌面背景融合。

旧版跑步动画曾超过预设的 CPU 增量目标，因此当前启动和预览都使用开心站姿静态角色，不加载动画帧。当前真实窗口的一次 30 秒采样及边界验证见验证报告。

进度窗必须在 dsh 启动前就出现，所以它做不成 dsh 插件（插件要等服务起来才会加载）。

配合起来的效果：**点图标 → 进度窗 → 浏览器打开；服务还在运行时再次点击会复用实例，服务关闭后再次点击才会冷启动。**

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

安装时，`install.ps1` 会把 `launcher\` 中的启动脚本、静态角色图和图标一并复制到 `%LOCALAPPDATA%\DeepSeekHarness`。

## 直接使用源码（本机当前方式）

本机桌面快捷方式直接调用 `D:\deepseek harness\dsh-windows-launcher\launcher\start-dsh.vbs`。启动、停止脚本和素材只维护 `launcher/` 这一份，不需要在父目录复制一套。

从仓库根目录运行以下命令可创建或更新快捷方式，并跳过插件注册：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -UseSource -SkipPlugin -WorkDir 'D:\deepseek harness' -Port 4080
```

`-UseSource` 不复制启动脚本，并保留已有快捷方式的名称和图标。新快捷方式的图标单独放在 `%LOCALAPPDATA%\DeepSeekHarness`，避免 DSH 工作区的完整性标签使图标变空白。重复安装时，未明确传入的端口、工作目录和浏览器模式沿用 `launcher/dsh-launcher.json`；普通复制安装仍使用原来的默认设置。

本机启动配置为端口 `4080`、工作目录 `D:\deepseek harness`、`appWindow=false`。配置与运行日志均留在 `launcher/`：`dsh-launcher.json`、`.run/server.log`、`.run/server.err` 和自动生成的 `.run/state.json` 都被 Git 忽略。

整理前的服务日志保留在 `launcher/.run/history/`，不与之后启动生成的新日志混用。

也可以直接启动或停止：

```powershell
& "$env:SystemRoot\System32\wscript.exe" 'D:\deepseek harness\dsh-windows-launcher\launcher\start-dsh.vbs'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File 'D:\deepseek harness\dsh-windows-launcher\launcher\stop-dsh.ps1'
```

`stop-dsh.ps1` 默认读取同目录配置的端口；显式指定 `-Port` 可覆盖。当前自动关闭插件仍链接独立的 `D:\deepseek harness\dsh-auto-shutdown`，因此该目录必须保留，整理启动器不改变插件配置。

## 预览

可以安全预览启动窗口，而不启动 `dsh` 或浏览器，也不会创建工作目录或 `.run` 状态文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\start-dsh.ps1 -Preview
```

预览默认显示12秒，使用与真实启动相同的开心站姿静态角色。可延长预览时间：

窗口中的产品名使用蓝紫艺术字，启动阶段使用青蓝/青绿字色，用时使用珊瑚/玫瑰色；启动中的三点省略号依次轻跳，完成或失败时停止。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\start-dsh.ps1 -Preview -PreviewSeconds 30
```

旧参数 `-StaticMascot` 为兼容性保留，不改变当前静态显示行为。

当前预览和主题、DPI验证说明见 [`images/validation-report.md`](images/validation-report.md)。
