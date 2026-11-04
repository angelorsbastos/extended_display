# Creates "Wingman" shortcuts on the Desktop and in the Start menu.
# They start the hub in the background with a tray icon (pc\tray.py, no terminal).
# To put it on the taskbar: right-click the Start menu entry > Pin to taskbar.
# Run again after moving the project folder.

$project = Split-Path -Parent $PSScriptRoot
$pythonw = Join-Path $project ".venv\Scripts\pythonw.exe"
$tray = Join-Path $PSScriptRoot "tray.py"
$icon = Join-Path $PSScriptRoot "assets\icon.ico"
$shell = New-Object -ComObject WScript.Shell

foreach ($folder in [Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs")) {
    $link = $shell.CreateShortcut((Join-Path $folder "Wingman.lnk"))
    $link.TargetPath = $pythonw
    $link.Arguments = "`"$tray`""
    $link.WorkingDirectory = $project
    $link.IconLocation = $icon
    $link.Description = "Your iPad and iPhone, beside your laptop"
    $link.Save()
    Write-Output "created $($link.FullName)"
}

# Explorer: right-click a file > Send to > iPad (Wingman). On Windows 11 the
# "Send to" menu is under "Show more options" (or Shift+right-click).
$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("SendTo")) "iPad (Wingman).lnk"))
$link.TargetPath = $pythonw
$link.Arguments = "`"$(Join-Path $PSScriptRoot "sendfile.py")`""
$link.WorkingDirectory = $PSScriptRoot
$link.IconLocation = $icon
$link.Description = "Send to the iPad"
$link.Save()
Write-Output "created $($link.FullName)"

