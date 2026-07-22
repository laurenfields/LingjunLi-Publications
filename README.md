# Lingjun Li — Publications

A self-contained web page of Prof. Lingjun Li's publications, with citation-growth
charts and an interactive collaborator network. Built from [OpenAlex](https://openalex.org),
cross-referenced against her CV.

**Prof. Li has not reviewed this page.** It was assembled by Lauren Fields as a
starting point. The repository is deliberately standalone so it can be handed over
and maintained by whoever owns it.

## Quick start

```powershell
.\scripts\Update-All.ps1          # refresh data and rebuild index.html
.\scripts\Update-All.ps1 -Publish # ...and commit + push
```

## The name-collision problem — read this first

OpenAlex has **merged at least four different researchers named Lingjun Li into one
author entity** and attached this ORCID to all of them. Querying by ORCID returns
657 works spanning atmospheric chemistry in Beijing, prenatal epigenetics at Soochow
University, periodontology, and — mixed in — her actual mass spectrometry work.

Neither obvious fallback rescues this:

- **Filtering by OpenAlex author ID doesn't help.** There is only one substantive
  author entity (`A5100746152`) and it *is* the merged one. It lists UW–Madison as its
  affiliation while containing papers from the Chinese Academy of Sciences.
- **Her own ORCID record lists only 6 works**, so it cannot arbitrate.

So `Crossref-CV.ps1` uses **her CV as the authority**, combining four signals:

| Signal | What it establishes |
|---|---|
| Title appears in the CV | Decisive — the paper is hers |
| DOI appears in the CV | Decisive |
| Her authorship lists Wisconsin or Illinois | Decisive — no other Lingjun Li is at either. Illinois covers her PhD, 1995–2000 |
| Co-authors overlap her confirmed work | Corroborating only — one or two shared names across a large author list is coincidence among common names |

Current outcome: **475 kept, 140 excluded**, 0 unresolved.

Every exclusion is written to `config/exclusions.generated.json` with its reason. The
six cases the heuristics could not settle were decided by hand and recorded in
`config/review-decisions.json`; those decisions override the heuristics on every
re-run, so nothing is re-litigated.

The clustering is the sanity check that this worked. Before filtering, the collaborator
network produced groups called "Offspring & Prenatal", "China & City" and "Hepatitis &
Virus". After filtering, every group is mass spectrometry.

## What's here

| Path | What it is |
|---|---|
| `index.html` | The built page. Self-contained — no CDN, no fonts, no API calls at view time. ~1.1 MB, because it embeds all 475 papers. |
| `LLi_CV.pdf` | The CV used as the source of truth. Replace it with a newer one and re-run. |
| `config/profile.json` | ORCID, display details, thresholds. **Edit this**, not the scripts. |
| `config/review-decisions.json` | Human verdicts on ambiguous works. Hand-maintained. |
| `config/exclusions.generated.json` | Machine-generated exclusion list. Do not hand-edit. |
| `data/*.json` | Generated: publications, summary, collaborator network. |
| `data/review-queue.csv` | Anything still unresolved after a cross-reference run. Currently empty. |
| `scripts/Crossref-CV.ps1` | Cross-references OpenAlex against the CV and writes the exclusion list. |
| `scripts/Fetch-Publications.ps1` | Pulls from OpenAlex, applies exclusions, writes the data files. |
| `scripts/Build-Network.ps1` | Derives the collaborator network and finds research clusters. |
| `scripts/Build-Site.ps1` | Injects data into the template, writes `index.html`. |
| `scripts/Update-All.ps1` | Fetch → network → build, plus optional publish. |

## Adding a new paper, or fixing a wrong one

New papers appear automatically if they pass the cross-reference. If one is wrong:

1. Find its OpenAlex ID in `data/crossref-all.csv`
2. Add it to `config/review-decisions.json` with `keep` or `drop` and a note
3. Re-run `.\scripts\Crossref-CV.ps1` then `.\scripts\Update-All.ps1`

When the CV is updated, drop in the new PDF and re-run — more papers will match
directly and fewer will need judgement.

## Notes on the page

- **Senior authorship is the headline metric**, not first authorship: she is last
  author on her lab's output (332 of 475). Set `kpi_authorship` to `first` in the
  config for an early-career researcher.
- **The collaborator network shows 117 of 1,034 co-authors** — those with 5+ shared
  papers. A force layout is O(n²) per tick and unreadable past a few hundred nodes.
  The cutoff is stated on the page and set by `network_min_shared`.
- **Only the four largest clusters get colour.** The categorical palette validates
  all-pairs at four slots, and any two bubbles can be adjacent in a force layout;
  a fifth hue would be indistinguishable under common colour-vision deficiencies.
- **Citation counts are OpenAlex's** and read lower than Google Scholar, which indexes
  more sources. Her CV quotes 15,227 citations and h-index 64 from Google Scholar at
  the time it was written; OpenAlex currently gives 17,270 and 67.
- **Co-first authorships are not shown.** Shared first authorship is declared only in
  the paper itself and appears in no bibliographic database. It would have to be
  entered by hand in `co_first_author_works`.

## Requirements

Windows PowerShell 5.1 and git. **`pdftotext` (poppler) is required** by
`Crossref-CV.ps1` to read the CV; the other scripts don't need it. No Python, no Node.

OpenAlex needs no API key; setting a contact email gets you the faster pool:

```powershell
$env:OPENALEX_EMAIL = "you@wisc.edu"
```

## Relationship to the sibling project

The scripts and template here are identical to those in Lauren Fields'
[MyPublications](https://github.com/laurenfields/MyPublications); only the config
differs. `Crossref-CV.ps1` is the one addition, needed because her ORCID is merged.
Improvements to either should be copied to the other.
