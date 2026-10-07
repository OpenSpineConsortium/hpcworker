<#
.SYNOPSIS
  The Windows Scheduled Task that keeps the grid's approved list: tools/grid_access.sh --quiet, run in
  WSL every 15 minutes while you are signed in to Windows.

.DESCRIPTION
  -Install  registers the task "Beethoven grid access" for the Windows account running this script. No
            administrator rights: it runs as you, only while you are signed in, at the lowest run level,
            in a hidden console (conhost.exe --headless), at most 10 minutes a run, never two at once.
            It refuses until a -Run has applied the list once while you watched, that is until
            <vendor>\state\grid_access.wayne.ids exists (grid_access.sh writes it only after the grid
            side applied the list).
  -Remove   unregisters it.
  -Run      runs the task's command once, here, in this window, without --quiet so you see what it did.
            -ToolArgs passes more options to grid_access.sh for this one run, in one string, separated
            by spaces or commas, for example  -ToolArgs '--dry-run'  or  -ToolArgs '--dry-run --force'
            (the grid's entries as they are now, changing nothing). Under -File, PowerShell hands this
            script one string however the options are written, so the script splits it itself.
  (none)    prints the command the task runs, whether the list has been applied once, and whether the
            task is registered.
  -WhatIf   with -Install, -Remove or -Run: says what would be done and does nothing.

  -AdminTool  the access service's admin.mjs, a Windows path (or $env:BEETHOVEN_ADMIN_TOOL). Every
            option but the bare one needs it: grid_access.sh reads its two lists only from a command the
            person names, and assumes no checkout beside this one (the two repositories meet only at
            those two plain-text lists). The path may hold letters, digits and . _ - / \ : only.

  The command is
    conhost.exe --headless wsl.exe -e bash -lc "BEETHOVEN_VENDOR_DIR='<vendor>' BEETHOVEN_ROSTER_CMD='node <admin> roster' BEETHOVEN_READERS_CMD='node <admin> readers' exec bash '<tool>' --quiet"
  where <vendor> is %USERPROFILE%\.beethoven-vendor, <admin> the -AdminTool path and <tool> grid_access.sh
  in this folder, all as WSL paths (wslpath). The network goes through WSL, where ssh to wsu-grid works;
  admin.mjs (node, in WSL) finds its own admin token in the vendor folder, and prints the approved list
  (roster) and the readers' folders (readers). When the list has not changed since the last run, grid_access.sh does not connect to the
  grid at all (an approved AccessID the grid does not know yet is tried again once a day), and the task's
  runs never sweep the whole tree (that is --check-tree, by hand). Each run adds one line to
  <vendor>\state\grid_access.log.

.EXAMPLE
  powershell -NoProfile -File tools\grid_access_task.ps1 -AdminTool C:\Users\grego\OneDrive\Desktop\ashley\tools\intake\admin.mjs -Run -ToolArgs '--dry-run --force'
.EXAMPLE
  powershell -NoProfile -File tools\grid_access_task.ps1 -AdminTool C:\Users\grego\OneDrive\Desktop\ashley\tools\intake\admin.mjs -Run
.EXAMPLE
  powershell -NoProfile -File tools\grid_access_task.ps1 -AdminTool C:\Users\grego\OneDrive\Desktop\ashley\tools\intake\admin.mjs -Install
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Show')]
param(
  [Parameter(ParameterSetName = 'Install', Mandatory = $true)][switch]$Install,
  [Parameter(ParameterSetName = 'Remove', Mandatory = $true)][switch]$Remove,
  [Parameter(ParameterSetName = 'Run', Mandatory = $true)][switch]$Run,
  [Parameter(ParameterSetName = 'Run')][string[]]$ToolArgs = @(),
  [string]$AdminTool = $env:BEETHOVEN_ADMIN_TOOL
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$TaskName = 'Beethoven grid access'
$TaskPath = '\'
$Minutes = 15
$Site = 'wayne'   # grid_access.sh's default site; the task runs it without --site
$Vendor = Join-Path $env:USERPROFILE '.beethoven-vendor'
$StateFile = Join-Path $Vendor "state\grid_access.$Site.ids"

function ConvertTo-WslPath([string]$WindowsPath) {
  $out = & wsl.exe -e wslpath -a -u $WindowsPath 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) {
    throw "wslpath could not convert $WindowsPath. Is WSL installed, with a default distribution?"
  }
  return ([string]($out | Select-Object -First 1)).Trim()
}

function Get-BashCommand {
  # what bash -lc runs; the tool's and the vendor folder's paths in single quotes, so a space in a folder
  # name is fine. The admin tool's path sits inside a command grid_access.sh runs with bash -c, so it is
  # held to plain characters instead of being quoted twice.
  if (-not $AdminTool) {
    throw ("Name the access service's admin.mjs: -AdminTool <path>, or `$env:BEETHOVEN_ADMIN_TOOL. grid_access.sh " +
      "takes the approved list and the readers only from a command you name, and looks for nothing beside this checkout.")
  }
  if ($AdminTool -notmatch '^[A-Za-z0-9_.:\\/-]+$') {
    throw "the path $AdminTool holds characters the task's command line does not carry (letters, digits and . _ - / \ : only)"
  }
  if (-not (Test-Path -LiteralPath $AdminTool -PathType Leaf)) { throw "there is no file $AdminTool" }
  $tool = Join-Path $PSScriptRoot 'grid_access.sh'
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "grid_access.sh is not beside this script ($tool)" }
  $wslTool = ConvertTo-WslPath $tool
  $wslVendor = ConvertTo-WslPath $Vendor
  $wslAdmin = ConvertTo-WslPath (Resolve-Path -LiteralPath $AdminTool).Path
  foreach ($p in @($wslTool, $wslVendor)) {
    if ($p -match "['`"]") { throw "the path $p holds a quote; the task's command line cannot carry it" }
  }
  if ($wslAdmin -notmatch '^[A-Za-z0-9_./-]+$') { throw "the WSL path $wslAdmin holds characters the task's command line does not carry" }
  return ("BEETHOVEN_VENDOR_DIR='$wslVendor' BEETHOVEN_ROSTER_CMD='node $wslAdmin roster' " +
    "BEETHOVEN_READERS_CMD='node $wslAdmin readers' exec bash '$wslTool'")
}

function Get-Task {
  return Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

function Split-ToolArgs([string[]]$Given) {
  # -ToolArgs '--dry-run --force' or '--force,--open-tree' arrives under -File as ONE string: split
  # every element on commas and white space before anything is judged
  $parts = @()
  foreach ($g in $Given) {
    if ($null -eq $g) { continue }
    $parts += @(($g -split '[,\s]+') | Where-Object { $_ -ne '' })
  }
  foreach ($p in $parts) {
    if ($p -notmatch '^[A-Za-z0-9_./=:-]+$') { throw "option '$p' holds characters this script does not pass on" }
  }
  return ,$parts
}

$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'

switch ($PSCmdlet.ParameterSetName) {
  'Install' {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
      throw ("The list has not been applied yet: $StateFile does not exist. Run it once while you watch, " +
        "first  -Run -ToolArgs '--dry-run --force'  (what it would change), then  -Run  (it applies the list and writes that file). " +
        "-Install refuses until then, so the task never makes its first change unseen.")
    }
    $bash = Get-BashCommand
    $argument = "--headless wsl.exe -e bash -lc `"$bash --quiet`""
    $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Output "Task:     $TaskPath$TaskName"
    Write-Output "Runs:     $conhost $argument"
    Write-Output "As:       $who, only while signed in, every $Minutes minutes, hidden, no administrator rights"
    if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Register a scheduled task running grid_access.sh every $Minutes minutes")) {
      $action = New-ScheduledTaskAction -Execute $conhost -Argument $argument
      $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
      $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
      $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
      $description = 'Beethoven: keeps the grid''s approved list (the named-user ACL on the lab volume''s root) and its readers (the group''s read on approved folders) in step with the access service. tools/grid_access.sh --quiet in WSL; log in .beethoven-vendor\state\grid_access.log.'
      Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $description -Force | Out-Null
      $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
      Write-Output "Registered. Next run: $($info.NextRunTime)"
    }
  }
  'Remove' {
    if (-not (Get-Task)) { Write-Output "No task $TaskPath$TaskName is registered."; break }
    if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Unregister the scheduled task')) {
      Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
      Write-Output "Removed $TaskPath$TaskName."
    }
  }
  'Run' {
    $opts = Split-ToolArgs $ToolArgs
    $bash = Get-BashCommand
    $line = $bash
    if ($opts.Count -gt 0) { $line = "$bash " + (($opts | ForEach-Object { "'$_'" }) -join ' ') }
    Write-Output "Runs: wsl.exe -e bash -lc `"$line`""
    if ($PSCmdlet.ShouldProcess('WSL', "Run grid_access.sh once $($opts -join ' ')")) {
      & wsl.exe -e bash -lc $line
      $code = $LASTEXITCODE
      Write-Output "grid_access.sh ended with exit $code (0 done or unchanged, 1 refused or failed, 2 applied but a check failed)."
      exit $code
    }
  }
  default {
    Write-Output "Task:     $TaskPath$TaskName"
    if ($AdminTool) {
      $bash = Get-BashCommand
      Write-Output "Runs:     $conhost --headless wsl.exe -e bash -lc `"$bash --quiet`""
    } else {
      Write-Output 'Runs:     (name the access service''s admin.mjs with -AdminTool <path> to see the command)'
    }
    if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
      Write-Output "Applied:  yes, once at least ($StateFile exists)"
    } else {
      Write-Output "Applied:  not yet (-Run applies the list once while you watch; -Install refuses until then)"
    }
    $task = Get-Task
    if ($task) {
      $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
      Write-Output "State:    $($task.State); last run $($info.LastRunTime) (result $($info.LastTaskResult)); next run $($info.NextRunTime)"
    } else {
      Write-Output 'State:    not registered (-Install registers it)'
    }
  }
}
