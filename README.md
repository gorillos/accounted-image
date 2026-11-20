# accounted-image

Builds the Siffrly test instance's Accounted image: upstream
[erp-mafia/accounted](https://github.com/erp-mafia/accounted) at a chosen ref,
with our extension list (`extensions.self-hosted.json`, adds `arcim-migration`).

Run: Actions → "Build Accounted image" → Run workflow → ref = upstream tag (e.g. `2026-11-19`).
Result: `ghcr.io/<owner>/accounted:<ref>` and `:<short sha>`.

**Upgrading the instance:** see [UPGRADING.md](UPGRADING.md) (build, dry run,
migrations, switch, verify, rollback) and the helper scripts in `scripts/`.

The repo must be public (free 16 GB runners). The image contains no secrets:
all NEXT_PUBLIC_* values are placeholders filled in at container start.
