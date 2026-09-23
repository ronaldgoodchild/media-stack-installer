# Roadmap / ideas

Comment on (or open) an issue first so we don't duplicate work.

## Good first issues
- [ ] Add screenshots of the dashboard and the setup GUI to the README
- [ ] Split the 3,600-line `Install-REGTechesMediaStack.ps1` into a module (one function per app)
- [ ] Add Pester tests for the password generation, state handling and parameter validation
- [ ] Add a `-WhatIf` / dry-run mode that lists what would be installed without doing it
- [ ] Publish `Build-Executables.ps1` output as a signed `.exe` on each GitHub Release

## Security
- [ ] Stop storing the login password in plain text in `state.json` (use DPAPI or Windows Credential Manager)
- [ ] Bind services to localhost by default and add a reverse-proxy + HTTPS guide

## Features
- [ ] Linux/Docker edition (a tested compose file with no default credentials)
- [ ] Optional VPN-bound qBittorrent profile
- [ ] Backup and restore of app configuration
- [ ] winget / Chocolatey packaging
