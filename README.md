# LexCockpit — your native macOS cockpit

A SwiftUI Mac app with two dashboards:

- **Projects** — your editorial pipeline (draft / scheduled / published), from your repo.
- **Topics** — all the regulatory data (Tracker, Pipeline, Trilogue, Enforcement),
  pulled live from the *same* public feeds the website uses, so it's always in sync.

No third-party packages. No compliance-of-record, no advice — a read-only cockpit
(watch + navigate), which keeps it on the safe side of the liability line.

---

## Run it (≈5 minutes)

You need a Mac with **Xcode 15+** (macOS 13 Ventura or newer).

1. **New project:** Xcode → *File ▸ New ▸ Project… ▸ macOS ▸ App*.
   - Product Name: `LexCockpit`
   - Interface: **SwiftUI**, Language: **Swift**
   - Uncheck Core Data / Tests. Save it anywhere.
2. **Add the source:** in Finder, open this `LexCockpit/LexCockpit/` folder. Select
   `Models.swift`, `Store.swift`, `Theme.swift`, `LexCockpitApp.swift`, `Views.swift`
   and drag them into the Xcode project navigator (into the app group).
   - When prompted: **Copy items if needed** ✔, add to target **LexCockpit** ✔.
   - Xcode created its own `ContentView.swift` and `LexCockpitApp.swift` — delete the
     two it generated (move to Trash) and keep the ones you dragged in. (Both define
     `LexCockpitApp` / `ContentView`; you want exactly one of each.)
3. **Add the sample data:** drag `Resources/projects.json` into the project too
   (Copy items ✔, target ✔). This makes the Projects tab work on first launch.
4. **Allow outgoing network:** select the project ▸ target **LexCockpit** ▸
   *Signing & Capabilities* ▸ **+ Capability ▸ App Sandbox**, then tick
   **Outgoing Connections (Client)**. (Needed to fetch the feeds.)
5. Press **⌘R**. The window opens on the Dashboard and loads the live feeds.

The toolbar **⟳** button refreshes. If a feed can't load you'll see a banner (and the
rest still renders).

---

## Wire in your real projects

The Projects tab starts from a bundled sample. To see your actual pipeline:

```bash
# in your lexdigestglobal repo (dependency-free):
node /path/to/LexCockpit/scripts/build-projects.js > ~/projects.json
```

Then in the app: **Projects ▸ Open projects.json…** and pick `~/projects.json`.
(You can also just replace `Resources/projects.json` in the project and rebuild.)

---

## Where the data comes from

`Store.swift` fetches from `https://lexdigestglobal.com/data/`:
`tracker.json`, `pipeline.json`, `trilogue.json`, `enforcement.json`.
To develop against local data, run `python3 -m http.server` in the website repo and
change `base` in `Store.swift` to `http://localhost:8000/data/` (then also tick
*Allow Arbitrary Loads* under App Transport Security, since that's plain http).

## Good next steps (v2)

- **Native notifications** when a watched file changes (`UNUserNotificationCenter`) —
  diff against `tracker-changelog.json`; this is your Pro "alerts" feature, prototyped.
- **Watchlist**: star regulations, filter every view to your set (persist with
  `@AppStorage`).
- **Menu-bar extra** (`MenuBarExtra`) so the "what moved today" count is always visible.
- **Read the repo directly** for Projects via a security-scoped folder bookmark,
  instead of the generated projects.json.
