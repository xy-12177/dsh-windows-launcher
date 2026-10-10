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

配合起来的效果：**点图标 → 进度窗 → 浏览器打开；再点图标 → 冷启动。**

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

## 预览

可以安全预览启动窗口，而不启动 `dsh` 或浏览器，也不会创建工作目录或 `.run` 状态文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\start-dsh.ps1 -Preview
```

预览默认显示12秒，使用与真实启动相同的开心站姿静态角色。可延长预览时间：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File launcher\start-dsh.ps1 -Preview -PreviewSeconds 30
```

旧参数 `-StaticMascot` 为兼容性保留，不改变当前静态显示行为。

当前预览和主题、DPI验证说明见 [`images/validation-report.md`](images/validation-report.md)。
