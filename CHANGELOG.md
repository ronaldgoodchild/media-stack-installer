# Changelog

Reconstructed from the original development history (September 2026).

## [Unreleased]
- **Public release changes**
  - Prowlarr is installed with **no indexers**; the automatic public-indexer feature (`-SkipPublicIndexers`, `-AllPublicIndexers`, `-PublicIndexerNames`) was removed. Choosing indexers is up to you.
  - **No default password.** A random 20-character password is generated on first run, shown at the end and stored in `config\state.json`; re-runs reuse it. `-AdminPassword` still overrides it.
  - The setup GUI leaves the password blank by default (blank = generated).
  - Lab-specific paths and addresses removed from comments and docs; MIT license, security policy and CI added.

## [1.x] - 2026-09-11 to 2026-09-19
- Native Windows install (no Docker) of Prowlarr, Sonarr, Radarr, Lidarr, Readarr, Whisparr, SABnzbd, qBittorrent, Jellyfin and Seerr as real Windows services (NSSM)
- TRaSH-Guides quality definitions via Recyclarr, Jellyfin first-run automation, Seerr wiring, Tailscale
- Branded status dashboard with live stats, tray app, setup GUI, update and uninstall scripts, getting-started guide
