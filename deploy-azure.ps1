<#
.SYNOPSIS
    Publish the portfolio to Azure Blob Storage static website hosting.

.DESCRIPTION
    Creates (or reuses) a resource group and a general-purpose v2 storage account,
    enables the static website endpoint, and uploads the site.

    Idempotent: safe to re-run. Storage account names are globally unique, so the
    chosen name is recorded in .deploy-state.json and reused on later runs.

.NOTES
    Requires an authenticated Azure CLI session with permission to create the
    resource group and storage account.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-portfolio-phathy',
    [string] $Location      = 'southeastasia',
    [string] $AccountName   = '',
    [string] $SourceDir     = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- preflight

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) not found on PATH.'
}

$stateFile = Join-Path $SourceDir '.deploy-state.json'
$state = @{}
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
}

# Refuse to publish placeholder contact details.
$placeholders = Get-ChildItem -Path $SourceDir -Recurse -File -Include *.html, *.css, *.js |
    Select-String -Pattern '__[A-Z][A-Z0-9_]*__' -AllMatches
if ($placeholders) {
    Write-Host ''
    Write-Host 'Refusing to publish: unresolved placeholders found.' -ForegroundColor Red
    $placeholders | ForEach-Object {
        Write-Host ("    {0}:{1}  {2}" -f $_.Filename, $_.LineNumber, $_.Matches[0].Value)
    }
    Write-Host ''
    Write-Host 'Replace them (at minimum __EMAIL__) and re-run.' -ForegroundColor Yellow
    throw 'Unresolved placeholders in site source.'
}

# ------------------------------------------------------------- account name

if (-not $AccountName) {
    if ($state.ContainsKey('accountName')) {
        $AccountName = $state['accountName']
    } else {
        # must be 3-24 chars, lowercase letters and digits, globally unique
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $AccountName = "phathycv$suffix"
    }
}
$AccountName = $AccountName.ToLower()
if ($AccountName -notmatch '^[a-z0-9]{3,24}$') {
    throw "Invalid storage account name '$AccountName' (3-24 lowercase letters/digits)."
}

# --------------------------------------------------------------- provision

Write-Step "Checking Azure sign-in"
$acct = az account show --output json | ConvertFrom-Json
Write-Ok ("subscription: {0}" -f $acct.name)

Write-Step "Resource group: $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location --output none
Write-Ok 'resource group ready'

Write-Step "Storage account: $AccountName"
$exists = az storage account show --name $AccountName --resource-group $ResourceGroup `
    --query 'name' --output tsv 2>$null
if (-not $exists) {
    az storage account create `
        --name $AccountName `
        --resource-group $ResourceGroup `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access true `
        --output none
    Write-Ok 'created'
} else {
    Write-Ok 'already exists, reusing'
}

Write-Step 'Enabling static website hosting'
az storage blob service-properties update `
    --account-name $AccountName `
    --static-website `
    --index-document 'index.html' `
    --404-document 'index.html' `
    --auth-mode login `
    --output none
Write-Ok 'static website enabled'

# ------------------------------------------------------------ upload

Write-Step "Uploading from $SourceDir"
$exclude = @('.git', '.deploy-state.json', 'deploy-azure.ps1', '.github')
$uploadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("portfolio-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $uploadRoot | Out-Null

try {
    Get-ChildItem -Path $SourceDir -File | Where-Object { $exclude -notcontains $_.Name } |
        ForEach-Object { Copy-Item $_.FullName -Destination $uploadRoot }
    Get-ChildItem -Path $SourceDir -Directory |
        Where-Object { $exclude -notcontains $_.Name } |
        ForEach-Object { Copy-Item $_.FullName -Destination $uploadRoot -Recurse }

    az storage blob upload-batch `
        --account-name $AccountName `
        --destination '$web' `
        --source $uploadRoot `
        --overwrite `
        --auth-mode login `
        --only-show-errors `
        --output none
} finally {
    Remove-Item $uploadRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Ok 'upload complete'

# --------------------------------------------------------------- endpoint

$webEndpoint = az storage account show `
    --name $AccountName `
    --resource-group $ResourceGroup `
    --query 'primaryEndpoints.web' --output tsv

$webEndpoint = $webEndpoint.TrimEnd('/')

@{ accountName = $AccountName; resourceGroup = $ResourceGroup; url = $webEndpoint } |
    ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

Write-Host ''
Write-Host 'Site published:' -ForegroundColor Green
Write-Host "    $webEndpoint/" -ForegroundColor White
Write-Host ''
Write-Host "State saved to $stateFile (used to reuse the account on re-runs)." -ForegroundColor DarkGray

return $webEndpoint
