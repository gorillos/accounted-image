# Upgrading the Accounted test instance

How to move the self-hosted Accounted test instance to a newer upstream
version. First done this way on 2026-11-20 (b0b481b9d → b2ec8b68e, 515
migrations, about 2 minutes of downtime).

Everything in this guide runs **on the server as root**, except step 2, which
runs in GitHub Actions in this repository.

## How the instance is put together

| What | Where |
|---|---|
| Accounted checkout (detached at the running commit) | `/opt/accounted` |
| Local, non-upstream files in that checkout | `compose.local.yml`, `Caddyfile.local`, `docker/extensions.self-hosted.json` (our list) |
| Secrets and the image tag | `/opt/accounted/.env` (`IMAGE_TAG=<short sha>`) |
| App image | `ghcr.io/gorillos/accounted:<short sha>`, built by this repo |
| Cron sidecar | built locally from `docker/cron.Dockerfile`; reads `docker/crontab.self-hosted` from the checkout |
| Supabase (Postgres container `supabase-db`) | `/opt/supabase` |
| Provisioner (depends on Accounted's DB functions) | `/opt/provision`, see its README, "Upgrade routine" |
| Encrypted offsite backup | `/opt/provision/scripts/backup-accounted.sh` (also runs nightly from cron) |
| Upgrade scripts | `scripts/` in this repo |

**Why the image is built here:** the Next.js/Turbopack build needs more than
the server's 7.7 GB of RAM and gets OOM-killed, on every release, not just big
ones. Upstream's prebuilt `ghcr.io/erp-mafia/gnubok` image lacks
`arcim-migration` (Systemmigration: import from Fortnox, Bokio, Visma, Briox),
which we keep enabled. This repo must stay **public**: only public repos get
the free 16 GB runners.

**Migrations have no tracking table.** Upstream ships plain SQL files that are
not idempotent. We apply exactly the files added since the commit we run now,
in filename order, once. `scripts/new-migrations.sh` works that list out.

## 1. Is there something new?

```bash
cd /opt/accounted
git fetch --tags origin
git rev-parse --short HEAD                  # what we run
git log --oneline HEAD..origin/main | head  # what is new
```

Upstream publishes releases as date tags (for example `2026-11-19`) with notes
on GitHub. `main` often has fixes on top of the tag. Prefer the **commit sha of
`origin/main`** unless there is a reason to stay on the tag, and use that same
sha in every step below.

```bash
NEW=$(git rev-parse origin/main); OLD=$(git rev-parse HEAD); echo "$OLD -> $NEW"
```

Run the remaining steps in the same shell: they reuse `$OLD`, `$NEW`,
`$SHORT`, `$U` and `$TS`.

## 2. Build the image (GitHub Actions)

1. Repo → Actions → "Build Accounted image" → Run workflow.
2. `ref` = the full `$NEW` sha (a tag or branch also works).
3. Wait about 7 minutes. The image is pushed as `ghcr.io/gorillos/accounted:<short sha>` and `:<ref>`.

If upstream changed the extension list, compare
`docker/extensions.self-hosted.json` upstream with `extensions.self-hosted.json`
here first: ours should be upstream's list plus `arcim-migration`.

Check the image on the server:

```bash
SHORT=$(git -C /opt/accounted rev-parse --short=7 "$NEW")
docker pull ghcr.io/gorillos/accounted:$SHORT
docker image inspect ghcr.io/gorillos/accounted:$SHORT --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'   # = $SHORT
docker run --rm --entrypoint sh ghcr.io/gorillos/accounted:$SHORT -c 'grep -rlo arcim-migration /opt/gnubok-template/.next/server/chunks | wc -l'      # well above 100 (upstream image: ~30)
```

## 3. Review what changes

```bash
cd /opt/accounted
mkdir -p /root/accounted-update-$(date +%F) && U=/root/accounted-update-$(date +%F)

# Migrations to run (refuses if one is back-dated; notes edited old ones)
/root/accounted-image/scripts/new-migrations.sh "$OLD" "$NEW" > $U/new-migrations.txt

# New environment variables (names only, never values)
git diff "$OLD" "$NEW" -- docker/.env.example .env.example | grep -E '^[+-][A-Z_]+=' | sed 's/=.*//' | sort -u

# Deployment files that changed
git diff --stat "$OLD" "$NEW" -- docker-compose.yml docker/
```

- **New required env variable:** add it to `.env` before going live (back up `.env` first).
- **`docker/cron.Dockerfile` changed:** add `--build cron` in step 6.
- **`docker-compose.yml` or `docker/compose.caddy.yml` changed:** check that `compose.local.yml` still overrides the right keys (`docker compose config --services` and `--images`).
- **Read the release notes** for removed features or anything Siffrly depends on (REST v1, MCP, auth).

> Never run plain `docker compose config` here: it prints every secret in `.env`.

## 4. Back up

```bash
bash /opt/provision/scripts/backup-accounted.sh && tail -n 3 /var/log/accounted-backup.log
TS=$(date +%Y%m%d-%H%M%S); umask 077
docker exec supabase-db pg_dump -U supabase_admin -Fc -d postgres > /root/backups/pre-update-$TS.dump
cp /opt/accounted/.env /root/backups/env-accounted-pre-$TS.bak
cp /opt/accounted/compose.local.yml /root/backups/compose.local.yml-pre-$TS
```

## 5. Dry run (no downtime)

The dry run uses the checkout's migration files, so the files must be at
`$NEW` without touching the running app. Use a throwaway worktree:

```bash
git -C /opt/accounted worktree add --detach /opt/accounted-next "$NEW"
/root/accounted-image/scripts/dry-run-migrations.sh $U/new-migrations.txt /root/backups/pre-update-$TS.dump /opt/accounted-next
```

It needs about 2 GB of free RAM and takes roughly one minute per 500
migrations. Expected output ends with `DONE: N migrations applied OK` and
`row counts unchanged`. A failure here costs nothing: read the log, fix, repeat.

## 6. Go live (maintenance window, about 2–10 minutes)

Tell Siffrly first: the API is down for the duration.

```bash
# Record the provisioner's state
docker exec provision-provisioner-1 node src/selfcall.js development GET /v1/health > $U/provisioner-before.json

# Stop everything that writes
cd /opt/accounted && docker compose stop app cron
(cd /opt/provision && docker compose stop)

# Final dump: data may have changed since step 4
TS=$(date +%Y%m%d-%H%M%S); umask 077
docker exec supabase-db pg_dump -U supabase_admin -Fc -d postgres > /root/backups/pre-migrate-$TS.dump

# Migrate the live database
/root/accounted-image/scripts/apply-migrations.sh supabase-db $U/new-migrations.txt /opt/accounted-migrations-$(date +%F).log /opt/accounted-next

# Switch the checkout (our extension list is the only tracked local change)
git -C /opt/accounted worktree remove --force /opt/accounted-next
git -C /opt/accounted checkout -q -- docker/extensions.self-hosted.json
git -C /opt/accounted checkout -q --detach "$NEW"
cp /root/accounted-image/extensions.self-hosted.json /opt/accounted/docker/extensions.self-hosted.json
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$SHORT/" /opt/accounted/.env

# Start (add --build cron if cron.Dockerfile changed)
docker compose up -d app cron caddy
(cd /opt/provision && docker compose up -d)
```

If `apply-migrations.sh` stops with `FAILED`, do **not** start the new app.
Go to "Rollback" below.

## 7. Verify

```bash
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -E 'accounted|provision'   # app healthy, on :$SHORT
for u in https://accounted-dev.siffrly.com/api/health https://accounted-dev.siffrly.com/login https://api.siffrly.com/api/health; do curl -s -o /dev/null -w "%{http_code} $u\n" $u; done
sleep 120; docker logs --since 3m accounted-cron-1 2>&1 | grep -c 'job succeeded'
docker logs --since 3m accounted-cron-1 2>&1 | grep -E 'level=(error|warning)' | grep -oE 'APP_URL\}[^ "]*' | sort | uniq -c   # should be empty

# Provisioner: health and selftest (see /opt/provision/README.md, "Upgrade routine")
docker exec provision-provisioner-1 node src/selfcall.js development GET /v1/health    # contract_ok true, failed_checks []
docker exec provision-provisioner-1 node src/selfcall.js development POST /v1/selftest # ok true
```

If the health check reports `accounted_newer_than_tested: true`, follow the
provisioner README before letting Siffrly run tests.

## Rollback

The old image and the dumps stay on the server.

```bash
cd /opt/accounted && docker compose stop app cron
(cd /opt/provision && docker compose stop)
# Restore the database from the final dump (replaces all data written since)
docker exec -i supabase-db pg_restore -U supabase_admin -d postgres --clean --if-exists < /root/backups/pre-migrate-<TS>.dump
# Previous code and image
git -C /opt/accounted checkout -q --detach "$OLD"
cp /root/backups/compose.local.yml-pre-<TS> /opt/accounted/compose.local.yml
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=<old short sha>/" /opt/accounted/.env
docker compose up -d app cron caddy && (cd /opt/provision && docker compose up -d)
```

`--clean` drops and recreates only the objects in the dump. Tables and
functions that the new migrations *added* stay behind; the old app ignores
them, but they will be there when you retry the upgrade, so the retry's first
migrations may fail with "already exists". For a clean retry, restore the
dump into an empty database instead (as in the backup restore test in the
provisioner README).

Rehearse the restore on the throwaway container first if there is any doubt
(`dry-run-migrations.sh` with an empty list does exactly that).

## Afterwards

- Note the new commit and date in the table below.
- Old app images can be removed after a week: `docker image ls ghcr.io/gorillos/accounted`.
- Keep `/root/accounted-update-<date>/` until the next upgrade.

## History

| Date | From → to | Migrations | Downtime | Notes |
|---|---|---|---|---|
| 2026-11-20 | b0b481b9d → b2ec8b68e (release 2026-11-19 + 4 fixes) | 515 | ~2 min | First upgrade via this repo; local build had become impossible (OOM). |
