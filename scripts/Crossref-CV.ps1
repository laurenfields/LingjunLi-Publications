<#
.SYNOPSIS
    Cross-references OpenAlex works against a CV to separate real publications from
    other researchers merged in under the same ORCID.

.DESCRIPTION
    OpenAlex has merged at least four researchers named Lingjun Li into one author
    entity and stamped this ORCID on all of them, so `author.orcid` alone returns a
    mix of people. Her own ORCID record lists only 6 works, so it cannot arbitrate.

    This script uses the CV as the authority and applies four independent signals:

      1. CV title match  - the paper's title appears in the CV publication list
      2. CV DOI match    - the paper's DOI appears in the CV
      3. Affiliation     - her authorship lists Wisconsin or Illinois (her PhD and
                           faculty institutions)
      4. Co-author overlap - the paper shares co-authors with already-confirmed work

    Each work lands in one of three verdicts:

      keep     - confirmed by the CV, or strongly corroborated
      drop     - a foreign affiliation is recorded and nothing else corroborates
      review   - genuinely ambiguous; a human decides

    "review" rows are written to data/review-queue.csv with a blank `decision`
    column. Fill it with keep or drop and re-run Apply-Review.ps1.

    Requires pdftotext (poppler) on PATH to read the CV.

.PARAMETER CvPath
    The CV PDF. Defaults to LLi_CV.pdf in the project root.

.EXAMPLE
    .\Crossref-CV.ps1
#>
[CmdletBinding()]
param(
    [string] $CvPath,
    [string] $ConfigPath,
    [string] $DataDir,
    [string] $Email = $env:OPENALEX_EMAIL
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $CvPath)     { $CvPath     = Join-Path $root 'LLi_CV.pdf' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\profile.json' }
if (-not $DataDir)    { $DataDir    = Join-Path $root 'data' }

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$cfg = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json

if (-not (Test-Path $CvPath)) { throw "CV not found: $CvPath" }
if (-not (Get-Command pdftotext -ErrorAction SilentlyContinue)) {
    throw "pdftotext (poppler) is required to read the CV and was not found on PATH."
}

# --- Read the CV -------------------------------------------------------------
$txtPath = Join-Path $env:TEMP ("cv_" + [guid]::NewGuid().ToString('N') + ".txt")
& pdftotext -layout $CvPath $txtPath | Out-Null
$cvRaw = [System.IO.File]::ReadAllText($txtPath)
Remove-Item $txtPath -Force

# Everything from the first publication heading to the patents/talks section. Taking
# the whole document would match against talk titles and grant names too.
$startRx = '(?im)^\s*(peer-reviewed publications|publications based on)'
$endRx   = '(?im)^\s*(patents?\s*:|invited seminars)'
$s = [regex]::Match($cvRaw, $startRx)
$e = [regex]::Match($cvRaw, $endRx)
$pubText = if ($s.Success -and $e.Success -and $e.Index -gt $s.Index) {
    $cvRaw.Substring($s.Index, $e.Index - $s.Index)
} else {
    Write-Warning "Could not locate the publication section headings; using the whole CV."
    $cvRaw
}

$cvNorm = ($pubText.ToLower() -replace '[^a-z0-9]+', ' ').Trim()
$cvDois = @{}
foreach ($m in [regex]::Matches($pubText.ToLower(), '10\.\d{4,9}/[^\s,;)"]+')) {
    $cvDois[$m.Value.TrimEnd('.', ',', ';')] = $true
}
Write-Host "CV: $($cvNorm.Length) chars of publications, $($cvDois.Count) DOIs" -ForegroundColor DarkGray

# --- Fetch works -------------------------------------------------------------
$ua = if ($Email) { "MyPublications/1.0 (mailto:$Email)" } else { 'MyPublications/1.0' }
$sel = 'id,doi,title,publication_year,cited_by_count,authorships,primary_location,type'
$works = [System.Collections.Generic.List[object]]::new()
$page = 1
do {
    $resp = Invoke-RestMethod -Uri ("https://api.openalex.org/works?filter=author.orcid:$($cfg.orcid)&per-page=200&page=$page&select=$sel") -Headers @{ 'User-Agent' = $ua }
    foreach ($w in $resp.results) { $works.Add($w) | Out-Null }
    $page++
} while ($resp.results.Count -eq 200)
Write-Host "OpenAlex: $($works.Count) works for ORCID $($cfg.orcid)" -ForegroundColor DarkGray

$keepTypes = if ($cfg.PSObject.Properties.Name -contains 'include_types' -and $cfg.include_types) { @($cfg.include_types) } else { $null }
$homeRx = if ($cfg.PSObject.Properties.Name -contains 'home_institutions' -and $cfg.home_institutions) {
    ($cfg.home_institutions | ForEach-Object { [regex]::Escape($_) }) -join '|'
} else { 'Wisconsin' }

$nameRx = '^' + [regex]::Escape($cfg.name.Split(' ')[0]) + '.*' + [regex]::Escape($cfg.name.Split(' ')[-1])

function Test-TitleInCv([string] $title) {
    $t = ($title -replace '[^a-zA-Z0-9]+', ' ').ToLower().Trim()
    if ($t.Length -lt 25) { return $false }
    # Several probes: a CV may abbreviate a long subtitle at either end, and
    # pdftotext line-wrapping can mangle the middle.
    if ($t.Length -ge 40) {
        if ($cvNorm.Contains($t.Substring(0, 40)))               { return $true }
        if ($cvNorm.Contains($t.Substring($t.Length - 40, 40)))  { return $true }
    }
    return $cvNorm.Contains($t)
}

# --- Pass 1: CV, DOI and affiliation -----------------------------------------
$rows = foreach ($w in $works) {
    if ($keepTypes -and $keepTypes -notcontains $w.type) { continue }

    # OpenAlex omits sub-objects rather than nulling them; StrictMode turns a missing
    # property into a terminating error, and a few records have authorships with no
    # author and authors with no institutions.
    $names = @(
        foreach ($a in @($w.authorships)) {
            if ($a.PSObject.Properties.Name -contains 'author' -and $a.author -and
                $a.author.PSObject.Properties.Name -contains 'display_name' -and $a.author.display_name) {
                $a.author.display_name
            }
        }
    )
    $me = $w.authorships | Where-Object {
        $_.PSObject.Properties.Name -contains 'author' -and $_.author -and
        $_.author.PSObject.Properties.Name -contains 'display_name' -and
        $_.author.display_name -match $nameRx
    } | Select-Object -First 1
    $inst = ''
    if ($me -and $me.PSObject.Properties.Name -contains 'institutions' -and $me.institutions) {
        $inst = ((@(
            foreach ($i in @($me.institutions)) {
                if ($i -and $i.PSObject.Properties.Name -contains 'display_name') { $i.display_name }
            }
        ) | Where-Object { $_ }) -join '; ')
    }

    $ven = ''
    if ($w.primary_location -and $w.primary_location.source) { $ven = $w.primary_location.source.display_name }

    $doi = if ($w.doi) { ($w.doi -replace '^https?://(dx\.)?doi\.org/', '').ToLower() } else { '' }

    [pscustomobject]@{
        id       = ($w.id -replace 'https://openalex\.org/', '')
        title    = $w.title
        year     = $w.publication_year
        cites    = $w.cited_by_count
        venue    = $ven
        inst     = $inst
        atHome   = [bool]($inst -match $homeRx)
        inCv     = (Test-TitleInCv $w.title)
        doiInCv  = [bool]($doi -and $cvDois.ContainsKey($doi))
        authors  = ((@($names) | Where-Object { $_ -notmatch $nameRx }) -join '; ')
        overlap  = 0
        verdict  = ''
    }
}
$rows = @($rows)

# --- Pass 2: co-author overlap against the confirmed core --------------------
# Anyone who has co-authored a CV-confirmed paper is a real collaborator, so a
# shared name is strong evidence a paper belongs to the same person.
$core = @{}
foreach ($r in $rows) {
    if ($r.inCv -or $r.doiInCv) {
        foreach ($a in ($r.authors -split ';\s*')) { if ($a) { $core[$a] = $true } }
    }
}
Write-Host "Confirmed-core collaborators: $($core.Count)" -ForegroundColor DarkGray

foreach ($r in $rows) {
    $n = 0
    foreach ($a in ($r.authors -split ';\s*')) { if ($a -and $core.ContainsKey($a)) { $n++ } }
    $r.overlap = $n
}

# --- Verdicts ----------------------------------------------------------------
foreach ($r in $rows) {
    if ($r.inCv -or $r.doiInCv) {
        # The CV is the authority; nothing overrides it.
        $r.verdict = 'keep'
    }
    elseif ($r.atHome) {
        # Her authorship carries Wisconsin or Illinois. No other Lingjun Li is at
        # either institution, so this is decisive on its own.
        $r.verdict = 'keep'
    }
    elseif ($r.inst -and $r.overlap -le 2) {
        # A foreign affiliation is recorded. One or two shared surnames across a
        # large author list is coincidence among common names, not evidence - the
        # Soochow prenatal-hypoxia papers all score 1 this way.
        $r.verdict = 'drop'
    }
    elseif (-not $r.inst -and $r.overlap -eq 0) {
        # No affiliation and no shared collaborator: nothing connects it to her.
        $r.verdict = 'drop'
    }
    else {
        # Either a foreign affiliation with substantial collaborator overlap, or no
        # affiliation but shared collaborators. Genuinely ambiguous - ask a human.
        $r.verdict = 'review'
    }
}

# --- Human decisions win --------------------------------------------------------
# Recorded verdicts override every heuristic, so a paper a person has already ruled
# on is never re-litigated when the heuristics or the upstream data shift.
$decPath = Join-Path (Split-Path -Parent $ConfigPath) 'review-decisions.json'
$decided = @{}
if (Test-Path $decPath) {
    $dec = [System.IO.File]::ReadAllText($decPath) | ConvertFrom-Json
    foreach ($d in $dec.decisions) { $decided[$d.id] = $d }
    $applied = 0
    foreach ($r in $rows) {
        if ($decided.ContainsKey($r.id)) { $r.verdict = $decided[$r.id].decision; $applied++ }
    }
    Write-Host "Applied $applied recorded human decisions from review-decisions.json" -ForegroundColor DarkGray
    foreach ($id in $decided.Keys) {
        if ($rows.id -notcontains $id) {
            Write-Warning "review-decisions.json entry $id matches no current work - it may be safe to retire."
        }
    }
}

$k = @($rows | Where-Object { $_.verdict -eq 'keep' }).Count
$d = @($rows | Where-Object { $_.verdict -eq 'drop' }).Count
$v = @($rows | Where-Object { $_.verdict -eq 'review' })

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$rows | Export-Csv (Join-Path $DataDir 'crossref-all.csv') -NoTypeInformation -Encoding UTF8
$v | Select-Object @{n='decision';e={''}}, year, cites, venue, title, inst, overlap, authors, id |
     Export-Csv (Join-Path $DataDir 'review-queue.csv') -NoTypeInformation -Encoding UTF8

# The exclusion list Fetch-Publications consumes. Generated, not hand-edited: rerunning
# this script regenerates it, and any correction belongs in review-decisions.json.
$why = {
    param($r)
    if ($decided.ContainsKey($r.id)) { return "reviewed by hand: $($decided[$r.id].note)" }
    if ($r.inst) { return "affiliation '$($r.inst)' is not hers and only $($r.overlap) co-author(s) overlap her confirmed work" }
    return "not in the CV, no affiliation recorded, and no co-author overlap with her confirmed work"
}
$excl = foreach ($r in ($rows | Where-Object { $_.verdict -eq 'drop' } | Sort-Object year)) {
    [pscustomobject]@{ id = $r.id; year = $r.year; title = $r.title; reason = (& $why $r) }
}
$generated = [pscustomobject]@{
    _comment      = 'GENERATED by Crossref-CV.ps1 - do not hand-edit. OpenAlex merges several researchers named Lingjun Li under this ORCID; these works were attributed to someone else. To change a verdict, add the work to config/review-decisions.json and re-run.'
    generated_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source_cv     = (Split-Path -Leaf $CvPath)
    count         = @($excl).Count
    excluded      = @($excl)
}
[System.IO.File]::WriteAllText(
    (Join-Path (Split-Path -Parent $ConfigPath) 'exclusions.generated.json'),
    ($generated | ConvertTo-Json -Depth 6), $Utf8NoBom)

Write-Host ""
Write-Host "keep   : $k" -ForegroundColor Green
Write-Host "drop   : $d" -ForegroundColor DarkYellow
Write-Host "review : $($v.Count)" -ForegroundColor Cyan
Write-Host ""
if ($v.Count) {
    Write-Host "Review queue -> $(Join-Path $DataDir 'review-queue.csv')" -ForegroundColor Cyan
    Write-Host "Decide each one, record it in config/review-decisions.json, and re-run this script." -ForegroundColor DarkGray
} else {
    Write-Host "Nothing left to review - every work is resolved." -ForegroundColor DarkGray
}
Write-Host "Exclusions -> config/exclusions.generated.json (consumed by Fetch-Publications.ps1)" -ForegroundColor Cyan
