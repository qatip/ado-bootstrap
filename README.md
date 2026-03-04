# ado-bootstrap

This repository contains the bootstrap scripts used to deploy and prepare an **Azure DevOps Server lab environment**.

The scripts are executed at different stages of the VM lifecycle to automate installation tasks and prepare the machine for use as a **self-hosted Azure DevOps build agent**.

---

# Scripts Overview

## stage0-install-ado-server.ps1

Installs **Azure DevOps Server Express** and its prerequisites.

This script is executed automatically by **Terraform using the Azure CustomScriptExtension** during VM deployment.

### What it installs

* IIS and required Windows features
* SQL Server Express
* Azure DevOps Server Express
* Generates an unattended configuration file

### Purpose

Creates a working **Azure DevOps Server instance** on the VM.

---

## stage1-install-tools.ps1

Installs the development tools required for build pipelines.

### Tools Installed

* Git for Windows
* Azure CLI
* Terraform CLI

The script also updates the **system PATH** and reboots the VM to ensure all tools are available.

### Run manually on the VM

```
iwr https://raw.githubusercontent.com/qatip/ado-bootstrap/main/stage1-install-tools.ps1 -OutFile C:\Tools\stage1.ps1
powershell -ExecutionPolicy Bypass -File C:\Tools\stage1.ps1
```

The VM will reboot automatically after the installation.

---

## stage2-install-agent.ps1

Installs and configures the **Azure DevOps self-hosted build agent**.

This step requires a **Personal Access Token (PAT)** generated from Azure DevOps Server.

### Run manually on the VM

```
iwr https://raw.githubusercontent.com/qatip/ado-bootstrap/main/stage2-install-agent.ps1 -OutFile C:\Tools\stage2.ps1

powershell -ExecutionPolicy Bypass -File C:\Tools\stage2.ps1 `
  -AdoUrl "http://vm-devops:8080/" `
  -Pat "<PAT>"
```

### Result

The Azure DevOps Agent will be installed and registered with the **Default Agent Pool**.

---

# Typical Deployment Flow

1. Terraform deploys the VM
2. Terraform executes **stage0-install-ado-server.ps1**
3. User logs into the VM
4. User runs **stage1-install-tools.ps1**
5. VM reboots
6. User runs **stage2-install-agent.ps1**
7. VM becomes a **self-hosted Azure DevOps build agent**

---

# Repository Structure

```
ado-bootstrap
│
├── stage0-install-ado-server.ps1
├── stage1-install-tools.ps1
├── stage2-install-agent.ps1
└── README.md
```

---

# Notes

These scripts are designed for **training environments and lab deployments** and may not reflect production hardening practices.

For production deployments, additional considerations such as secure secret storage, identity management, and network isolation should be implemented.
