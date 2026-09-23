# REGTeches Media Stack

Developed by Ronald Goodchild for your pleasure.

A native Windows 11 install (no Docker) of Prowlarr, Sonarr, Radarr, Lidarr,
Readarr, Whisparr, SABnzbd, qBittorrent, Jellyfin and Seerr, wired together
and configured following TRaSH-Guides conventions, with a branded status
dashboard, Tailscale for remote access, and Prowlarr ready for you to add
your own indexers.

## Quick start

**Simplest — no flags, no thinking:** double-click **`start.bat`**. It
requests admin elevation itself (a UAC prompt), then runs the real `.ps1`
installer with default settings.

**GUI (recommended for first install):**

```powershell
powershell -ExecutionPolicy Bypass -File .\REGTechesMediaStack-Setup.ps1
```

Pick your install folder and which apps to include, click Install — it
relaunches the real installer elevated.

**Prefer double-clicking an .exe over running PowerShell scripts?** Run
`.\Build-Executables.ps1` once (installs the `ps2exe` module for you if
needed) to compile both scripts above into `REGTechesMediaStack-Setup.exe`
and `Install-REGTechesMediaStack.exe` — no execution-policy flag, no
right-click menu, and the installer gets a real UAC shield icon. The GUI
automatically prefers the compiled installer over the `.ps1` if both are
present.

**Command line (technician / unattended):**

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-REGTechesMediaStack.ps1
```

Run from an **elevated** PowerShell window. Useful flags:

| Flag | Effect |
|---|---|
| `-InstallRoot "D:\Media\Stack"` | Install somewhere other than `C:\REGTechesMediaStack` |
| `-SkipApps Whisparr,Readarr` | Don't install specific apps |
| `-OpenFirewallPorts` | Allow other devices on your LAN to reach the stack |
| `-SkipRecyclarr` | Skip the TRaSH-Guides quality-definition sync |
| `-AdminUsername "media"` | Login username set on every app (default `media`) |
| `-AdminPassword "..."` | Login password set on every app. Leave it out and a random one is generated on first run, printed at the end, stored in `config\state.json` and reused on re-runs |
| `-SkipTailscale` | Don't install Tailscale |
| `-TailscaleAuthKey "tskey-..."` | Join your tailnet unattended (from your Tailscale admin console → Settings → Keys) |
| `-SkipQBittorrent` | Don't install qBittorrent |
| `-UsenetHost "news.example.com"` | Your Usenet provider's server address |
| `-UsenetPort 563` | Server port (default 563, the standard SSL port) |
| `-UsenetUsername` / `-UsenetPassword` | Your Usenet account login |
| `-UsenetConnections 8` | Connection count (match what your plan allows) |
| `-UsenetNoSSL` | Use plaintext instead of SSL (not recommended) |
| `-SkipSeerr` | Don't install Seerr |

The script is **idempotent** — re-run it any time (e.g. after adding a drive)
and it only does the work that isn't already done. Changing `-AdminUsername`
/`-AdminPassword` on a re-run updates the login on every app *except*
Jellyfin, whose first-run wizard only runs once — change its password from
its own Dashboard → Users page instead.

**Login:** username `media` on every app. The password is generated randomly on
first run (unless you pass `-AdminPassword`), shown once at the end of the install
and stored in `config\state.json`. Re-runs reuse it. If you expose the stack beyond
your own LAN (`-OpenFirewallPorts`, Tailscale funnels, port forwards), keep it strong.

## What the installer actually does

1. Downloads the current Windows build of each app straight from its
   official GitHub releases (resolved dynamically, not pinned to a version
   that will go stale).
2. Wraps each one as a real Windows service using **NSSM**. This matters:
   the apps' own installers just add a "run at next login" shortcut, not a
   service — that means nothing starts until someone logs in, and dies the
   moment they log off. NSSM services run as SYSTEM, start at boot with no
   one logged in, and restart themselves automatically if a process crashes
   — on top of NSSM's own restart, Windows' own service-recovery is
   configured too (`sc.exe failure`), and `Start` is explicitly forced to
   Automatic so a service can't silently end up demand-start-only.
3. Waits for each app to come up, reads its auto-generated API key from
   `config.xml`, and uses the REST API to:
   - Add a root folder under `media\<type>`.
   - Register SABnzbd (Usenet) and qBittorrent (torrent) as download
     clients, both pointed at the matching category (`movies`, `tv`,
     `music`, `books`, `adult`) — each app auto-routes a release to
     whichever client matches its protocol.
   - Register itself inside **Prowlarr**, so any indexer you add to
     Prowlarr syncs out to every app automatically.
4. Installs SABnzbd — with its `sabnzbd.ini` **pre-seeded before its first
   launch** (language, a self-generated API key, login, `host_whitelist`),
   rather than letting SABnzbd generate its own on first boot. That's a
   real fix, not a nicety: without it, SABnzbd's own setup wizard greets
   whoever opens the web UI first, and the installer previously had to
   scrape the API key back out of a file SABnzbd might still be writing —
   a race that could quietly fail and leave categories/whitelist
   unconfigured. Pre-seeding removes both problems: no wizard, no race.
   `host_whitelist` in particular is what lets the *arr apps talk to it at
   all (a very common source of "unable to connect" errors if missed). If
   you pass `-UsenetHost`/`-UsenetUsername`/`-UsenetPassword`, that news
   server is wired straight into SABnzbd too — a free trial account is
   plenty to prove the whole chain (indexer → download → import → library)
   actually works end to end before you commit to a paid one.

   One thing this installer can't fix: SABnzbd's own installer hardcodes
   `C:\Program Files\SABnzbd` on 64-bit Windows (its `.onInit` script
   forcibly overwrites the install directory after the fact, ignoring any
   `/D=` override — confirmed by reading its actual NSIS source). There's no
   silent-install switch that gets around this, so SABnzbd's *program files*
   live in Program Files, not under InstallRoot — only its config/data
   (`appdata\SABnzbd`) does. Everything still gets found and wired up
   correctly; it's the one exception to "everything lives under one root."

   **SABnzbd, qBittorrent, and Jellyfin don't run as Windows services.**
   All three are registered as a **logon Scheduled Task** instead, in a
   real interactive desktop session. This wasn't the original design — it's
   the result of hitting real, confirmed bugs (or, for Jellyfin, an
   intentional design choice) in each:
   - **qBittorrent**'s GUI build crashes under NSSM (Windows Application
     Error events showed access violations inside qbittorrent.exe itself,
     with zero output — a Qt app failing to initialize with no real desktop
     to attach to, which Session 0, where Windows services run, doesn't
     provide).
   - **SABnzbd** auto-detects Session 0 and tries to hand off to the real
     Windows Service Control Manager (`StartServiceCtrlDispatcher`), which
     fails because NSSM — not SABnzbd — is the process actually registered
     with it; SABnzbd's *own* native service installer turned out to be
     broken too, needing a `pythonservice.exe` its official build doesn't
     ship.
   - **Jellyfin**'s Windows installer moved to an NSIS package
     (`jellyfin/jellyfin-server-windows` on GitHub — confirmed by reading
     its actual `.nsi` source). Its "Setup Type" page defaults to "Basic
     Install (Recommended)" — the checkbox is pre-checked in the dialog
     definition — and that choice is read by the page's own Leave callback,
     which still runs under `/S` even though the page itself is never shown.
     Basic Install sets its internal "install as a service" flag to `No`,
     and there is no command-line override anywhere in the installer to
     force it back to `Yes` silently. In other words: Jellyfin's own
     installer will never register a `JellyfinServer` Windows service in an
     unattended install — that's Jellyfin's own recommended, intended mode
     now, not a bug we're working around.

   All three were confirmed to run perfectly normally as a plain process in
   a real desktop session, so all three run as a task triggered `At log on`
   for whichever account installs the stack. Trade-off: they start when you
   log in, not at boot, unlike the *arr apps and Prowlarr.
   **Trade-off:** they start when you log in, not at boot, unlike every
   other app here — worth knowing if you're setting this up on a box meant
   to run fully headless. Both restart automatically if they crash
   (`RestartCount`/`RestartInterval` on the task), same as the services.
5. Installs **qBittorrent** (skip with `-SkipQBittorrent`) as a torrent client —
   SABnzbd only speaks Usenet, so if you add torrent indexers you need one. Same story as SABnzbd:
   its WebUI login is pre-seeded before first launch (qBittorrent hashes
   its WebUI password as PBKDF2-SHA512, which the installer computes
   directly, into the exact nested path its `--profile` flag actually
   uses — `<profile>\qBittorrent\config\qBittorrent.ini`, one folder
   deeper than the flag name suggests, confirmed by reading its source)
   instead of scraping a temporary password out of a log file. Registered
   into every app as a second download client alongside SABnzbd, and into
   Prowlarr the same way.
6. Installs **Recyclarr** and runs a TRaSH-Guides quality-definition sync
   for Sonarr and Radarr. Recyclarr is the tool TRaSH-Guides itself now
   recommends for staying in sync — see the note below on going further.
6. Installs Jellyfin silently (`/S /D=<path>` — NSIS's real silent switches;
   see the Scheduled Task note above for why it's not a service). `/D=` only
   redirects the program-files folder and isn't guaranteed to be honored
   (can be skipped if the installer self-elevates via UAC) — the installer
   double-checks where `jellyfin.exe` actually landed afterward and falls
   back to the default Program Files location if needed, logging a warning
   either way. The data folder is entirely ours to control since we launch
   `jellyfin.exe` ourselves via the Scheduled Task (`--datadir`), so that one
   does land under `<InstallRoot>\appdata\Jellyfin` like every other app.
7. Drives Jellyfin's first-run setup API directly: creates the admin
   account with the same login as every other app, completes the wizard,
   then authenticates and adds all five libraries (Movies, TV, Music,
   Books, Adult) pointing at `media\<type>` — no browser click-through
   needed. If that automation fails (Jellyfin's setup API isn't guaranteed
   stable release to release), the install log says so and you finish the
   wizard by hand instead, at http://localhost:8096.
8. Leaves **Prowlarr with no indexers**, on purpose. Which indexers you use —
   Usenet providers, private trackers, public trackers — is your choice and is
   subject to their terms and your local laws. Add them at
   http://localhost:9696 → Indexers and they sync to every other app automatically.
9. Installs **Tailscale** so the stack is reachable from your other
   devices without opening any port to the raw internet. Installing it is
   fully automatable; *joining your tailnet* isn't — that's your account,
   not something this script can do for you. Give it `-TailscaleAuthKey`
   (from your Tailscale admin console) for a silent join, or it launches
   `tailscale up` for you to approve once in a browser. Either way, the
   stack's ports are opened on the Tailscale interface only
   (100.64.0.0/10) — independent of, and safer than, `-OpenFirewallPorts`.
10. Installs **Seerr** (https://docs.seerr.dev), the actively-maintained
    successor to Jellyseerr/Overseerr — lets people request movies/TV
    through a proper UI instead of poking Sonarr/Radarr directly. It ships
    no native Windows installer or prebuilt binary at all (only Docker
    images or a from-source build — confirmed directly against its GitHub
    releases), so this installer builds it from source instead: installs
    Node.js 22 if missing, fetches Seerr's latest release, and runs its
    documented build (`pnpm install` + `pnpm build` via Corepack, which
    picks up the exact pnpm version Seerr itself pins). Unlike
    qBittorrent/SABnzbd/Jellyfin, it's a plain headless Node server, so it
    runs as a real NSSM service like the `*arr` apps — no logon-task
    workaround needed. Comes up at **http://localhost:5055**, and its
    first-run setup is driven automatically the same way Jellyfin's is:
    signs in with your admin account to create the initial Jellyfin
    connection, then registers Sonarr and Radarr using the API keys and
    root folders already captured earlier in this same run. If that
    automation fails (Seerr's setup API isn't guaranteed stable release to
    release, same caveat as Jellyfin's), the install log says so and you
    finish it by hand instead — see below.
11. Builds a branded dashboard at **http://localhost:8090**, running as its
    own service (`REGTMS-Dashboard`) so it's always up, not just while a
    terminal is open. It's a real status page, not just links:
    - Every service card is a live tile: a status dot, a one-line stat
      pulled from that app's own API (Sonarr/Radarr/Lidarr/Readarr/Whisparr
      show queue + missing counts, Prowlarr shows enabled/total indexers,
      SABnzbd and qBittorrent show current speed and active items, Jellyfin
      shows active streams), and the *whole card* is a real link to that
      app — not just a small "Open" text. Polled every 15-20s.
    - **Storage**: every fixed drive on the box, a used/total gauge
      color-coded green/amber/red at 75%/90% thresholds.
    - **Recent Activity**: the last dozen grabs/imports/downloads across
      every app (Sonarr/Radarr/Lidarr/Readarr/Whisparr history, SABnzbd's
      history, qBittorrent's completed torrents), merged and sorted by
      time — so you can see at a glance that things are actually flowing,
      not just that the services are technically running.
12. Adds a **"REGTeches Media Stack" folder to Edge's favorites bar**
    (one click each to every app — no more remembering ports) via
    Microsoft's own `ManagedFavorites` policy, and a **Desktop shortcut**
    straight to the Dashboard. The favorites folder is driven by a
    registry policy, not by editing Edge's own bookmarks file, so it
    can't touch or conflict with your personal bookmarks — restart Edge
    if it's already open to see it show up.
13. Opens a **Getting Started guide** (http://localhost:8090/getting-started)
    in your browser the moment everything finishes — VPN provider options
    for qBittorrent, Usenet provider options for SABnzbd, a walkthrough of
    what changes if you want to put Movies/TV/Adult on a different drive or
    a OneDrive folder, how to reach Jellyfin from a TV/phone/tablet
    instead of just this PC (it detects this machine's actual LAN IP and
    prints a real clickable address, plus whether your firewall/Tailscale
    are already set up for it or still need a step), a linked directory of
    every app with its own official docs, and ongoing-maintenance advice
    (what to unmonitor/archive/delete, download-client housekeeping, a
    weekly/monthly checklist). It only opens automatically this once; find
    it again any time from the **Getting Started Guide** link in the
    Dashboard's own header.

## Steps you still have to do yourself (on purpose)

- **Only if the install log warned about it** — Seerr's first-run setup
  (sign in with your Jellyfin admin account, then add Sonarr/Radarr from
  its own Settings → Services page) is normally done for you automatically.
  If that automation failed, finish it by hand at http://localhost:5055
  (API keys are already sitting in `config\state.json` if you want to copy
  them rather than re-typing).
- **Add your own indexers in Prowlarr** (http://localhost:9696 → Indexers). None
  are pre-installed; once added they sync to every other app automatically.
- **Add a Usenet (Newznab) indexer — there's no public/free option here,
  and that's normal.** Unlike torrents, Usenet doesn't have a real "public
  indexer catalog" to pull from automatically: Newznab is a generic
  standardized API, not a per-site scraper, so Prowlarr has nothing built
  in that could be pre-added (checked directly
  against Prowlarr's own indexer-definitions repo — all 548 entries are
  torrent sites, zero are Usenet). Nearly every decent Usenet indexer
  (NZBgeek, DrunkenSlug, NZBFinder, NZBPlanet, etc.) is paid or invite-only
  because indexing the full Usenet feed isn't something a free ad-supported
  site can sustain — the "free" NZB search sites that do exist (Binsearch,
  NZBIndex, NZBKing) aren't real Newznab-API providers, so they wouldn't
  actually work here even if wired in. This is two separate things that
  are easy to conflate:
  - **Usenet server/provider** — where you *download* the raw data from
    (Newshosting, Eweka, Frugal Usenet, etc. — the Getting Started guide
    links a handful of options). This is what
    `-UsenetHost`/`-UsenetUsername`/`-UsenetPassword` already wires in for
    you, and many providers have free trials — see the note above.
  - **Usenet indexer** — where you *search* for what's available. This is
    the piece you add by hand:
    1. Sign up with an indexer (a free trial tier is enough to prove the
       chain works, same as with the Usenet server).
    2. In Prowlarr (http://localhost:9696) → Indexers → Add Indexer →
       search for the indexer's name (most ship a real Prowlarr
       definition once you have an account) or pick generic **Newznab**
       and paste in the URL + API key they give you.
    3. It syncs to every *arr app automatically from there, same as any
       other indexer.
- **Pick a Usenet provider** and re-run with `-UsenetHost`/`-UsenetUsername`/
  `-UsenetPassword` — see the note above on free trials being enough to
  prove the setup works before paying for one.
- **Consider a VPN for the torrent side.** qBittorrent talking to public
  torrent trackers is the one piece of this stack that benefits from not
  showing your real IP to the swarm — Usenet and Tailscale don't have that
  exposure. The Getting Started guide (opens automatically after install,
  or from the Dashboard's header any time) links a handful of well-known
  options — NordVPN, Surfshark, ExpressVPN, Private Internet Access — and
  walks through binding qBittorrent to the VPN's own network adapter under
  **Options → Advanced → Network Interface**, so torrent traffic simply
  stops if the VPN ever drops instead of silently falling back to your
  real IP. Compare current pricing/port-forwarding support yourself before
  picking one.
- **Deeper TRaSH-Guides profiles/custom formats**: the installer syncs
  quality *definitions* automatically. For the full curated custom-format
  list (HDR handling, streaming-service tagging, repack scoring, etc.),
  edit `tools\recyclarr\recyclarr.yml` — see https://recyclarr.dev — and
  re-run `tools\recyclarr\recyclarr.exe sync`. That config changes often
  enough upstream that hand-baking it into this installer would go stale;
  Recyclarr is the tool actually built to track it.

## Day-to-day operation

| Task | How |
|---|---|
| Open any app | Dashboard at http://localhost:8090, or the tray app |
| Re-read the Getting Started guide | http://localhost:8090/getting-started, or the link in the Dashboard's header |
| Check status | Dashboard dot color, or `Get-Service REGTMS-*` |
| Restart everything | Tray app → "Restart all services" |
| Update all `*arr` apps | `Update-REGTechesMediaStack.ps1` (elevated) |
| Uninstall services (keep data) | `Uninstall-REGTechesMediaStack.ps1` (elevated) |
| Uninstall + delete everything | `Uninstall-REGTechesMediaStack.ps1 -PurgeData -RemoveJellyfin -RemoveSABnzbd` (the latter two live outside InstallRoot, so `-PurgeData` alone won't remove them — it warns if you forget) |

## Tray app

A small always-running tray icon with quick links to every app and a
"restart all services" action.

```powershell
cd tray
dotnet build -c Release
```

The exe lands in `tray\bin\Release\net9.0-windows\REGTechesMediaStackTray.exe`.
Drop a shortcut to it in `shell:startup` to have it launch at login.
(First build needs `nuget.org` registered as a package source — if `dotnet
build` reports `NU1100`, run `dotnet nuget add source
https://api.nuget.org/v3/index.json -n nuget.org` once.)

## Ports

| App | Port |
|---|---|
| Dashboard | 8090 |
| Prowlarr | 9696 |
| Sonarr | 8989 |
| Radarr | 7878 |
| Lidarr | 8686 |
| Readarr | 8787 |
| Whisparr | 6969 |
| SABnzbd | 8080 |
| qBittorrent | 8181 |
| Jellyfin | 8096 |
| Seerr | 5055 |

## Folder layout

```
<InstallRoot>\
  apps\<Name>\        the extracted app binaries
  appdata\<Name>\     each app's config.xml / database (its "AppData")
  tools\               nssm.exe, recyclarr\
  media\{movies,tv,music,books,adult}\
  downloads\{incomplete, complete\<category>}\
  dashboard\           index.html + the persistent Dashboard-Server.ps1
  logs\                install.log + one log pair per service
  config\state.json    resolved versions, API keys, base URLs
```

**`config\state.json` is sensitive** — it holds every app's API key plus
the admin username/password in plaintext (the dashboard needs them to query
qBittorrent's session-based API). Treat it like a credentials file: don't
commit it, don't share it, and NTFS permissions on that machine are what's
actually protecting it. Not different in kind from what was already true
before this file existed — the API keys were always sitting in each app's
own `config.xml` under `appdata\` — just now also gathered in one place.

## Known gaps / what's not built yet

- **Code-signed installer**: needs a code-signing certificate purchased in
  your name — once you have one, `signtool sign` is a one-line addition.
- **Public download site / auto-update daemon**: needs a domain + hosting
  to publish version manifests to. `Update-REGTechesMediaStack.ps1` covers
  the "check and update" logic already; wiring it to a public feed and a
  background scheduled task is the remaining piece once you've picked where
  to host it.

## A note on Readarr

Readarr's upstream project is archived — there's no "stable" release
anymore, only a pre-release "develop" build, which is what this installer
pulls. It works, but expect it to be the least polished piece of the stack.

## Security notes

- `config\state.json` holds every app's API key **and the login password in plain text**. Anyone who can
  read that file controls the stack - keep the install folder private.
- The apps listen on localhost by default. `-OpenFirewallPorts` exposes them to your LAN; use a strong
  password and never forward these ports to the internet - use Tailscale instead.
- Report security problems privately through the repository's Security tab.

## Legal

You're responsible for what you point these apps at and for complying with
your indexers' terms and your local laws. This stack automates library
organization; it doesn't include or access any content itself.
