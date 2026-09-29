# dsh-windows-launcher

A Windows desktop launcher for [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (`dsh web`) with a startup progress window.

面向 Windows 的 DeepSeek Harness 桌面启动器，提供带有阶段文字、计时和进度条的无黑窗启动体验：

| 部分 | 是什么 | 运行在哪 |
| --- | --- | --- |
| **启动进度窗**（`launcher/`） | 桌面快捷方式 → 无黑窗启动 `dsh web`，显示带阶段文字、计时和进度条的小卡片，就绪后在 Edge 新窗口打开并置前 | 启动器进程（dsh 起来**之前**） |

<img width="892" height="250" alt="Screenshot 2026-09-29 185359" src="https://github.com/user-attachments/assets/8e08e575-2892-44f5-98c7-af30ae971d51" />

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
