# 新版启动器 UI 验证报告

验证日期：2026-10-10。当前启动器 SHA-256：`400CFDDC1F7FD2C71AC37368E976AEFC7A10AFE0FBC37C1F92406CD468B92BC6`。编译和进程检查使用 Windows PowerShell 5.1。部署文件 `D:\deepseek harness\start-dsh.ps1` 与仓库源码 SHA-256 相同；部署未改动 VBS/快捷方式。

## 艺术字与布局

最终 UI 的标题保留完整拼写 **DeepSeek Harness**。C# 使用 Windows 内置 Segoe Print、Segoe Script、Segoe UI 字体候选，将字形路径预渲染到缓存 Bitmap，再以蓝紫渐变和浅色描边绘制。该预渲染图按布局/DPI 尺寸生成；截图测试没有再对艺术字单独放大字体，避免重复缩放。

本轮在标题艺术字之外新增检查左下阶段和计时艺术字。阶段与时间均使用楷体候选预渲染缓存 Bitmap，并以蓝紫渐变绘制；WinPS 5.1 的 GDI+ 将已安装字体族报告为 KaiTi（中文别名为楷体），实际中文截图无缺字方框。Capture 通过 SetProgress 更新阶段缓存，并验证 1 秒、10 分钟、100 分钟计时均生成可读图像。

我目视检查了浅色 100%、深色 200%、长阶段压力图和 100 分钟计时图：标题与阶段完整拼写/内容清晰，文本左对齐，计时未裁切；长中文状态以省略号截断，没有覆盖角色或进度条。测试使用 Windows PowerShell 5.1 成功编译内嵌 C#。

离屏截图通过内存注入模拟浅/深主题以及 100%、150%、200% 布局比例，未更改 Windows 系统主题或显示比例；因此它们不代表系统原生 DPI/主题切换测试。逻辑基准为 760×320，画布分别为 760×320、1140×480、1520×640。

## 运行隔离

实际 `-Preview -PreviewSeconds 1` 进程正常退出，ExitCode 为 0；未创建传入的唯一 WorkDir，`launcher/.run` 文件快照未变化。当前正常启动与 Preview 都选择静态开心站姿；兼容参数 `-StaticMascot` 仍被接受。活动 C# UI 不加载旧跑步帧。

## 原生窗口区域修复

这次排查确认先前离屏 `DrawToBitmap` 截图只能检查绘制布局，不能证明真实 Windows 窗口未被原生 Region 裁切。修复前的真实 WinForms 窗口 ClientSize 为 1520×640，而 `GetWindowRgnBox` 返回 0,0..273,228（Region 类型 3/COMPLEX），窗口其余区域被裁掉。根因是构造阶段调用 `Form.CreateGraphics()` 过早创建 HWND，Region 在最终 ClientSize 赋值前按初始尺寸建立。

修复后，真实 production form 的初始客户区与 native Region 均为 1520×640；将客户区改为 800×400 后，native Region 同步为 800×400；恢复后两者重新为 1520×640。真实安装路径 Preview 子进程（PID 13788）的 `GetClientRect` 与 `GetWindowRgnBox` 也都为 0,0..1520,640，Region 类型为 3，ExitCode 为 0；测试 WorkDir 不存在且 `launcher/.run` 文件快照未变化。该实测以 Win32 原生边界为裁切结论依据。

[PrintWindow目标窗口截图](validation-native-preview.png) 可辅助目视确认完整卡片、角色、阶段/用时和底部进度条均已绘制；CopyFromScreen 在本桌面 DPI/overlay 坐标环境中误捕获到 Codex 窗口，已删除，不作为证据。当前回归脚本 [Test-NativeWindowRegion.ps1](../tests/Test-NativeWindowRegion.ps1) 同时检查 Region 初始/Resize/还原尺寸，并通过 PID 枚举验证真实 Preview 子进程 HWND。

## 性能数据边界

本轮对修复后的真实可见静态 Preview 进程做了一次 30.89 秒采样：CPU 单核占用 1.62%，WorkingSet 峰值 151.20 MiB，PrivateBytes 峰值 118.00 MiB。此前记录的 CPU 0.61%、WorkingSet 150.48 MiB、PrivateBytes 115.58 MiB 来自 Region 被严重裁切的窗口，不能代表完整可视 UI 的性能，不与本次数据作有效对照。此次没有重测跑步动画。

## 预览与测试

[真实 Preview 窗口 PrintWindow 截图](validation-native-preview.png) 仅作外观辅助；原生 Region/client 边界才是窗口未裁切的判定依据。验证流程见 [Invoke-DshValidation.ps1](../tests/Invoke-DshValidation.ps1) 和 [Test-NativeWindowRegion.ps1](../tests/Test-NativeWindowRegion.ps1)。

## 复跑

从仓库根目录运行。`PreviewIsolation` 会短暂显示真实预览窗口。

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Compile
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Capture
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode PreviewIsolation
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Test-NativeWindowRegion.ps1 -SourcePath 'D:\deepseek harness\start-dsh.ps1' -Label installed -RequireMatch
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode StaticSample -DurationSeconds 30
```
