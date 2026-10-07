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
./start.sh --force-recreate   # wipe the database and start empty
```

## Data folders

| Folder      | Purpose                                        | Git |
|-------------|------------------------------------------------|-----|
| `exports/`  | timestamped export folders (one per export)    | ignored |
| `import/`   | staging folder for imports                     | ignored |
| `demo/`     | bundled demo dataset (same layout as exports)  | committed |

To import your own data, drop JSON files (one per table, `app.model.json`) into
`./import/` and press **Import** on the Data page (or run
`docker compose exec backend python manage.py import_data`).

## Service

```bash
./start.sh --install-service   # systemd unit, start on boot
```

See `scripts/manual.txt` for the operator manual.
