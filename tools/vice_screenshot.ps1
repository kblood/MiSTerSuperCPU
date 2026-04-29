param(
  [string]$ProgramPath = "C:\LLM\C64\MiSTerSuperCPU\asterix.prg",
  [int]$WaitSeconds = 25,
  [string]$OutputPath = "C:\LLM\C64\MiSTerSuperCPU\tools\vice_asterix.png"
)

$viceExe = "D:\Games\Emulator\C64\GTK3VICE-3.9-win64\bin\xscpu64.exe"

# Launch xscpu64 with autostart
Write-Host "Launching VICE xscpu64 with $ProgramPath"
$p = Start-Process -FilePath $viceExe -ArgumentList "-autostart",$ProgramPath,"+warp","+sound" -PassThru -WindowStyle Normal

Write-Host "Waiting $WaitSeconds seconds for Asterix to start..."
Start-Sleep -Seconds $WaitSeconds

# Find the VICE window and screenshot it
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

$procs = Get-Process -Name xscpu64 -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($pp in $procs) {
        if ($pp.MainWindowHandle -ne 0) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;

public class Win32 {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
            [Win32]::SetForegroundWindow($pp.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 500

            $r = New-Object Win32+RECT
            $null = [Win32]::GetWindowRect($pp.MainWindowHandle, [ref]$r)
            $w = $r.Right - $r.Left
            $h = $r.Bottom - $r.Top
            Write-Host "Window rect: $($r.Left),$($r.Top) size ${w}x${h}"

            if ($w -gt 0 -and $h -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap $w, $h
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
                $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $g.Dispose()
                $bmp.Dispose()
                Write-Host "Saved screenshot to $OutputPath"
            }
            break
        }
    }
}

# Kill VICE
Start-Sleep -Seconds 1
$procs = Get-Process -Name xscpu64 -ErrorAction SilentlyContinue
if ($procs) { $procs | Stop-Process -Force }
Write-Host "Done"
