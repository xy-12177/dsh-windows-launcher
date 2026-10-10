# V3 启动器 UI 验证报告

验证日期：2026-10-11（Asia/Tokyo）。仓库启动器 SHA-256：`FD0A29FECFA872AE5A93EC39F97737636C486402E1A7E3AB72B2B8CAC3781352`。检查使用 Windows PowerShell 5.1；内嵌 WinForms C# 编译通过。

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
