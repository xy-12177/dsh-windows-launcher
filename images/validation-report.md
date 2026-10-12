# V3 启动器 UI 验证报告

验证日期：2026-10-11（Asia/Tokyo）。仓库启动器 SHA-256：`FD0A29FECFA872AE5A93EC39F97737636C486402E1A7E3AB72B2B8CAC3781352`。检查使用 Windows PowerShell 5.1；内嵌 WinForms C# 编译通过。

## 启动器目录统一验收（2026-10-11）

- 当前桌面快捷方式直接调用 `D:\deepseek harness\dsh-windows-launcher\launcher\start-dsh.vbs`；原快捷方式名称和图标保持不变。配置与运行文件集中在 `launcher/`，端口仍为 4080、工作目录仍为 `D:\deepseek harness`，浏览器仍为普通窗口模式。下文涉及父目录部署源的记录是迁移前的历史验证。
- `tests/Test-InstallModes.ps1` 在临时目录验证源码模式保留配置、名称及图标，显式参数覆盖、新快捷方式只复制外部图标，以及原复制安装模式；插件注册被跳过。
- 真实源码 Preview 退出成功，未创建指定 WorkDir、未修改 `.run`；native Region 在初始、Resize、恢复和真实 Preview 子进程上均通过点包含测试，客户区为 1520×720。窗口源码和 UI 素材未改动。
- 通过实际桌面快捷方式冷启动 DSH，启动令牌交换及带 cookie 的网页请求均返回 HTTP 200；再次点击打开新浏览器窗口并复用原进程及缓存状态。源码停止脚本释放 4080 端口并移除 `state.json`。验收打开的 DSH 浏览器窗口已关闭。
- 服务日志确认自动关闭插件正常加载；web profile 的 package、lock 和 patch 配置哈希均保持不变。启动失败路径由现有流程模拟测试验证。

## 验证结果

- 六种离屏组合（浅/深主题 × 100/150/200%）均完成绘制，画布分别为 760×360、1140×540、1520×720；长中文阶段压力文本、1 秒/10 分钟/100 分钟计时缓存均通过。主题和比例由测试进程内存注入，不代表系统设置或原生多显示器 DPI 切换。
- 仓库源 Preview 子进程 PID 16772 与实际部署源 `D:\deepseek harness\start-dsh.ps1` Preview 子进程 PID 8716 均在本机 200% DPI 下得到 1520×720 客户区；部署文件 SHA-256 与仓库源码一致（`FD0A29FECFA872AE5A93EC39F97737636C486402E1A7E3AB72B2B8CAC3781352`）。Win32 `GetWindowRgn` / `PtInRegion` 的正点（卡片、越过卡片上沿的头发、左右鞋）和负点（窗口外角、右侧空白、左下圆角缺口、头发透明邻点）均符合设计；Resize、恢复原尺寸后相同点集仍通过。Region 矩形边界为 48,43..1412,680，故不应要求其等于整个客户区。
- 仓库源与已部署源的实际 `-Preview -PreviewSeconds 2` 均以 ExitCode 0 退出；唯一指定 WorkDir 未创建，部署启动器 `.run` 快照无变化。窗口句柄按子进程 PID 枚举并核验。PrintWindow 图像仅作外观辅助；裁切结论来自 native Region 点包含测试，而不是 DrawToBitmap 或整窗矩形。
- 缺失与损坏的吉祥物图都回退到同目录 logo；两种情况均完成绘制、Close/Dispose。冷启动、已有实例、启动失败路由由脚本拦截进程/浏览器操作进行模拟；没有启动真实 dsh 或浏览器。

## 单次静态性能采样

一次真实可见静态 Preview 运行 31.1 秒：单核 CPU 2.56%，WorkingSet 峰值 151.84 MiB，PrivateBytes 峰值 119.71 MiB。该数据针对当前 V3 异形窗口；此前 Region 裁切版本的性能值不代表完整显示 UI，也不作有效对比。本轮未测跑步动画。

## 截图与复跑

[真实 Preview 窗口 PrintWindow 截图](validation-native-preview.png) 是本机 200% DPI 子进程窗口的图像。它能辅助目视检查，但 PrintWindow 本身可能忽略桌面 Region 裁切；Region 点测试才是本报告的 native shape 证据。

验证脚本：[Invoke-DshValidation.ps1](../tests/Invoke-DshValidation.ps1)、[Test-NativeWindowRegion.ps1](../tests/Test-NativeWindowRegion.ps1)。从仓库根目录以 Windows PowerShell 5.1 运行：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Compile
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Capture -OutputDir "$env:TEMP\dsh-v3-captures"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Fallback
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode Flows
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Test-NativeWindowRegion.ps1 -PreviewSeconds 2
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-DshValidation.ps1 -Mode StaticSample -DurationSeconds 30
```


## Loading dots 更新验证（2026-10-13）

本节验证当前仓库源码 `launcher/start-dsh.ps1`，SHA-256：`2C036637CBAAF35AD24D1D3A64AFDD47212B964BD6A0BB124EFE68241E6C46BD`。内嵌 C# 在 Windows PowerShell 5.1 编译通过。

- Capture 六组浅/深主题与 100/150/200% 内存模拟尺寸（760×360、1140×540、1520×720），并通过长中文阶段与 1 秒、10 分钟、100 分钟计时缓存检查。Windows 系统主题和 DPI 设置未更改。
- 反射断言确认 loading dots 的边界位于阶段字形右侧且留在阶段栏范围内；完成和失败状态隐藏 dots。相同的长阶段文字从 loading 转为完成时，公开 Stage 字段仍保留原文，阶段缓存重建，并恢复原先为 dots 预留的宽度。
- 对真实 `-Preview -PreviewSeconds 16` 子进程 PID 17376 连续采集 12 帧，间隔 100 ms；采集进程调用 SetProcessDPIAware，得到完整 1520×720 窗口。Preview ExitCode 为 0，指定 WorkDir 未创建，`.run` 快照未变化。连续帧的点动画区域每个相邻间隔均有像素变化；同阶段帧 1 与帧 5 的全图差异只落在点区域 (589,380)..(628,398)，阶段文案及计时保持不变。
- [真实 Preview 截图](validation-native-preview.png) 来自上述可见 HWND 的 PrintWindow；[12 帧 loading dots GIF](validation-loading-dots.gif) 使用相同 Preview 捕获帧制作，100 ms/帧。PrintWindow 仅作显示辅助，窗口异形裁切仍由前节记录的 Win32 native Region 测试确认。
- 当前源码的缺失/损坏吉祥物回退、Preview 隔离和冷启动/已有实例/失败流程模拟均通过；流程模拟拦截外部进程和浏览器调用，不运行真实 dsh/浏览器。

唯一成功的动画运行样本为 32.81 秒：单核 CPU 2.52%，WorkingSet 峰值 109.65 MiB，PrivateBytes 峰值 92.02 MiB，ExitCode 0。该值是单样本，未据此作严格性能比较。禁用 dots 的同源对照未能启动：测试专用改写的 C# 在 warnings-as-errors 下因 `_dotPhase` 未使用而编译失败，未启动 Preview；这不影响生产源码编译结果。之前静态 UI 的 2.56% 数据来自上次验证，仅作历史参考。

复跑动态截图可运行：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File tests/Capture-LoadingDots.ps1 -OutputDir "$env:TEMP\dsh-dot-frames" -FrameCount 12 -IntervalMs 100 -PreviewSeconds 16
```
