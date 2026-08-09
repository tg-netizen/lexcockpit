# LexCockpit, rethought

Not a feature list. A different spine, and what follows from it.

---

## The diagnosis

The workspace tabs are called **Content · Calendar · CMS · Deploys · Repo**.
Four of those five name a *substrate* — where the bytes happen to live.
Nobody has ever thought "I need the Repo tab." They think "did that go
live?", and the answer is spread across three tabs and a sheet.

Alongside them sit Radar, Tracker, Trilogue, Enforcement, Pipeline and
Analytics — the website's sections, mirrored. So the app runs two
organising principles at once, technical layers and published desks, and
neither is the thing the user is actually doing.

37 screens, 11 of them sheets. That is not too much software. It is the
right amount of software with no spine through it.

---

## The spine

A one-person newsroom has one loop, and it has six moves:

```
  notice → judge → write → verify → publish → confirm
```

Everything in this app belongs to one of those. Nothing in this app is
named after one of them.

That is the whole redesign. Two consequences follow, and they are large.

### Consequence 1 — objects, not places

An article has a life: drafted, sources attached, scheduled, committed,
built, deployed, live, checked. Today that history is scattered across
Content, Calendar, Deploys and Repo, and the user reassembles it in their
head.

It should be **one timeline on the object**. Open an article, and its
history is the article — including the deploy that shipped it and the
commit that carried it. "Deploys" stops being a destination and becomes a
fact about a thing.

The same applies everywhere. A regulation has a history. A sanctions
regime has a history. A feed has a history — and *that* is where the
health ledger belongs, not in a settings panel.

### Consequence 2 — technical depth becomes an inspector, not a floor

The depth is the product. A cockpit that hides the machinery is a toy.
But depth as a *destination* costs a navigation decision every time;
depth as an *inspector* costs a keystroke.

One panel, one shortcut, always the same shape: **what is this, where did
it come from, when was that true, what happened to it since.** Press it on
an article, get sources and deploys. Press it on a number, get the
document and the retrieval date. Press it on a feed, get the last check
and the last failure.

That single idea replaces the CMS tab, the Deploys tab, the Repo tab and
the diagnostics sheet with one thing that is better than all four,
because it is *contextual* — it already knows what you are looking at.

---

## The shape that falls out

### One home: **the Desk**

Not tiles. Tiles are a monitoring idiom, and you are not monitoring, you
are working. The Desk is a prioritised worklist, in the order the day
actually has:

```
  ┌ TODAY ─────────────────────────────────────────────────┐
  │  3 sources agree on the Council's new listing package   │
  │  → open as a brief                        [ 3 sources ] │
  ├─────────────────────────────────────────────────────────┤
  │  CBAM definitive period starts in 14 days               │
  │  → nothing written yet                    [ deadline  ] │
  ├─────────────────────────────────────────────────────────┤
  │  "The Death of FCAS" is a draft and has been for 12 d   │
  │  → 1000 words, ready                      [ stalled   ] │
  └─────────────────────────────────────────────────────────┘

  QUIET
    Feeds all checked within 8 h · last deploy green · no conflicts
```

Two sections and one rule: **anything that is fine gets one line at the
bottom.** The nine stat tiles today spend the most valuable space in the
app telling you numbers that are almost always the same. A number that
does not change does not deserve a tile; it deserves a word in a sentence
that says everything is fine.

The list is generated, not curated: clustered waiting-list items,
approaching deadlines with no coverage, drafts that have stopped moving,
anything the site's own `trust-audit.js` is failing on. Each row states
what it is and what it costs to act.

### Four places, not six tabs

| | what it is | what it replaces |
| --- | --- | --- |
| **Desk** | today, prioritised | Overview, Hub, Radar |
| **Library** | everything ever written, filterable | Content, Calendar |
| **Sources** | the feeds, the acts, the register — and their health | Tracker, Trilogue, Enforcement, Pipeline |
| **Editor** | full takeover, already built | unchanged |

CMS, Deploys and Repo disappear as places and reappear inside the
inspector, where they were always answers rather than destinations.

Four is not fewer for its own sake. Four is how many nouns the work has.

---

## Making it beautiful

The app currently looks like an admin panel for a publication. It should
look like the publication.

**Borrow the site's own identity.** Cream `#F5F1EA`, navy `#1F2A44`, gold
`#C8B98F`, a serif for anything that is a headline, a monospace for
anything that is a figure. The editor already lives on a white page in a
grey surround, which is exactly right — the rest of the app has not
caught up.

**One type scale, brutally applied.** Today the app has cards inside
cards inside tabs. Cards are what you reach for when the hierarchy is
unclear; a real hierarchy needs fewer boxes, not more. Rule of thumb: if
a card contains exactly one thing, it should not be a card.

**Density with air.** A one-person newsroom wants a lot on screen. That
is a reason for a tight grid and a tall list, not for cramming. The
sanctions dossiers on the website get this right and the app does not.

**Motion only where it means something.** A row that arrives should
arrive. Nothing else should move.

**Every figure carries its provenance, visibly.** The defence pages on
the site already do this — "read 5 Aug 2026" under every claim. In the
app it becomes a hairline of grey text under any number that came from
somewhere: `queue · 34 · checked 4 min ago`. That single habit is what
makes depth feel like confidence instead of clutter, and it is the exact
fix for the audit's P0.

---

## Three moves that are quietly structural

### The state machine, everywhere
`.never · .loading · .loaded(at:count:) · .failed(reason)` on every panel
that fetches. Not a refactor for tidiness: it is the difference between
"the waiting list is empty" and "I have not asked yet", and this morning
that distinction was worth an hour. Once every panel has it, the Desk's
QUIET line can be *true* rather than assumed.

### Command-first
⌘K exists. Make it the fastest path to everything, and the chrome can
shrink — a sidebar earns its width only for things you cannot name. Type
"fcas", get the article. Type "cbam", get the regulation, its deadline and
its coverage. Type "deploy", get the last one.

### The contradiction detector
The app sits between two sources of truth — the site's data files and
Supabase — and it is the only thing that sees both. That is a position
nothing else in the stack has.

Use it. When `pipeline_runs.items_queued` says 34 and the queue returns
0, that is not an empty list, it is an alarm. When the compliance tool
says 250 employees and the profile page says 1,000, that is a story about
the site, surfaced in the app that edits it. When a feed's last check is
older than the cadence the homepage advertises, the app should say so
before a reader notices.

**That is the feature nothing else can have**, and it is three
comparisons over data both halves already hold.

---

## Order

1. State machine + provenance line — small, and it makes everything else
   honest
2. The Desk replacing the tile wall
3. The inspector, absorbing CMS/Deploys/Repo/Diagnostics
4. Four places instead of six tabs
5. The contradiction detector
6. Visual pass: type scale, fewer cards, the site's palette

One through three are the redesign. Four through six are what makes it
look like it was designed rather than assembled.
