# Game Portfolio — Phat Hy

Personal portfolio site for **Phat Hy** (Hồ Minh Phát) — Unity game developer working on
gameplay systems and enemy AI.

Static site: plain HTML, CSS and JavaScript. No build step, no framework, no external
font or asset requests. Deployed to Azure Blob Storage static website hosting.

## Contents

| Path | Purpose |
|---|---|
| `index.html` | The whole site (single page) |
| `assets/styles.css` | All styling |
| `assets/main.js` | Three small progressive enhancements; page works without it |
| `deploy-azure.ps1` | Creates the storage account and publishes the site |

## Projects featured

- **81 Days and Nights** — historical single-player FPS set during the 1972 Battle of Quang Tri,
  developed by AnomalyVN Studio. My work: enemy AI and the gameplay systems around it.
  [Steam](https://store.steampowered.com/app/5042430/81_Days_And_Nights/)
- **SuikaClone** — browser physics puzzle built around the merge mechanic, implemented solo.
  [itch.io](https://hypergs.itch.io/suikaclone)

## Local preview

Open `index.html` directly, or serve it:

```powershell
# any static server works
python -m http.server 8000
```

Then visit <http://localhost:8000>.

## Deploy

```powershell
pwsh ./deploy-azure.ps1
```

The script is idempotent: it reuses the resource group and storage account if they already
exist, enables static website hosting, uploads every file, and prints the public URL.

## Notes

- Placeholders written as `__EMAIL__` must be replaced before publishing — the deploy script
  refuses to run while any `__TOKEN__` placeholder is still present.
- The Steam key art is loaded from Valve's CDN rather than copied into this repo.
