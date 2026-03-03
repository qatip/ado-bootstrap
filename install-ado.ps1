param(
  [int]$AdoPort = 8080,
  [string]$SqlInstance = "SQLEXPRESS",
  [string]$CollectionName = "DefaultCollection",
  [string]$AdminUser = "azureuser"
)

$ErrorActionPreference = "Stop"
$global:RebootRequired = $false

# ---------------------------
# Logging
# ---------------------------
New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-ado.log" -Append

function Log { param([string]$m) Write-Host $m }
function Ensure-Tls12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {} }

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
  }
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
}

function Ensure-Choco {
  Ensure-Tls12
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "[INFO] Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force | Out-Null
    Ensure-Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  } else {
    Log "[INFO] Chocolatey already installed."
  }
  Refresh-Path
}

function Install-IisPrereqs {
  Log "[INFO] Installing IIS prerequisites..."
  Import-Module ServerManager

  $features = @(
    "Web-Server",
    "Web-WebServer",
    "Web-Common-Http",
    "Web-Default-Doc",
    "Web-Static-Content",
    "Web-Http-Errors",
    "Web-Http-Redirect",
    "Web-Http-Logging",
    "Web-Log-Libraries",
    "Web-Request-Monitor",
    "Web-Filtering",
    "Web-Stat-Compression",
    "Web-Dyn-Compression",
    "Web-Security",
    "Web-Windows-Auth",
    "Web-App-Dev",
    "Web-Net-Ext45",
    "Web-Asp-Net45",
    "Web-ISAPI-Ext",
    "Web-ISAPI-Filter",
    "Web-Mgmt-Tools",
    "Web-Mgmt-Console",
    "NET-Framework-45-Core",
    "NET-Framework-45-ASPNET"
  )

  $result = Install-WindowsFeature -Name $features -IncludeManagementTools
  if (-not $result.Success) { throw "Failed to install required IIS/.NET features." }
  Log "[INFO] IIS prerequisites installed."
}

function Ensure-SqlExpress {
  param([string]$Instance)

  Log "[INFO] Installing SQL Server Express..."
  Ensure-Choco

  # Install package (default instance name is SQLEXPRESS)
  choco install sql-server-express -y --no-progress

  Log "[INFO] Ensuring SQL Express service is running..."
  $svcName = "MSSQL`$$Instance"
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if ($null -eq $svc) { throw "SQL service $svcName not found after install." }
  if ($svc.Status -ne "Running") { Start-Service $svc.Name }
  Log "[INFO] SQL Express is running."
}

function Ensure-SqlSysadminForUser {
  param(
    [string]$Instance,
    [string]$User
  )

  $machine = $env:COMPUTERNAME
  $login   = "$machine\$User"
  $server  = "$machine\$Instance"   # e.g. vm-devops\SQLEXPRESS

  Log "[INFO] Granting SQL sysadmin to '$login' on '$server'..."

  $sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$login')
BEGIN
    CREATE LOGIN [$login] FROM WINDOWS;
END;

-- Add to sysadmin
EXEC sp_addsrvrolemember @loginame = N'$login', @rolename = N'sysadmin';
"@

  $tempSql = "C:\Tools\grant-sysadmin.sql"
  $sql | Set-Content -Path $tempSql -Encoding ASCII

  $sqlcmd = "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe"
  if (-not (Test-Path $sqlcmd)) {
    $sqlcmd = "${env:ProgramFiles(x86)}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe"
  }
  if (-not (Test-Path $sqlcmd)) {
    # sqlcmd often exists even if path differs; fall back to PATH
    $sqlcmd = "sqlcmd"
  }

  # Run as the current context (SYSTEM) against local SQL
  & $sqlcmd -S $server -E -b -i $tempSql
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed with exit code $LASTEXITCODE" }

  Log "[INFO] SQL sysadmin granted to '$login'."
}

function Install-AdoExpress {
  $adoExe = "C:\Tools\azuredevopsexpress2022.2.exe"
  $adoUrl = "https://go.microsoft.com/fwlink/?LinkId=2269947"  # Express 2022.2 EXE

  if (-not (Test-Path $adoExe)) {
    Log "[INFO] Downloading Azure DevOps Server Express installer..."
    Ensure-Tls12
    Invoke-WebRequest -Uri $adoUrl -OutFile $adoExe -UseBasicParsing
  } else {
    Log "[INFO] ADO installer already present."
  }

  Log "[INFO] Installing Azure DevOps Server Express..."
  $p = Start-Process -FilePath $adoExe -ArgumentList "/quiet","/norestart" -Wait -PassThru

  if ($p.ExitCode -eq 0) {
    Log "[INFO] ADO installer completed (0)."
  }
  elseif ($p.ExitCode -eq 3010) {
    Log "[INFO] ADO installer completed (3010 = reboot required). Not rebooting automatically."
    $global:RebootRequired = $true
  }
  else {
    throw "ADO installer failed with exit code $($p.ExitCode)"
  }
}

function Find-TfsConfig {
  $tfsConfig = Get-ChildItem -Path "C:\Program Files\Azure DevOps Server*\Tools\TfsConfig.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $tfsConfig) {
    $tfsConfig = Get-ChildItem -Path "C:\Program Files\Microsoft Team Foundation Server*\Tools\TfsConfig.exe" -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
  }
  return $tfsConfig
}

function Prepare-AdoUnattendBasic {
  param(
    [int]$Port,
    [string]$Instance,
    [string]$Collection
  )

  $tfsConfig = Find-TfsConfig
  if (-not $tfsConfig) { throw "Could not find TfsConfig.exe after install." }

  $iniPath = "C:\Tools\ado-basic.ini"
  if (-not (Test-Path $iniPath)) {
    Log "[INFO] Creating ADO unattend file..."
    & $tfsConfig unattend /create /type:basic /unattendfile:$iniPath | Out-Null
  }

  $machine = $env:COMPUTERNAME

  # IMPORTANT:
  # - Use "localhost\SQLEXPRESS" (ADO rejects '.' and '(local)' for SQL server identifier)
  # - SiteBindings wants port 80 by default; we set binding explicitly to Port
  $sqlLine          = "SqlInstance=localhost\$Instance"
  $siteBindingsLine = "SiteBindings=http:*:$($Port):"
  $publicUrlLine    = "PublicUrl=http://$machine`:$($Port)/"
  $collectionLine   = "CollectionName=$Collection"

  Log "[INFO] Updating unattend file values..."
  (Get-Content $iniPath) `
    -replace '^SqlInstance=.*$', $sqlLine `
    -replace '^SiteBindings=.*$', $siteBindingsLine `
    -replace '^PublicUrl=.*$', $publicUrlLine `
    -replace '^CollectionName=.*$', $collectionLine |
    Set-Content -Path $iniPath -Encoding UTF8

  Log "[INFO] Unattend file prepared at: $iniPath"
}

# ---------------------------
# Main
# ---------------------------
try {
  Assert-Admin
  Ensure-Tls12

  Log "[INFO] === Installing prerequisites, SQL, and ADO Express (scripted) ==="
  Install-IisPrereqs
  Ensure-SqlExpress -Instance $SqlInstance

  # CRITICAL FIX: grant sysadmin to the interactive local admin user
  Ensure-SqlSysadminForUser -Instance $SqlInstance -User $AdminUser

  Install-AdoExpress
  Prepare-AdoUnattendBasic -Port $AdoPort -Instance $SqlInstance -Collection $CollectionName

  Log "[INFO] Next step (reliable):"
  Log "       Open 'Azure DevOps Server Administration Console' -> Configure Installed Features -> Basic"
  Log "       Use SQL: localhost\$SqlInstance, Port: $AdoPort"
  Log "       You should no longer see the TF255475 sysadmin/serveradmin error."

  if ($global:RebootRequired) {
    Log "[INFO] Reboot is recommended (installer returned 3010)."
    Log "       Reboot AFTER Terraform apply completes."
  }

  Log "[INFO] DONE."
}
finally {
  try { Stop-Transcript } catch {}
}
