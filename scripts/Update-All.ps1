<#
.SYNOPSIS
    Refreshes citation data and rebuilds the page. This is the one to run.

.DESCRIPTION
    Runs Fetch-Publications.ps1 then Build-Site.ps1. Run it whenever you want the
    page to reflect current citation counts - monthly is plenty, since OpenAlex
    itself only reindexes periodically.

    With -Publish, commits the refreshed data and pushes, which redeploys the
    live page if GitHub Pages is serving this repository.

.PARAMETER Email
    Contact email for the OpenAlex polite pool. Defaults to $env:OPENALEX_EMAIL.

.PARAMETER Publish
    Commit and push the refreshed data and page.

.EXAMPLE
    .\Update-All.ps1
    Refresh the data and rebuild index.html locally.

.EXAMPLE
    .\Update-All.ps1 -Publish
    Refresh, rebuild, commit and push - updating the live site.
#>
[CmdletBinding()]
param(
    [string] $Email = $env:OPENALEX_EMAIL,
    [switch] $Publish
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'Fetch-Publications.ps1') -Email $Email
Write-Host ""
& (Join-Path $PSScriptRoot 'Build-Network.ps1')
Write-Host ""
& (Join-Path $PSScriptRoot 'Build-Site.ps1')

if ($Publish) {
    Write-Host ""
    Push-Location $root
    try {
        $changed = git status --porcelain -- index.html data
        if (-not $changed) {
            Write-Host "No changes since the last update - nothing to publish." -ForegroundColor Yellow
            return
        }
        $summary = Get-Content (Join-Path $root 'data\summary.json') -Raw | ConvertFrom-Json
        git add index.html data
        git commit -m "Update citation data ($($summary.total_citations) citations, $($summary.total_papers) papers)"
        git push
        Write-Host "Pushed. GitHub Pages redeploys in about a minute." -ForegroundColor Green
    }
    finally { Pop-Location }
}
