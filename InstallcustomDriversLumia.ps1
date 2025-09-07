<# InstallCustomDrivers.ps1 "Install customDrivers Lumia devices"

What this script does:

Asks you to pick a folder that contains driver .inf files (can be nested)

Scans mounted Windows volumes to automatically detect the MainOS partition (looks for a root folder named "MainOS" or for a Windows installation folder)

Shows the chosen driver path and the detected MainOS drive (example: X:)

Runs DISM to inject drivers into the offline image:  dism /Image:X:\ /Add-Driver /Driver:"<DriversFolder>" /Recurse

Logs output to a logfile next to the script


Usage:

Run PowerShell as Administrator and execute this script: .\InstallCustomDrivers.ps1

The script will request elevation automatically if not already elevated.


Notes / Caveats:

This script assumes the MainOS partition is accessible as a mounted filesystem drive (like X:). If you're working with an FFU or WIM, mount it first.

Make sure the drivers folder contains .inf files (either directly or in subfolders). Use "Recurse" to find nested drivers.

To convert this to an .exe, you can use a tool like ps2exe (external) after testing the script.


#>

Add-Type -AssemblyName System.Windows.Forms

function Assert-Administrator { $current = [Security.Principal.WindowsIdentity]::GetCurrent() $principal = New-Object Security.Principal.WindowsPrincipal($current) if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { Write-Host "Not running as Administrator. Trying to relaunch elevated..." -ForegroundColor Yellow $psi = New-Object System.Diagnostics.ProcessStartInfo $psi.FileName = (Get-Process -Id $PID).Path $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"" $psi.Verb = "runas" try { [System.Diagnostics.Process]::Start($psi) | Out-Null exit } catch { Write-Error "Elevation cancelled or failed. Please run PowerShell as Administrator and re-run the script." exit 1 } } }

Assert-Administrator

$logFile = Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath "InstallCustomDrivers.log" "n---- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ----n" | Out-File -FilePath $logFile -Append

function Log { param([string]$Message) $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' $line = "[$ts] $Message" $line | Tee-Object -FilePath $logFile -Append }

Ask user to pick drivers folder

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog $folderDialog.Description = 'Select the folder that contains your drivers (.inf)' $folderDialog.ShowNewFolderButton = $false $drvPath = $null if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $drvPath = $folderDialog.SelectedPath } else { Write-Host "No folder selected. Exiting." -ForegroundColor Red Log "User cancelled driver folder selection." exit 1 }

validate driver files exist

$infCount = Get-ChildItem -Path $drvPath -Include *.inf -Recurse -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count if ($infCount -eq 0) { Write-Host "No .inf files found in the selected folder or its subfolders. Please check and try again." -ForegroundColor Red Log "No .inf files in $drvPath" exit 1 }

Log "Driver folder chosen: $drvPath (found $infCount .inf files)" Write-Host "Driver path is: "$drvPath"`n" -ForegroundColor Green

Function to detect MainOS drive(s)

function Get-PotentialMainOSDrives { $candidates = @() $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -ne $null } foreach ($d in $drives) { $root = $d.Root.TrimEnd('') try { # look for a folder literally named MainOS at root if (Test-Path (Join-Path $root 'MainOS')) { $candidates += [PSCustomObject]@{Drive=$d.Name; Root=$root; Reason='Found \MainOS folder'} continue } # look for a Windows installation pattern if (Test-Path (Join-Path $root 'Windows\System32')) { # also ensure it's not the current running system drive $isRunning = ($root -eq (Get-PSDrive -Name (Split-Path -Qualifier $env:SystemDrive) -ErrorAction SilentlyContinue).Root) $reason = 'Found Windows\System32' if ($isRunning) { $reason += ' (This is current OS)'} $candidates += [PSCustomObject]@{Drive=$d.Name; Root=$root; Reason=$reason} } } catch { # ignore restricted drives } } return $candidates }

$candidates = Get-PotentialMainOSDrives

if ($candidates.Count -eq 0) { Write-Host "Could not find any candidate MainOS drives. Please ensure the MainOS partition is mounted (e.g. X:) and try again." -ForegroundColor Red Log "No candidate MainOS drives found on system." exit 1 }

Prefer a drive that has a root folder named MainOS

$preferred = $candidates | Where-Object { $_.Reason -like 'MainOS' } | Select-Object -First 1 if (-not $preferred) { $preferred = $candidates | Select-Object -First 1 }

$mainDriveLetter = $preferred.Drive + ':' $mainRoot = $preferred.Root Log "Detected MainOS candidate: $($preferred.Drive) - $($preferred.Root) - Reason: $($preferred.Reason)" Write-Host "MainOS detected as $mainDriveLetter (as it show what it is) — ready to injecting drivers." -ForegroundColor Cyan Write-Host "Drivers folder: "$drvPath"`n" -ForegroundColor Cyan

Confirm automatic action

$yes = [System.Windows.Forms.MessageBox]::Show("Inject drivers from:n$drvPathninto MainOS:$mainDriveLetternnProceed?","Confirm Injection", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question) if ($yes -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Host "Cancelled by user." -ForegroundColor Yellow Log "User cancelled before injection." exit 0 }

Build DISM arguments

For offline image injection we use: dism /Image:X:\ /Add-Driver /Driver:"C:\path" /Recurse

If the detected drive root has a MainOS folder, use the full path to Imaging (e.g. X:\MainOS) where appropriate.

$useImagePath = "$mainDriveLetter"

If root contains a folder named MainOS, inject into that folder

if (Test-Path (Join-Path $mainRoot 'MainOS')) { $useImagePath = Join-Path $mainRoot 'MainOS' }

Normalize: ensure trailing backslash for DISM /Image parameter

if ($useImagePath -notlike ':' -and $useImagePath -notlike ':*') { # ensure it ends with backslash if ($useImagePath[-1] -ne '') { $useImagePath += '' } }

Log "Using DISM Image path: $useImagePath" Write-Host "Injecting Drivers..." -ForegroundColor Magenta Log "Starting DISM injection into image: $useImagePath"

Build the DISM command

$dismPath = Join-Path $env:windir 'System32\dism.exe' if (-not (Test-Path $dismPath)) { Write-Host "DISM not found at $dismPath. Cannot continue." -ForegroundColor Red Log "DISM not found: $dismPath" exit 1 }

Prepare arguments array

$argList = @('/Image:' + $useImagePath, '/Add-Driver', ('/Driver:"' + $drvPath + '"'), '/Recurse', '/ForceUnsigned')

Note: /ForceUnsigned may be needed for unsigned drivers; remove if you want signed-only.

Run DISM and capture output

$startInfo = New-Object System.Diagnostics.ProcessStartInfo $startInfo.FileName = $dismPath $startInfo.Arguments = $argList -join ' ' $startInfo.RedirectStandardOutput = $true $startInfo.RedirectStandardError = $true $startInfo.UseShellExecute = $false $startInfo.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process $proc.StartInfo = $startInfo

Try { $proc.Start() | Out-Null $stdOut = $proc.StandardOutput.ReadToEnd() $stdErr = $proc.StandardError.ReadToEnd() $proc.WaitForExit() $exitCode = $proc.ExitCode

$stdOut | Out-File -FilePath $logFile -Append
$stdErr | Out-File -FilePath $logFile -Append

if ($exitCode -eq 0) {
    Write-Host "Injection complete — DISM reported success." -ForegroundColor Green
    Log "DISM exited with code 0. Injection succeeded."
} else {
    Write-Host "DISM finished with exit code $exitCode. Check the log at $logFile for details." -ForegroundColor Red
    Log "DISM exited with code $exitCode. StdErr: $stdErr"
    Write-Host "Output snippet: `n$stdOut`n`nError snippet: `n$stdErr`n" -ForegroundColor DarkYellow
}

} Catch { Write-Host "An error occurred while running DISM: $" -ForegroundColor Red Log "Exception running DISM: $" exit 1 }

Write-Host "Done. Log file: $logFile" -ForegroundColor Gray Log "Script finished."

End of script

