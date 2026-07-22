<#
.SYNOPSIS
    Builds the co-authorship network for the interactive collaborator web.

.DESCRIPTION
    Reads data/publications.json and derives:

      - one node per collaborator, weighted by papers shared with the profile author
      - one edge per co-authoring pair, weighted by papers shared
      - research clusters, found by weighted label propagation on the network itself

    Writes data/network.json.

    Clustering is deterministic: nodes are processed in a fixed order and ties break
    lexicographically, so the same input always produces the same groups. Nothing here
    calls a random number generator - a network that regrouped itself on every rebuild
    would be worse than useless for a page people revisit.

    The author's own node is excluded from clustering (they are on every paper by
    definition, so including them collapses everything into one group) and re-added
    at the centre afterwards.

.EXAMPLE
    .\Build-Network.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $DataDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\profile.json' }
if (-not $DataDir)    { $DataDir    = Join-Path $root 'data' }

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$cfg  = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$pubs = [System.IO.File]::ReadAllText((Join-Path $DataDir 'publications.json')) | ConvertFrom-Json

# Match the profile author by given + family name, tolerating a middle initial.
$parts  = $cfg.name.Split(' ')
$selfRe = '^' + [regex]::Escape($parts[0]) + '\b.*\b' + [regex]::Escape($parts[-1]) + '$'

Write-Host "Building collaborator network..." -ForegroundColor Cyan

# --- Nodes -------------------------------------------------------------------
$people = @{}
foreach ($w in $pubs) {
    foreach ($a in @($w.authors)) {
        if ($a -match $selfRe) { continue }
        if (-not $people.ContainsKey($a)) {
            $people[$a] = [pscustomobject]@{
                name = $a; papers = 0; citations = 0; first_year = 9999; last_year = 0
                titles = [System.Collections.Generic.List[string]]::new()
            }
        }
        $n = $people[$a]
        $n.papers++
        $n.citations += $w.citations
        if ($w.year -lt $n.first_year) { $n.first_year = $w.year }
        if ($w.year -gt $n.last_year)  { $n.last_year  = $w.year }
        $n.titles.Add($w.title) | Out-Null
    }
}
Write-Host "  $($people.Count) collaborators" -ForegroundColor DarkGray

# --- Threshold ---------------------------------------------------------------
# A force layout is O(n^2) per tick and unreadable past a few hundred nodes. For a
# long career the graph has to be cut somewhere; cutting by shared-paper count keeps
# the people who define the collaboration structure and drops one-off co-authors.
# The cutoff is reported on the page so nothing is hidden silently.
$minShared = 1
if ($cfg.PSObject.Properties.Name -contains 'network_min_shared' -and $cfg.network_min_shared) {
    $minShared = [int]$cfg.network_min_shared
}
$totalPeople = $people.Count
if ($minShared -gt 1) {
    $keep = @{}
    foreach ($k in $people.Keys) { if ($people[$k].papers -ge $minShared) { $keep[$k] = $people[$k] } }
    $people = $keep
    Write-Host "  $($people.Count) shown (>= $minShared shared papers); $($totalPeople - $people.Count) below the cutoff" -ForegroundColor DarkYellow
}
if ($people.Count -eq 0) { throw "network_min_shared=$minShared excludes every collaborator." }

# --- Edges -------------------------------------------------------------------
# Weighted by number of papers two people share. The author's own edges are implicit
# (they share every paper with everyone here) and are added at render time.
$edgeW = @{}
foreach ($w in $pubs) {
    # Only among people who survived the threshold - an edge to a dropped node would
    # dangle and break the layout.
    $a = @(@($w.authors) | Where-Object { $_ -notmatch $selfRe -and $people.ContainsKey($_) } | Sort-Object)
    for ($i = 0; $i -lt $a.Count; $i++) {
        for ($j = $i + 1; $j -lt $a.Count; $j++) {
            $k = "$($a[$i])||$($a[$j])"
            $edgeW[$k] = [int]$edgeW[$k] + 1
        }
    }
}
Write-Host "  $($edgeW.Count) co-authorship edges" -ForegroundColor DarkGray

# Adjacency for the clustering pass.
$adj = @{}
foreach ($k in $edgeW.Keys) {
    $s, $t = $k -split '\|\|', 2
    if (-not $adj.ContainsKey($s)) { $adj[$s] = @{} }
    if (-not $adj.ContainsKey($t)) { $adj[$t] = @{} }
    $adj[$s][$t] = $edgeW[$k]
    $adj[$t][$s] = $edgeW[$k]
}

# --- Weighted label propagation ---------------------------------------------
# Each node adopts the label carrying the most edge weight among its neighbours.
# Deterministic: fixed node order, ties broken by lexicographically smallest label.
$order = @($people.Keys | Sort-Object)
$label = @{}
foreach ($p in $order) { $label[$p] = $p }

$advisor = if ($cfg.PSObject.Properties.Name -contains 'advisor') { $cfg.advisor } else { $null }

for ($iter = 1; $iter -le 100; $iter++) {
    $changed = 0
    foreach ($p in $order) {
        # The advisor sits on nearly every paper; letting them propagate a label would
        # smear one group across the whole network, so they follow rather than lead.
        if ($p -eq $advisor) { continue }
        if (-not $adj.ContainsKey($p)) { continue }

        $score = @{}
        foreach ($nb in $adj[$p].Keys) {
            if ($nb -eq $advisor) { continue }
            $l = $label[$nb]
            $score[$l] = [int]$score[$l] + $adj[$p][$nb]
        }
        if ($score.Count -eq 0) { continue }

        $best = ($score.GetEnumerator() |
                 Sort-Object @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key}} |
                 Select-Object -First 1).Key
        if ($label[$p] -ne $best) { $label[$p] = $best; $changed++ }
    }
    if ($changed -eq 0) { Write-Host "  clustering converged after $iter passes" -ForegroundColor DarkGray; break }
}

# The advisor joins whichever group they connect to most heavily.
if ($advisor -and $adj.ContainsKey($advisor)) {
    $score = @{}
    foreach ($nb in $adj[$advisor].Keys) { $score[$label[$nb]] = [int]$score[$label[$nb]] + $adj[$advisor][$nb] }
    if ($score.Count) {
        $label[$advisor] = ($score.GetEnumerator() |
            Sort-Object @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key}} |
            Select-Object -First 1).Key
    }
}

# --- Name the clusters -------------------------------------------------------
$stop = @('the','and','for','with','from','via','using','a','an','of','in','on','to','by','its',
          'novel','new','improved','enabling','enabled','advancing','recent','advances','updated',
          'guide','comprehensive','global','high','based','study','studies','analysis','profiling',
          'identification','quantitation','characterization','development','open','source','software',
          'platform','pipeline','automated','optimized','modular','confidence','insights','complexity',
          'diversity','trends','implication','human','disease','research','method','methods','data',
          'is','are','their','this','that','it','as','at','be','can','into','reveal','reveals','role',
          'roles','coupled','through','across','toward','towards','between','under','more','than') |
        ForEach-Object { $_ }
$stopSet = @{}; foreach ($s in $stop) { $stopSet[$s] = $true }

$groups = $people.Keys | Group-Object { $label[$_] } | Sort-Object Count -Descending

# Flatten the override object to a hashtable up front - reaching into an empty
# PSCustomObject's properties throws under StrictMode.
$overrides = @{}
if ($cfg.PSObject.Properties.Name -contains 'cluster_labels' -and $null -ne $cfg.cluster_labels) {
    foreach ($pr in $cfg.cluster_labels.PSObject.Properties) { $overrides[$pr.Name] = $pr.Value }
}

$clusters = @()
$ci = 0
foreach ($g in $groups) {
    $ci++
    $members = @($g.Group | Sort-Object { -$people[$_].papers }, { $_ })

    # Name the cluster from the words that recur in its members' paper titles.
    $freq = @{}
    foreach ($m in $members) {
        foreach ($t in ($people[$m].titles | Select-Object -Unique)) {
            foreach ($word in ([regex]::Matches($t.ToLower(), '[a-z][a-z\-]{3,}') | ForEach-Object { $_.Value })) {
                if ($stopSet.ContainsKey($word)) { continue }
                $freq[$word] = [int]$freq[$word] + 1
            }
        }
    }
    $topWords = @($freq.GetEnumerator() |
        Sort-Object @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key}} |
        Select-Object -First 2 | ForEach-Object { $_.Key })

    $auto = if ($topWords.Count) {
        (($topWords | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ' & ')
    } else { "Group $ci" }

    # A human override always wins over the keyword guess.
    $key = $g.Name
    $name = if ($overrides.ContainsKey($key)) { $overrides[$key] } else { $auto }

    $clusters += [pscustomobject]@{
        key       = $key
        name      = $name
        auto_name = $auto
        size      = $members.Count
        papers    = @($members | ForEach-Object { $people[$_].papers } | Measure-Object -Sum).Sum
        members   = $members
        top       = $members[0]
    }
}

# The categorical palette validates all-pairs for its first four slots only, and any two
# bubbles in a force layout can end up adjacent. So four named clusters get colour and
# the rest fold into a neutral "Other" - the documented alternative to inventing hues.
$MAX_COLORED = 4
$colorIndex = @{}
for ($i = 0; $i -lt $clusters.Count; $i++) {
    $colorIndex[$clusters[$i].key] = if ($i -lt $MAX_COLORED) { $i + 1 } else { 0 }
}

# --- Emit --------------------------------------------------------------------
$nodes = foreach ($p in ($people.Keys | Sort-Object { -$people[$_].papers }, { $_ })) {
    $n = $people[$p]
    [pscustomobject]@{
        id         = $p
        name       = $p
        papers     = $n.papers
        citations  = $n.citations
        first_year = $n.first_year
        last_year  = $n.last_year
        cluster    = $label[$p]
        color_slot = $colorIndex[$label[$p]]
        is_advisor = ($p -eq $advisor)
    }
}

$links = foreach ($k in ($edgeW.Keys | Sort-Object)) {
    $s, $t = $k -split '\|\|', 2
    [pscustomobject]@{ source = $s; target = $t; weight = $edgeW[$k] }
}

$net = [pscustomobject]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    center        = $cfg.name
    advisor       = $advisor
    node_count    = @($nodes).Count
    link_count    = @($links).Count
    min_shared    = $minShared
    total_people  = $totalPeople
    hidden_people = $totalPeople - @($nodes).Count
    max_colored   = $MAX_COLORED
    clusters      = @($clusters | Select-Object key, name, auto_name, size, papers, top,
                        @{Name='color_slot';Expression={$colorIndex[$_.key]}})
    nodes         = @($nodes)
    links         = @($links)
}

# A label override whose key no longer matches means the auto-generated name is
# showing on the page instead - warn rather than let a keyword guess ship silently.
foreach ($k in $overrides.Keys) {
    if ($clusters.key -notcontains $k) {
        Write-Warning "cluster_labels key '$k' matches no cluster - that group is showing its auto-generated name. Update profile.json."
    }
}

$outPath = Join-Path $DataDir 'network.json'
[System.IO.File]::WriteAllText($outPath, ($net | ConvertTo-Json -Depth 8), $Utf8NoBom)

Write-Host ""
Write-Host "Wrote $outPath" -ForegroundColor Green
Write-Host "  $($net.node_count) nodes, $($net.link_count) links, $(@($clusters).Count) clusters" -ForegroundColor Cyan
foreach ($c in $clusters) {
    $mark = if ($colorIndex[$c.key] -eq 0) { '(Other)' } else { "(slot $($colorIndex[$c.key]))" }
    Write-Host ("    {0,-28} {1,2} people, {2,2} papers  top: {3}  {4}" -f `
        $c.name, $c.size, $c.papers, $c.top, $mark) -ForegroundColor DarkGray
}
