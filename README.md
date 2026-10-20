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
```

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

Before `--force-recreate` the script exports the running database to
`exports/`; `--force-recreate-demo` skips that export. Both keep the existing
`exports/` folder across the wipe. The Data page also
writes a safety export before every import, demo load or upload.

Empty-database login: `TEAMMGMT_ADMIN_EMAIL` / `TEAMMGMT_ADMIN_PASSWORD` in `.env`
(defaults `admin@team-management.local` / `changeme`). The demo dataset has its own
four logins (see the sign-in hint after start).

## Data folders

| Folder      | Purpose                                        | Git |
|-------------|------------------------------------------------|-----|
| `exports/`  | timestamped export folders (one per export)    | ignored |
| `import/`   | staging folder for imports                     | ignored |
| `demo/`     | bundled demo dataset (same layout as exports)  | committed |

The Data page (admin) can also download everything as a single JSON file and
restore from one, so a backup needs neither the database nor this folder.

To import your own data, drop JSON files (one per table, `app.model.json`) into
`./import/` and press **Import** on the Data page (or run
`docker compose exec backend python manage.py import_data`).

## Service

```bash
./start.sh --install-service   # systemd unit, start on boot
```

See `scripts/manual.txt` for the operator manual.
