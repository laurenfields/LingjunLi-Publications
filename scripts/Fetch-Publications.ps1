<#
.SYNOPSIS
    Fetches publications and per-year citation counts from OpenAlex, keyed by ORCID.

.DESCRIPTION
    Pulls every work OpenAlex attributes to the ORCID in config/profile.json, drops the
    works listed in that file's `excluded_works` (misattributions and duplicate deposits),
    and writes a cleaned dataset to data/publications.json plus rolled-up totals to
    data/summary.json.

    OpenAlex is used rather than ORCID's own API because ORCID carries no citation data.
    Both are keyed on the same ORCID, so the join is exact.

    No API key required. OpenAlex asks for an email in the User-Agent to get you into
    their faster "polite pool" - set -Email or the OPENALEX_EMAIL environment variable.

.PARAMETER Email
    Contact email sent to OpenAlex for polite-pool access. Defaults to $env:OPENALEX_EMAIL.

.PARAMETER ConfigPath
    Path to profile.json. Defaults to config/profile.json next to this script.

.PARAMETER OutputDir
    Where to write publications.json and summary.json. Defaults to data/.

.EXAMPLE
    .\Fetch-Publications.ps1
    Refresh the dataset using the configured ORCID.

.EXAMPLE
    .\Fetch-Publications.ps1 -Email you@university.edu
    Refresh via the OpenAlex polite pool.
#>
[CmdletBinding()]
param(
    [string] $Email      = $env:OPENALEX_EMAIL,
    [string] $ConfigPath,
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\profile.json' }
if (-not $OutputDir)  { $OutputDir  = Join-Path $root 'data' }

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

# Read and write through .NET rather than Get-Content/Out-File: Windows PowerShell 5.1
# reads as ANSI by default and writes UTF-8 with a BOM, either of which corrupts the
# non-ASCII characters in this data (en dashes in affiliations, accented author names).
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$cfg = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json

if (-not $cfg.orcid) { throw "profile.json is missing an 'orcid' field." }
Write-Host "Fetching works for ORCID $($cfg.orcid) ..." -ForegroundColor Cyan

# --- Build the request -------------------------------------------------------
$ua = if ($Email) { "MyPublications/1.0 (mailto:$Email)" } else { 'MyPublications/1.0' }
if (-not $Email) {
    Write-Warning "No email set - using the OpenAlex common pool (slower). Pass -Email or set OPENALEX_EMAIL."
}

$fields = @(
    'id','doi','title','publication_year','publication_date','cited_by_count',
    'counts_by_year','authorships','primary_location','open_access','type'
) -join ','

# OpenAlex caps per-page at 200; page through in case the list outgrows one page.
$works  = [System.Collections.Generic.List[object]]::new()
$page   = 1
do {
    $uri = "https://api.openalex.org/works" +
           "?filter=author.orcid:$($cfg.orcid)" +
           "&per-page=200&page=$page&select=$fields"
    $resp = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = $ua }
    foreach ($w in $resp.results) { $works.Add($w) | Out-Null }
    $page++
} while ($resp.results.Count -eq 200)

Write-Host "  OpenAlex returned $($works.Count) works." -ForegroundColor DarkGray

# --- Work-type filter --------------------------------------------------------
# Prolific profiles accumulate supplementary-material stubs, dataset deposits and
# conference abstracts that are artifacts of indexing, not publications. Omit
# include_types from the config to keep everything.
if ($cfg.PSObject.Properties.Name -contains 'include_types' -and $cfg.include_types) {
    $keepTypes = @($cfg.include_types)
    $before = $works.Count
    $typed = [System.Collections.Generic.List[object]]::new()
    $byType = @{}
    foreach ($w in $works) {
        if ($keepTypes -contains $w.type) { $typed.Add($w) | Out-Null }
        else { $byType[$w.type] = [int]$byType[$w.type] + 1 }
    }
    $works = $typed
    if ($before -ne $works.Count) {
        Write-Host "  kept $($works.Count) of $before by type; dropped:" -ForegroundColor DarkYellow
        foreach ($t in ($byType.Keys | Sort-Object)) {
            Write-Host "    $($byType[$t]) x $t" -ForegroundColor DarkYellow
        }
    }
}

# --- Apply the exclusion list ------------------------------------------------
$excluded = @{}
foreach ($e in $cfg.excluded_works) { $excluded[$e.id] = $e }

# Crossref-CV.ps1 writes a machine-generated exclusion list when a CV is available to
# arbitrate a merged ORCID. Merge it with the hand-maintained list above.
$genPath = Join-Path (Split-Path -Parent $ConfigPath) 'exclusions.generated.json'
if (Test-Path $genPath) {
    $gen = [System.IO.File]::ReadAllText($genPath) | ConvertFrom-Json
    foreach ($e in $gen.excluded) { if (-not $excluded.ContainsKey($e.id)) { $excluded[$e.id] = $e } }
    Write-Host "  merged $(@($gen.excluded).Count) generated exclusions from $(Split-Path -Leaf $genPath)" -ForegroundColor DarkGray
}

$kept    = [System.Collections.Generic.List[object]]::new()
$dropped = [System.Collections.Generic.List[object]]::new()
foreach ($w in $works) {
    $shortId = $w.id -replace 'https://openalex\.org/', ''
    if ($excluded.ContainsKey($shortId)) { $dropped.Add($excluded[$shortId]) | Out-Null }
    else                                 { $kept.Add($w) | Out-Null }
}

# A merged ORCID can produce well over a hundred exclusions; list them only when the
# count is small enough to actually read.
if ($dropped.Count -le 12) {
    foreach ($d in $dropped) {
        Write-Host "  excluded $($d.id) ($($d.year), $($d.reason))" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  excluded $($dropped.Count) works (see config/exclusions.generated.json for each reason)" -ForegroundColor DarkYellow
}

# Warn if the config lists an exclusion OpenAlex no longer returns - it may have been
# fixed upstream, in which case the entry can be retired from profile.json.
foreach ($id in $excluded.Keys) {
    if ($works.id -notcontains "https://openalex.org/$id") {
        Write-Warning "Exclusion $id no longer appears in OpenAlex results - it may be safe to remove from profile.json."
    }
}

# --- Normalise ---------------------------------------------------------------
$orcidUrl  = "https://orcid.org/$($cfg.orcid)"
$preprints = @($cfg.preprint_venues)

# Shared first authorship exists only in the paper's own text, never in the API, so it
# comes from the config rather than from OpenAlex's author_position.
$coFirst = @{}
if ($cfg.PSObject.Properties.Name -contains 'co_first_author_works') {
    foreach ($c in $cfg.co_first_author_works) { $coFirst[$c.id] = $true }
}

$pubs = foreach ($w in $kept) {
    # OpenAlex omits fields rather than nulling them, and StrictMode turns a missing
    # property into a terminating error. Small records (errata, deposits, some older
    # papers) routinely lack primary_location, source, or open_access.
    $authors = @(
        foreach ($a in @($w.authorships)) {
            if ($a.PSObject.Properties.Name -contains 'author' -and $a.author -and
                $a.author.PSObject.Properties.Name -contains 'display_name') {
                $a.author.display_name
            }
        }
    )

    # Locate the profile author to record first/middle/last authorship.
    $me = $w.authorships | Where-Object { $_.author.orcid -eq $orcidUrl } | Select-Object -First 1
    if (-not $me) {
        # Fall back to a name match when OpenAlex has not stamped the ORCID on this record.
        $me = $w.authorships |
              Where-Object { $_.author.display_name -like "*$($cfg.name.Split(' ')[-1])*" } |
              Select-Object -First 1
    }

    $venue = $null
    if ($w.PSObject.Properties.Name -contains 'primary_location' -and $w.primary_location -and
        $w.primary_location.PSObject.Properties.Name -contains 'source' -and $w.primary_location.source) {
        $venue = $w.primary_location.source.display_name
    }
    if (-not $venue) { $venue = 'No venue listed' }

    # Publisher feeds carry inline markup that reaches OpenAlex HTML-encoded, e.g.
    # "&lt;i&gt;Aloe Vera&lt;/i&gt;". Decode first, THEN strip tags - stripping first
    # matches nothing and the later decode leaves a literal <i> in the title.
    $title = ([System.Net.WebUtility]::HtmlDecode($w.title) -replace '<[^>]+>', '').Trim()
    # Collapse whitespace left behind by removed markup.
    $title = $title -replace '\s{2,}', ' '

    $shortId  = $w.id -replace 'https://openalex\.org/', ''
    $isCoFirst = $coFirst.ContainsKey($shortId)
    $position  = if ($me) { $me.author_position } else { $null }

    [pscustomobject]@{
        title       = $title
        year        = $w.publication_year
        date        = $w.publication_date
        venue       = $venue
        doi         = $w.doi
        url         = if ($w.doi) { $w.doi } else { $w.id }
        authors     = $authors
        author_count= $authors.Count
        position    = $position
        is_co_first = $isCoFirst
        # True for sole-first and shared-first alike - what "first author" means on a CV.
        leads       = ($position -eq 'first' -or $isCoFirst)
        citations   = $w.cited_by_count
        by_year     = @($w.counts_by_year | Sort-Object year |
                        ForEach-Object { [pscustomobject]@{ year = $_.year; count = $_.cited_by_count } })
        is_preprint = [bool]($preprints -contains $venue)
        open_access = [bool]($w.PSObject.Properties.Name -contains 'open_access' -and
                             $w.open_access -and $w.open_access.is_oa)
        type        = $w.type
        openalex_id = $w.id
    }
}

$pubs = @($pubs | Sort-Object @{Expression='year';Descending=$true}, @{Expression='citations';Descending=$true})

# A co-first ID that matches nothing is almost always a typo, and it would silently
# undercount first authorships rather than erroring.
foreach ($id in $coFirst.Keys) {
    if ($pubs.openalex_id -notcontains "https://openalex.org/$id") {
        Write-Warning "co_first_author_works entry $id matches no publication - check the ID in profile.json."
    }
}

# --- Roll-up stats -----------------------------------------------------------
# Citations received per calendar year, summed across every paper.
$perYear = @{}
foreach ($p in $pubs) {
    foreach ($c in $p.by_year) { $perYear[$c.year] = ([int]$perYear[$c.year]) + $c.count }
}

$cumulative = 0
$growth = foreach ($y in ($perYear.Keys | Sort-Object)) {
    $cumulative += $perYear[$y]
    [pscustomobject]@{ year = $y; received = $perYear[$y]; cumulative = $cumulative }
}

# h-index: the largest h where h papers each have >= h citations.
$desc = @($pubs.citations | Sort-Object -Descending)
$h = 0
for ($i = 0; $i -lt $desc.Count; $i++) { if ($desc[$i] -ge ($i + 1)) { $h = $i + 1 } }

$byYear = foreach ($g in ($pubs | Group-Object year | Sort-Object Name)) {
    [pscustomobject]@{
        year       = [int]$g.Name
        papers     = $g.Count
        citations  = ($g.Group | Measure-Object citations -Sum).Sum
    }
}

$summary = [pscustomobject]@{
    name             = $cfg.name
    orcid            = $cfg.orcid
    affiliation      = $cfg.affiliation
    tagline          = $cfg.tagline
    generated_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    current_year     = (Get-Date).Year
    total_papers     = $pubs.Count
    total_citations  = ($pubs | Measure-Object citations -Sum).Sum
    h_index          = $h
    i10_index        = @($pubs | Where-Object { $_.citations -ge 10 }).Count
    first_author     = @($pubs | Where-Object { $_.leads }).Count
    co_first_author  = @($pubs | Where-Object { $_.is_co_first }).Count
    # For a PI the meaningful figure is senior (last) authorship, not first - they are
    # last author on their own lab's output. Which one the page leads with is set by
    # kpi_authorship in the config.
    last_author      = @($pubs | Where-Object { $_.position -eq 'last' }).Count
    kpi_authorship   = if ($cfg.PSObject.Properties.Name -contains 'kpi_authorship') { $cfg.kpi_authorship } else { 'first' }
    preprints        = @($pubs | Where-Object { $_.is_preprint }).Count
    open_access      = @($pubs | Where-Object { $_.open_access }).Count
    excluded_count   = $dropped.Count
    # False means the exclusion/co-first lists were never verified by a human, which
    # the page states outright rather than implying an accuracy it does not have.
    curated          = [bool]($cfg.PSObject.Properties.Name -contains 'curated' -and $cfg.curated)
    # Optional prose shown in the footer, for when "curated" is too blunt a summary of
    # how the list was actually arrived at.
    curation_note    = if ($cfg.PSObject.Properties.Name -contains 'curation_note') { $cfg.curation_note } else { $null }
    citation_growth  = @($growth)
    papers_by_year   = @($byYear)
}

# --- Write -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$pubsPath = Join-Path $OutputDir 'publications.json'
$sumPath  = Join-Path $OutputDir 'summary.json'

[System.IO.File]::WriteAllText($pubsPath, ($pubs    | ConvertTo-Json -Depth 8), $Utf8NoBom)
[System.IO.File]::WriteAllText($sumPath,  ($summary | ConvertTo-Json -Depth 8), $Utf8NoBom)

Write-Host ""
Write-Host "Wrote $($pubs.Count) publications -> $pubsPath" -ForegroundColor Green
Write-Host "Wrote summary               -> $sumPath"  -ForegroundColor Green
Write-Host ""
Write-Host ("  {0} citations | h-index {1} | i10 {2} | {3} first-author | {4} preprints" -f `
    $summary.total_citations, $summary.h_index, $summary.i10_index,
    $summary.first_author, $summary.preprints) -ForegroundColor Cyan
