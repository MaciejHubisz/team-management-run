# team-management — run repository

Run-only checkout for **team-management** (the single-team amateur hockey
operations web app). This folder holds no application source, schema, or dumps:
it vendors the shared `common/ops` lifecycle framework and a `docker-compose.yml`
that runs the pre-built images. The source lives in the sibling `team-management`
repository.

## Quick start

```bash
./start.sh --start
```

If `../team-management` is present (the source repo), images are built from it
first; otherwise they are pulled from the configured registry.

```bash
./start.sh --status
./start.sh --stop
./start.sh --update
./start.sh --force-recreate        # recreate the database from scratch, empty
./start.sh --force-recreate-demo   # same, then load the demo dataset
./start.sh --force-recreate-prod   # same, then load the production dataset
```

## Configuration

Everything is in one file, [`.env`](.env): image tag, container port, public
domain and TLS, Django URLs and hosts, cache, database credentials,
auto-backup schedule, email provider, systemd service and CI deploy target. The start
script, the host setup script, `e2e.sh`, and every container read it.
`docker-compose.yml` holds only wiring.

Secrets stay out of the committed `.env`. They go in `secrets.env`, which is
gitignored and created by `./start.sh` on its first run (mode 600, every key
commented out). Every container and script reads it after `.env`:

```bash
DJANGO_SECRET_KEY=…          # python3 -c "import secrets; print(secrets.token_urlsafe(50))"
EMAIL_HOST_PASSWORD=…        # password of the EMAIL_HOST_USER account
TEAMMGMT_REGISTRY_TOKEN=…    # read:packages token for the private ghcr.io images
```

Changing `DJANGO_SECRET_KEY` signs everyone out once. When the host setup
script asks for a registry token, it saves the token in `registry.env`, which
is also gitignored. The image itself is configured in the source repo's
`app.conf`.

### Cache

Database reads and sessions are cached in the `redis` container (DB 1; the
Huey queue uses DB 0). Every write invalidates exactly what it changed, so
nothing needs flushing after an edit or an import. The `CACHE_*` lines in
`.env` choose the backend (`dummy` turns it off), the entry lifetime and what
is cached; change them and run `./start.sh --update`. Sessions live in the
cache too, so the site needs the `redis` container up.

### Email

Set `EMAIL_HOST`, `EMAIL_PORT` and `EMAIL_HOST_USER` in `.env`, put
`EMAIL_HOST_PASSWORD=…` in `secrets.env`, and run `./start.sh --update`. Then
check the settings with a test message:

```bash
docker compose exec backend python manage.py send_test_email you@example.com
```

With `EMAIL_HOST` empty, emails are only logged. Otherwise every email waits in
a queue in the database until the server accepts it. The `worker` container
tries it at once, then retries 1, 2, 5, 10 and 30 minutes later, then hourly.
A sign-in link stops being retried when the link expires (30 minutes),
anything else after 48 hours. Settings → Integrations → Email queue shows what
is waiting and why, and has a "Send now" button. Failed emails stay listed
until a later email goes out or you press "Clear failed".

### Google sign-in

Players register only from an invitation; Google is an extra way to do it and
to sign in afterwards. In Google Cloud Console create an OAuth client of type
"Web application" (consent screen: External, scopes `openid`, `email`,
`profile`) with the authorized redirect URI `SITE_URL/accounts/google/callback/`
(`https://odynce.nfy.pl/accounts/google/callback/`). Put `GOOGLE_CLIENT_ID=…` in
`.env` and `GOOGLE_CLIENT_SECRET=…` in `secrets.env`, then `./start.sh --update`.
The login page and the invitation page then show "Continue with Google". A
Google account without an invitation gets no login.

### Facebook sign-in

Same rules as Google: an extra way to register from an invitation and to sign
in afterwards; a Facebook account without an invitation gets no login.

1. On developers.facebook.com create an app (use case "Authenticate and
   request data from users with Facebook Login", type Consumer).
2. Use cases → Facebook Login → Permissions: add `email` (`public_profile` is
   there already).
3. Facebook Login → Settings: Client OAuth login and Web OAuth login on,
   Enforce HTTPS on, Valid OAuth Redirect URIs
   `SITE_URL/accounts/facebook/callback/`
   (`https://odynce.nfy.pl/accounts/facebook/callback/`).
4. App settings → Basic: App domains `odynce.nfy.pl`, Privacy Policy URL
   `https://odynce.nfy.pl/legal/privacy/`, User data deletion: "Data deletion
   instructions URL" pointing to the same privacy page (deleting data is a
   request to the admin there). Copy the App ID and App Secret.
5. Put `FACEBOOK_APP_ID=…` in `.env` and `FACEBOOK_APP_SECRET=…` in
   `secrets.env`, then `./start.sh --update`.
6. Switch the app to Live (App Mode). In Development only people with a role
   on the app (admins, developers, testers) can sign in.

The login page and the invitation page then show "Continue with Facebook".
Facebook sends no "email verified" flag, and a person can refuse to share the
email: such a sign-in is refused with "Facebook sign-in did not finish".

The console output of the last `--start` / `--update` (build included) is saved
to `tmp/start.log` in this folder (git-ignored); a standalone `../team-management/build.sh`
saves to `/tmp/team-management-build.log`. Each run overwrites its file.

## Database

PostgreSQL runs as its own compose service on the named volume `teammgmt-pg`.
The app containers (`backend`, `worker`, `web`) are stateless:

| Command | Database |
|---|---|
| `--start`, `--update`, `--stop` | untouched (migrations apply new schema on backend start) |
| `--force-recreate` | database recreated from scratch by migrations, **no rows** except one admin login |
| `--force-recreate-demo` | identical, then the demo dataset is loaded |
| `--force-recreate-prod` | identical, then the production dataset (`prod/`) is loaded |

Before `--force-recreate` the script exports the running database to
`exports/` (`--force-recreate-prod` too); `--force-recreate-demo` skips that export. Both keep the existing
`exports/` folder across the wipe. Settings → Backup also
writes a safety export before every import, demo load or upload.

Empty-database login: `TEAMMGMT_ADMIN_EMAIL` / `TEAMMGMT_ADMIN_PASSWORD` in `.env`
(default email `admin@team-management.local`; without a password a random one is
generated and printed once: `docker compose logs backend | grep 'Generated admin password'`). The demo dataset has its own
staff logins (see the sign-in hint after start). Its players have no logins (contact details
only), except Maciej Hubisz: `mhubisz91@gmail.com` / `changeme`, role player.

## Data folders

| Folder      | Purpose                                        | Git |
|-------------|------------------------------------------------|-----|
| `exports/`  | timestamped export folders (one per export)    | ignored |
| `auto-backups/` | hourly `.json.gz` bundles, last 48 h       | ignored |
| `import/`   | staging folder for imports                     | ignored |
| `demo/`     | bundled demo dataset (same layout as exports)  | committed |
| `prod/`     | production starting dataset (same layout)      | committed |

Settings → Backup (admin) can also download everything as a single JSON file and
restore from one, so a backup needs neither the database nor this folder.

### Auto-backups

The `backup` service writes one gzipped bundle per hour while the stack is up
(`auto-backups/team-management-auto-<timestamp>.json.gz`, a few KB each) and
deletes its own files older than 48 hours. It is the only container that mounts
this folder: the web app cannot see or delete it, and `--force-recreate` does not
touch it. The file has the same format as the Settings → Backup single-file download.
Disaster recovery:

```bash
# Settings → Backup → restore from file → pick the .json.gz, or:
cp auto-backups/team-management-auto-….json.gz import/
docker compose exec backend python manage.py import_data --bundle /app/import/team-management-auto-….json.gz
```

`prod/` is the real club data: roster, rinks, season Zima 2026 with its declarations, formations, events,
lineups, attendance and notifications. It carries the admin login (change its
password), three coach logins and two player logins.
Load it with **Load production data** on Settings → Backup,
`docker compose exec backend python manage.py load_prod`, or start from scratch
with `./start.sh --force-recreate-prod` (sign in as `admin` / `changeme`).

To import your own data, drop JSON files (one per table, `app.model.json`) into
`./import/` and press **Import** on Settings → Backup (or run
`docker compose exec backend python manage.py import_data`).

## Browser tests (e2e)

```bash
./e2e.sh            # run the browser test suite and watch it at http://localhost:7900
./e2e.sh --window   # same, in a Chromium window on this desktop
./e2e.sh --fast     # headless; ./e2e.sh --help for filters and options
```

Runs the `team-management-e2e` image (built from `../team-management` when it
is present, otherwise pulled) against its own throwaway database; the running
app and its data are not touched. Report and failure traces: `tmp/e2e/`. The
tests themselves live in the source repo (`e2e/`, see its `docs/testing/e2e.md`).

## Service

```bash
./start.sh --install-service   # systemd unit, start on boot
```

See `scripts/manual.txt` for the operator manual.
