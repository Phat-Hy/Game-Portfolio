<#
.SYNOPSIS
    Publish the portfolio to Azure Blob Storage static website hosting.

.DESCRIPTION
    Creates (or reuses) a resource group and a general-purpose v2 storage account,
    enables the static website endpoint, and uploads the site.

    Idempotent: safe to re-run. Storage account names are globally unique, so the
    chosen name and region are recorded in .deploy-state.json and reused.

    Azure for Students subscriptions apply a region allow-list policy that rejects
    some locations with RequestDisallowedByAzure, so the region is probed rather
    than assumed.

.NOTES
    Requires an authenticated Azure CLI session.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-portfolio-phathy',
    [string] $Location      = '',
    [string] $AccountName   = '',
    [string] $SourceDir     = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# Run az and fail loudly on a non-zero exit code. Native commands do not throw,
# and the previous version happily reported "upload complete" over a hard error.
function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $AzArgs)
    $out = & az @AzArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $text = ($out | Out-String).Trim()
        throw "az $($AzArgs -join ' ') failed ($code):`n$text"
    }
    return $out
}

# ---------------------------------------------------------------- preflight

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) not found on PATH.'
}

$stateFile = Join-Path $SourceDir '.deploy-state.json'
$state = @{}
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
}

$placeholders = Get-ChildItem -Path $SourceDir -Recurse -File -Include *.html, *.css, *.js |
    Select-String -Pattern '__[A-Z][A-Z0-9_]*__' -AllMatches
if ($placeholders) {
    Write-Host ''
    Write-Host 'Refusing to publish: unresolved placeholders found.' -ForegroundColor Red
    $placeholders | ForEach-Object {
        Write-Host ("    {0}:{1}  {2}" -f $_.Filename, $_.LineNumber, $_.Matches[0].Value)
    }
    throw 'Unresolved placeholders in site source.'
}

# ------------------------------------------------------------- account name

if (-not $AccountName) {
    if ($state.ContainsKey('accountName')) {
        $AccountName = $state['accountName']
    } else {
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $AccountName = "phathycv$suffix"
    }
}
$AccountName = $AccountName.ToLower()
if ($AccountName -notmatch '^[a-z0-9]{3,24}$') {
    throw "Invalid storage account name '$AccountName' (3-24 lowercase letters/digits)."
}

# --------------------------------------------------------------- provision

Write-Step 'Checking Azure sign-in'
Invoke-Az account show --output none | Out-Null
$acct = Invoke-Az account show --query '{name:name,id:id}' --output json | ConvertFrom-Json
Write-Ok ("subscription: {0}" -f $acct.name)

Write-Step "Resource group: $ResourceGroup"
$rgExists = & az group exists --name $ResourceGroup 2>$null
if ("$rgExists".Trim() -ne 'true') {
    $rgRegion = if ($Location) { $Location } else { 'eastasia' }
    Invoke-Az group create --name $ResourceGroup --location $rgRegion --output none | Out-Null
    Write-Ok "created in $rgRegion"
} else {
    Write-Ok 'already exists, reusing'
}

Write-Step "Storage account: $AccountName"
$existingRegion = $null
$probe = & az storage account show --name $AccountName --resource-group $ResourceGroup --query 'location' --output tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $probe) {
    $existingRegion = "$probe".Trim()
    Write-Ok "already exists in $existingRegion, reusing"
}

if (-not $existingRegion) {
    if ($state.ContainsKey('location') -and -not $Location) { $Location = $state['location'] }
    $candidates = @($Location) + @('eastasia', 'japaneast', 'eastus', 'westeurope',
                                  'centralus', 'australiaeast', 'westus2') |
        Where-Object { $_ } | Select-Object -Unique

    $created = $false
    foreach ($region in $candidates) {
        $out = & az storage account create --name $AccountName --resource-group $ResourceGroup `
            --location $region --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
            --allow-blob-public-access true --output none 2>&1
        if ($LASTEXITCODE -eq 0) {
            $Location = $region
            $created = $true
            Write-Ok "created in $region"
            break
        }
        if (($out | Out-String) -match 'RequestDisallowedByAzure|disallowed by Azure') {
            Write-Warn "$region disallowed by subscription policy, trying next"
            continue
        }
        throw "storage account create failed in ${region}:`n$($out | Out-String)"
    }
    if (-not $created) { throw 'No permitted region found for the storage account.' }
} else {
    $Location = $existingRegion
}

Write-Step 'Enabling static website hosting'
Invoke-Az storage blob service-properties update --account-name $AccountName --static-website `
    --index-document 'index.html' --404-document 'index.html' --auth-mode login --output none | Out-Null
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

    # --auth-mode login needs a data-plane RBAC role (Storage Blob Data
    # Contributor) that this subscription does not grant; account keys do work.
    Invoke-Az storage blob upload-batch --account-name $AccountName --destination '$web' `
        --source $uploadRoot --overwrite --auth-mode key --only-show-errors --output none | Out-Null
} finally {
    Remove-Item $uploadRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Ok 'upload complete'

# --------------------------------------------------------------- endpoint

$webEndpoint = (Invoke-Az storage account show --name $AccountName --resource-group $ResourceGroup `
    --query 'primaryEndpoints.web' --output tsv | Out-String).Trim()
if (-not $webEndpoint) { throw 'Could not read the static website endpoint.' }
$webEndpoint = $webEndpoint.TrimEnd('/')

@{ accountName = $AccountName; resourceGroup = $ResourceGroup; location = $Location; url = $webEndpoint } |
    ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

Write-Host ''
Write-Host 'Site published:' -ForegroundColor Green
Write-Host "    $webEndpoint/" -ForegroundColor White
Write-Host ''

return $webEndpoint
