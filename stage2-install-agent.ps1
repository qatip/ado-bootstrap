param(
  [string]$AdoUrl = "http://localhost:8080/",
  [string]$Pool   = "Default",
  [string]$AgentVersion = "4.268.0"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-agent.log" -Append

function Log { param([string]$m) Write-Host "[INFO] $m" }

# Prompt user for PAT
Write-Host ""
Write-Host "Paste your Azure DevOps Personal Access Token when prompted."
$securePat = Read-Host "Enter PAT" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
$Pat = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$agentZip = "C:\Tools\vsts-agent-win-x64-$AgentVersion.zip"
$agentUri = "https://download.agent.dev.azure.com/agent/$AgentVersion/vsts-agent-win-x64-$AgentVersion.zip"
$agentDir = "C:\ado-agent"

Log "Downloading Azure Pipelines agent..."
Invoke-WebRequest -Uri $agentUri -OutFile $agentZip -UseBasicParsing

Log "Extracting agent..."
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
Expand-Archive -Path $agentZip -DestinationPath $agentDir -Force

Set-Location $agentDir

Log "Configuring agent..."

.\config.cmd --unattended `
  --url "$AdoUrl" `
  --auth pat `
  --token "$Pat" `
  --pool "$Pool" `
  --agent $env:COMPUTERNAME `
  --acceptTeeEula `
  --runAsService `
  --work "_work" `
  --replace

Log "Agent installed and registered."

Stop-Transcript
