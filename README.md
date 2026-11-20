# accounted-image

Builds the Siffrly test instance's Accounted image: upstream
[erp-mafia/accounted](https://github.com/erp-mafia/accounted) at a chosen ref,
with our extension list (`extensions.self-hosted.json`, adds `arcim-migration`).

Run: Actions → "Build Accounted image" → Run workflow → ref = upstream tag (e.g. `2026-11-19`).
Result: `ghcr.io/<owner>/accounted:<ref>` and `:<short sha>`.

The repo must be public (free 16 GB runners). The image contains no secrets:
all NEXT_PUBLIC_* values are placeholders filled in at container start.
