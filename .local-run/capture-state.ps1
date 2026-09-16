$ErrorActionPreference = 'Stop'
$scratch = $PSScriptRoot
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup  = Join-Path $scratch "backup-$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null

# Registry values the configuration will set (RemoteDesktop already removed)
$targets = @(
  @{k='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo';                            v='Enabled'}
  @{k='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock';                  v='AllowDevelopmentWithoutDevLicense'}
  @{k='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem';                               v='LongPathsEnabled'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='HideFileExt'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='Hidden'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='FullPathAddress'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='LaunchTo'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='ShowFrequent'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';                        v='ShowRecent'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';                        v='ShowCloudFilesInQuickAccess'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='NavPaneShowVersionControl'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='ShowSyncProviderNotifications'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings';          v='NOC_GLOBAL_SETTING_TOASTS_ENABLED'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='TaskbarDa'}
  @{k='HKCU:\Control Panel\Bluetooth';                                                   v='Notification Area Icon'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='TaskbarEndTask'}
  @{k='HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer';                              v='DisableSearchBoxSuggestions'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings';                  v='IsDynamicSearchBoxEnabled'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';               v='Start_IrisRecommendations'}
  @{k='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';                                           v='AllowNewsAndInterests'}
  @{k='HKLM:\SOFTWARE\Policies\Microsoft\Edge';                                          v='NewTabPageLocation'}
  @{k='HKLM:\SOFTWARE\Policies\Microsoft\Edge';                                          v='HideFirstRunExperience'}
  @{k='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\PowerToys'; v='Enabled'}
)

$revert = @("# Revert script generated $stamp",
            "# Restores the registry values as they were BEFORE dev-config was applied.",
            "# Run in an ELEVATED PowerShell 7.",
            "`$ErrorActionPreference = 'Stop'",
            "")
$report = @()

foreach ($t in $targets) {
  $exists = Test-Path -LiteralPath $t.k
  $prop   = if ($exists) { Get-ItemProperty -LiteralPath $t.k -Name $t.v -ErrorAction SilentlyContinue } else { $null }
  $has    = $null -ne $prop -and $null -ne $prop.PSObject.Properties[$t.v]

  if ($has) {
    $val  = $prop.$($t.v)
    $kind = (Get-Item -LiteralPath $t.k).GetValueKind($t.v)
    $report += "{0,-8} {1}\{2} = {3}" -f 'SET', $t.k, $t.v, $val
    $q = if ($kind -eq 'String') { "'" + ($val -replace "'","''") + "'" } else { $val }
    $revert += "Set-ItemProperty -LiteralPath '$($t.k)' -Name '$($t.v)' -Value $q -Type $kind -Force"
  } else {
    $report += "{0,-8} {1}\{2}" -f 'UNSET', $t.k, $t.v
    $revert += "Remove-ItemProperty -LiteralPath '$($t.k)' -Name '$($t.v)' -Force -ErrorAction SilentlyContinue"
  }
}

$revert | Set-Content -Path (Join-Path $backup 'revert-registry.ps1') -Encoding UTF8
$report | Set-Content -Path (Join-Path $backup 'before-state.txt')    -Encoding UTF8

# Back up Windows Terminal settings.json (the config rewrites the font)
$wt = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path -LiteralPath $wt) {
  Copy-Item -LiteralPath $wt -Destination (Join-Path $backup 'terminal-settings.json') -Force
  "Windows Terminal settings.json backed up."
} else {
  "Windows Terminal settings.json NOT found at expected path."
}

""
"Backup directory: $backup"
""
"--- Current state of the values the config will change ---"
$report
