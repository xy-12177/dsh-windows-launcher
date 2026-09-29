' Desktop-shortcut shim for the DeepSeek Harness Web GUI.
'
' Window style 0: the launcher runs with no console at all. That is the point
' -- the harness must start without leaving a black window on screen. It is
' only safe because start-dsh.ps1 reports every failure through a MessageBox
' instead of printing to a console nobody would see.
'
' All the real logic (port probe, reuse-vs-boot decision, hidden server spawn,
' token-URL handoff, foreground grab) lives in start-dsh.ps1 next to this file.
Option Explicit

Dim fso, shell, here, ps1, psHost, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "start-dsh.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "Launcher not found:" & vbCrLf & ps1, 16, "DeepSeek Harness"
    WScript.Quit 1
End If

' Resolve a PowerShell host explicitly. This machine runs Windows PowerShell
' 5.1, whose powershell.exe is NOT on PATH for every process, so a bare
' "powershell.exe" can fail silently -- the exact class of bug this avoids.
psHost = ""
Dim candidates, i, full
candidates = Array( _
    shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"), _
    shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe"), _
    "powershell.exe", _
    "pwsh.exe")
For i = 0 To UBound(candidates)
    full = candidates(i)
    If InStr(full, "\") > 0 Then
        If fso.FileExists(full) Then
            psHost = full
            Exit For
        End If
    Else
        psHost = full ' bare name: let the shell resolve it via PATH
        Exit For
    End If
Next

If psHost = "" Then
    MsgBox "Could not find a PowerShell host (powershell.exe / pwsh.exe)." & vbCrLf & _
           "Install PowerShell or run start-dsh.ps1 manually.", 16, "DeepSeek Harness"
    WScript.Quit 1
End If

cmd = """" & psHost & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass " & _
      "-WindowStyle Hidden -File """ & ps1 & """"
shell.Run cmd, 0, False
