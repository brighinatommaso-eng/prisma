# Prisma backend

> **⚠️ No authentication — never expose this service to the internet.** LAN and
> Tailscale only; no port forwarding, no public reverse proxy. The full warning is at
> the top of the [repository README](../README.md).

Self-hosted music download service. This is **phase 1a** of section 9 of the design
spec: it exists only to prove the two external dependencies work inside Docker —
ytmusicapi for search and yt-dlp for audio extraction. There is no job queue, no
library, and no download endpoint yet.

Deployed and verified on `your-server` at `http://YOUR_SERVER_IP:8000`.

`YOUR_SERVER_IP`, `YOUR_USER` and `your-server` throughout this README are
placeholders — substitute your own server address, SSH username and hostname.
Every command below is runnable as written once you have.

## What is here

| Path | Purpose |
|---|---|
| `app/main.py` | FastAPI app: `GET /health`, `GET /search`, `POST /import/demus` |
| `app/ytm.py` | the only module that talks to YouTube Music |
| `app/demus.py` | parser for a Demus playlist export; no network, no database |
| `app/worker.py` | the download worker: one job at a time, paced, with the bot-wall cooldown |
| `app/integrity.py` | which tracks have no file or the wrong file; `POST /repair` and the `missing_files` count |
| `app/config.py` | reads `PRISMA_MUSIC_DIR`, `PRISMA_HOST`, `PRISMA_PORT` |
| `scripts/smoke_download.py` | manual yt-dlp spike, **not** wired into the API |
| `scripts/guard.py` | makes every test script refuse to start where the real library is |
| `scripts/backup_state.py` | daily backup of the catalogue and the collection, run on the host by cron |
| `Dockerfile` | python:3.12-slim + ffmpeg + deno (yt-dlp's JS runtime) |

## Endpoints

```
GET /health
  -> { ytdlp_version, ytmusicapi_version, music_free_bytes, youtube_music_reachable,
       track_count, album_count, total_bytes_stored,
       js_runtime, po_token_provider_active, last_successful_download_at,
       download_cooldown_active, download_cooldown_until, missing_files }

GET /search?q=<string>&limit=<1..50>     limit defaults to 20
  -> [ { video_id, title, artist, album, duration_s,
         artwork_url, artwork_url_small }, ... ]

POST /import/demus                       body: the .playlist file, raw
  -> { name, created_at,
       songs: [ { video_id, title, artist, album, artwork_url, duration_s }, ... ] }

POST /downloads                          body: { "video_id": "..." }
  -> 200 { status: "exists", track }                    in the catalogue, file on disk
  -> 202 { status: "queued", job_id, video_id }         queued for download
  -> 202 { status: "queued"|"running", job_id, video_id }   file gone, already being repaired

POST /repair?dry_run=<true|false>        dry_run defaults to false
  -> { dry_run, checked, missing, mismatch, unverified, queued, skipped }
```

`/health` always answers 200. `youtube_music_reachable` goes `false` on a failed or
slow probe rather than failing the request — the point of the endpoint is to stay
answerable when something upstream is broken.

`youtube_music_reachable` is the only field that costs an upstream request: one
unauthenticated YouTube Music search. It is **cached for 60 seconds**, because the
iOS client polls `/health` every few seconds and one search per poll is exactly the
repetition that provokes "Sign in to confirm you're not a bot". A probe that fails
is cached for the same 60 seconds, so a YouTube Music outage is not hammered either.

`js_runtime`, `po_token_provider_active` and `last_successful_download_at` exist
to date and explain a yt-dlp breakage (spec section 3.6),
typically "Sign in to confirm you're not a bot":

| Field | Meaning |
|---|---|
| `js_runtime` | The JavaScript runtime yt-dlp would use for YouTube's player challenges, e.g. `"deno 2.9.7"`. The image ships deno, so this is `null` only if something is wrong. A runtime too old for yt-dlp is still named, suffixed ` (unsupported)`. |
| `po_token_provider_active` | `true` only when a PO token provider plugin is registered with yt-dlp **and** reports itself available — installed-but-unusable counts as `false`. |
| `last_successful_download_at` | Unix time the most recent download job finished with state `done`; `null` if none ever has. |

The two `download_cooldown_*` fields say whether the download queue is resting
after a bot wall, and until when (Unix time; `null` when it is not). They are read
from the database and cost no request. See
[Download pacing and the bot-wall cooldown](#download-pacing-and-the-bot-wall-cooldown).

`missing_files` is the number of live tracks whose file is absent, or is there but
does not match the SHA-256 stored for it. It is computed with the other probes and
**cached for 60 seconds**; it reads the local disk only and never contacts YouTube.
Hashing is remembered per file and repeated only when a file's size or modification
time changes, so after the first pass a re-count costs one `stat` per track. That
first pass, after each start, hashes the whole library. The field is **`null` when
the count is not known** — the scan failed, or it is still running when the probe
timeout (8 s) expires — and never `0` in that case: read `null` as "ask again", not
as "nothing is missing". `/health` only counts; it never starts a repair. See
[Missing files and repair](#missing-files-and-repair).

`js_runtime` and `po_token_provider_active` are asked of yt-dlp itself, built with
the download pipeline's own options, so they show what a download would really use.
They make no network request. The probe costs about a second on the first call after
a start (importing yt-dlp) and is then cached for five minutes; both TTLs and the
cache they share live in `app/diagnostics.py`. The probe relies on yt-dlp
internals, and if a yt-dlp update moves them the container log shows
`JS runtime probe failed` or `PO token provider probe failed` and the fields read
`null` / `false` — check the log before trusting a `null` there.

Interactive docs, generated by FastAPI: `http://YOUR_SERVER_IP:8000/docs`.
The OpenAPI document at `/openapi.json` is the backend/app contract (spec section 2).

### The two artwork fields

Search results from YouTube Music only ever carry a 120x120 thumbnail, which is too
small both for cover display and for the palette extraction in spec section 3.3.
googleusercontent encodes the rendition in a suffix after the final `=`, so the
larger variant is a URL rewrite, not a second API call.

- `artwork_url` — rewritten to `=w544-h544-l90-rj`, **HEAD-verified** before being
  returned. If the larger rendition does not answer 200 with an `image/*` content
  type, this field falls back to the 120x120 URL, which is known to work. The
  download phase persists this value, so an unverified URL would become a
  permanently broken link on a stored track.
- `artwork_url_small` — the original 120x120 URL, for list thumbnails.

googleusercontent does **not upscale**. For an album whose source art is smaller
than 544px it serves the source size instead — 512x512 is common. That is a 200
with a real image, so it is accepted rather than rejected: the field guarantees
"the best rendition that actually exists, verified fetchable", not "exactly 544px".

Verification costs one HEAD per result, run concurrently with 8 workers. A
`limit=5` search takes about 0.75s end to end.

### Importing a Demus playlist

`POST /import/demus` reads a playlist exported by the Demus app and returns what is
in it. It **only parses**: nothing is downloaded, queued or stored, and the server
makes no request. Deciding what to download is left to the client, which queues
each song through `POST /downloads` with the `video_id` it was given.

The body is the `.playlist` file itself — not a multipart form:

```powershell
curl.exe -s --data-binary "@Rap.playlist" -H "Content-Type: application/octet-stream" "http://YOUR_SERVER_IP:8000/import/demus"
```

```json
{"name":"Rap","created_at":1782052736,
 "songs":[{"video_id":"DbWqfUPVoOo","title":"Yung 3p 3","artist":"Kid Yugi",
           "album":"The Globe",
           "artwork_url":"https://yt3.googleusercontent.com/...=w544-h544-l90-rj",
           "duration_s":118}]}
```

- `songs` is in the file's order, and a song listed twice appears twice.
- `video_id` is the export's `id`, untouched: the YouTube video id, which is
  Prisma's own track key.
- `created_at` is the export's ISO 8601 `createdDate` as Unix seconds, like every
  other timestamp in the API; `null` if the export has none.
- `title`, `artist`, `album`, `artwork_url` and `duration_s` are `null` when the
  export does not carry them.
- `artwork_url` is rewritten to `=w544-h544-l90-rj` for a googleusercontent URL
  and passed through unchanged for any other host. Unlike `/search` it is **not**
  HEAD-verified, because this endpoint makes no request; the rewrite is limited to
  the host where a larger size than exists is answered with the source size
  rather than an error.
- The export's `albumId` is deliberately not returned. In real exports it is
  sometimes a channel id, not an album; the download pipeline resolves the album
  itself. Lyrics, genre and the artist fields are ignored too.

The file is xz-compressed JSON, and both sizes are capped so a hostile file cannot
exhaust memory: **4 MiB compressed** and **16 MiB decompressed**. The first is
enforced while the request is read and the second while the data is unpacked, so
neither is ever held in full past its limit. A playlist may carry at most
**10,000 songs**. The constants are in `app/demus.py`.

Anything that is not a readable export answers **422**, with a `detail` string
saying what is wrong — for example:

| `detail` begins | Cause |
|---|---|
| `The request body is empty` | no file was sent |
| `This is not an xz file` | some other file, or the JSON sent uncompressed |
| `The xz data is truncated` / `is corrupt` | an incomplete or damaged upload |
| `The decompressed content is not JSON` | xz, but not a Demus export |
| `The playlist has no 'songs' list` | JSON of some other shape |
| `Song 7 has no 'id'` | a song that cannot be matched to a track; the number is its position in the file |
| `The playlist contains text that is not valid Unicode` | a string holding half of a surrogate pair |
| `The playlist has 10001 songs, more than the 10000 songs one import may carry` | over the song cap |
| `The file is larger than the 4194304 byte limit on the compressed size` | over the compressed cap |
| `The file decompresses to more than the 16777216 byte limit on the decompressed size` | over the decompressed cap |

## Missing files and repair

The catalogue lives in `.prisma` and the audio beside it, and the two can come
apart: files removed from the share by hand leave rows that promise audio
`GET /tracks/{id}/file` can only answer **410** for. `app/integrity.py` sorts every
live track into one of four states, and both `/health` and the repair use that one
classification:

| State | Meaning | Counted in `missing_files` | Queued by `POST /repair` |
|---|---|---|---|
| `missing` | no file at the recorded path (or the row has no path) | yes | yes |
| `mismatch` | a file is there, and its SHA-256 is not the stored one | yes | yes |
| `unverified` | a file is there, and the row has no stored SHA-256 to compare | no | no, only listed |
| `ok` | a file is there and its SHA-256 matches | no | no |

### POST /repair

Queues a download for every `missing` and `mismatch` track. **It is the only way a
repair starts**: nothing runs it at startup, on a timer or from `/health`.

```powershell
curl.exe -s -X POST "http://YOUR_SERVER_IP:8000/repair?dry_run=true"
curl.exe -s -X POST "http://YOUR_SERVER_IP:8000/repair"
```

```json
{"dry_run":false,"checked":69,
 "missing":["DbWqfUPVoOo","Jb6gcoR266U"],
 "mismatch":["zVeVSydiT2c"],
 "unverified":[],
 "queued":[{"video_id":"DbWqfUPVoOo","job_id":112},{"video_id":"zVeVSydiT2c","job_id":113}],
 "skipped":[{"video_id":"Jb6gcoR266U","reason":"job_active","job_id":108,"job_state":"queued"}]}
```

- `checked` is the number of live tracks looked at. Deleted tracks are not looked at.
- `queued` holds one job per track, in id order. With `dry_run=true` it is empty and
  nothing is written; everything else in the report is what a real run would say.
- `skipped` lists what was found broken and not queued, with a `reason`:
  `job_active` — a job for the track is already queued or running (`job_id`,
  `job_state`), so calling `/repair` twice never queues a track twice; `deleted` —
  the track was deleted while the scan ran (`job_id` and `job_state` are `null`).
- The jobs are ordinary download jobs: watch them with `GET /downloads`, cancel a
  queued one with `DELETE /downloads/{id}`. They run one at a time with the usual
  12 to 20 second gap, they wait out a bot-wall cooldown like any other job, and a
  job that fails **is not retried** — the track simply shows up again in the next
  `/repair`, which you have to ask for.
- A repaired track keeps its row and its album; its `file_bytes`, `sha256` and
  `updated_at` change, so the next `GET /library?since=` carries it. The album's
  `cover.jpg` is written again if it is not there.
- The scan hashes files, in a worker thread; on a large library the first call
  after a start can take a while.

### POST /downloads repairs a single track

`POST /downloads` asks only the cheap question, whether the file exists:

| The `video_id` is | Answer |
|---|---|
| live in the catalogue, file on disk | `200 {"status":"exists","track":{...}}`, nothing queued |
| live in the catalogue, **file gone** | `202 {"status":"queued","job_id":N,"video_id":"..."}` |
| the same, and a job for it is already queued or running | `202` with **that** job: its `job_id`, and its real state (`queued` or `running`) as `status` |
| deleted, or never downloaded | `202 {"status":"queued",...}`, as before |

A file that is present but wrong still answers `exists` here; finding those is what
`/repair` is for. Until the job has run, `GET /tracks/{id}/file` and the album's
cover keep answering 410.

### Two tracks, one name

Two different recordings can share artist, album and title. The first one to arrive
is filed at `Artist/Album/Title.m4a`; any other is filed beside it as
**`Artist/Album/Title [video_id].m4a`**, and that is the path its row records. The
title is shortened if needed so that the id always fits. `cover.jpg` is unchanged:
one per album folder, shared by every track in it.

A track downloaded again goes back to the path on its row, as long as that path is
still its own: the file there has its recorded SHA-256, or there is no file and no
lower video id is recorded at the same path. Otherwise it gets its bracketed path.
**Nothing is ever renamed, moved, deleted or written over to make room** — a file
that is not a track's recorded audio is left exactly where it is, and stays on disk
unreferenced if no row points at it any more. That rule is also what separates two
ids that were recorded at one path before this was fixed:

- If the file is still there, the id whose stored SHA-256 matches it keeps the
  shared path and is not touched; the other one is `mismatch`, and a repair
  downloads it to its bracketed path.
- If the file is gone, both are `missing`; the **lower video id** (plain string
  order) keeps the shared path and the other one gets its bracketed path, whichever
  of the two jobs runs first.

If the bracketed path itself holds a file that is not the track's recorded audio,
the job fails with `PathConflict` and says which file; nothing is downloaded.

## Download pacing and the bot-wall cooldown

Downloads run one at a time. Importing a playlist queues dozens of them at once,
which is the volume that has provoked "Sign in to confirm you're not a bot"
before, so the worker (`app/worker.py`) paces itself:

- **A gap between downloads.** After a download attempt ends — done or failed —
  the next one starts no sooner than a random 12 to 20 seconds later. A job that
  arrives after the queue has been idle for longer than that starts at once.
- **A cooldown after a bot wall.** When a job fails with the bot wall, or with an
  HTTP 429 from YouTube, that job fails as any other does, error text intact, and
  is **not retried**. The rest of the queue then waits for **30 minutes** instead
  of being run into the same wall one job after another. Waiting jobs stay
  `queued`; none is failed or cancelled, and when the cooldown ends the worker
  carries on with the next one.

The end of the cooldown is stored in the database, so it **survives a restart**: a
redeploy is usually what follows a bot wall, and the queue must not go straight
back to YouTube because the container is new. `/health` shows it:

```json
{"download_cooldown_active":true,"download_cooldown_until":1789499782}
```

Everything else keeps working during a cooldown. `POST /downloads` still queues,
`DELETE /downloads/{id}` still cancels a queued job, and tracks can be deleted.
The gap, unlike the cooldown, is held in memory: the first download after a
restart starts without waiting.

The container log records it:

```
job 41 hit YouTube's bot wall: queued downloads wait until 1789499782 (1800 s); the failed job is not retried
download cooldown in force until 1789499782; queued jobs wait
```

The three durations are constants at the top of `app/worker.py`.

## Tests

**The tests are never run in the running container, and never against the real
library.** They create and delete tracks and rewrite the catalogue; they do it in a
scratch directory, and `scripts/guard.py` makes sure of that. It is the first thing
every `test_*.py` calls, and it exits with status 3 and a message starting
`REFUSING` — before creating anything and before importing the application — when
the process was started where the library is:

- the `PRISMA_MUSIC_DIR` it inherited resolves to `/music` or `/opt/prisma/music`.
  An unset variable counts as `/music`, because that is the application's default;
  or
- a `.prisma/catalog.db` exists in the inherited `PRISMA_MUSIC_DIR`, wherever that
  is, or an inherited `PRISMA_STATE_DIR` or `PRISMA_DB_PATH` names an existing
  catalogue.

Past that, the guard sets every path variable to the scratch directory itself, and
after the application is imported it checks what `app.config` really resolved.
`scripts/smoke_download.py` is not a test but writes into the music directory, so
it refuses in the same place; see [The yt-dlp smoke test](#the-yt-dlp-smoke-test).

The scripts are plain Python, each printing `N/N passed`. These need neither the
network nor YouTube and run on a bare development machine:

```powershell
python scripts/test_guard.py
python scripts/test_demus_import.py
python scripts/test_download_pacing.py
python scripts/test_collection.py
python scripts/test_track_deletion.py
python scripts/test_path_collisions.py
python scripts/test_repair.py
python scripts/test_backup_state.py
```

On Windows that is all there is to it. On Linux or macOS an unset `PRISMA_MUSIC_DIR`
means `/music` and is refused, so name any directory that is not the library:
`PRISMA_MUSIC_DIR=/tmp/not-the-library python3 scripts/test_guard.py`.

Where a package is absent the affected tests say so and are skipped:
`test_demus_import.py` skips its three endpoint tests without ytmusicapi, and
`test_collection.py` its HTTP tests without httpx. `test_path_collisions.py` and
`test_repair.py` drive the real pipeline, worker step and endpoint functions with
the network parts replaced; `scripts/stubs.py` gives them something to import where
ytmusicapi and mutagen are not installed.

`test_health_diagnostics.py` and `test_album_normalisation.py` need the real yt-dlp
and ytmusicapi, which only the image has. Run them — or any other test — in a
**throwaway container** of that image: no volume, no network, and a music directory
that is explicitly not the library:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "docker run --rm --network none --entrypoint python -e PRISMA_MUSIC_DIR=/scratch-not-the-library prisma-backend:latest scripts/test_health_diagnostics.py"
```

`docker run` starts a new container from the image; it is not the running one and
shares nothing with it. Nothing is mounted, so the library is not there to be
touched, and `--rm` discards the container afterwards. `--entrypoint python` with
the script as the argument replaces the image's start command, so neither the
yt-dlp self-update nor the server runs. Without `-e PRISMA_MUSIC_DIR=...` the guard
refuses, as it would in the running container.

## Configuration

Nothing is hardcoded to a machine. Every value is an environment variable with a
default, set in `../docker-compose.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `PRISMA_MUSIC_HOST_DIR` | `/opt/prisma/music` | host directory holding the library |
| `PRISMA_MUSIC_DIR` | `/music` | the same directory seen from inside the container |
| `PRISMA_PORT` | `8000` | port on the host and in the container |
| `PRISMA_HOST` | `0.0.0.0` | uvicorn bind address inside the container |
| `PRISMA_BACKUP_DIR` | none | host directory for the daily backups; read only by `scripts/backup_state.py`, see [Backup](#backup) |

To override, put a `.env` next to `docker-compose.yml` (it is gitignored):

```dotenv
PRISMA_MUSIC_HOST_DIR=/mnt/nas/musica
PRISMA_PORT=8000
```

There is no authentication. The service is only meant to be reachable over the LAN
and over Tailscale; do not publish port 8000 to the internet.

## Backup

The catalogue and the favourites and playlists live in `.prisma`, inside the music
folder, so whatever empties that folder can take them too. `scripts/backup_state.py`
copies `catalog.db` and `collection.json` somewhere else once a day and keeps the
last **7** copies. It runs **on the host**, from cron, not in the container: the
backup directory is deliberately not mounted into it. It needs only the host's
`python3` (3.7 or later), no extra package and no root — read access to
`.prisma` and write access to the backup directory.

Tell it where the backups go, in the `.env` next to `docker-compose.yml`. There is
no default, and the script refuses to run without it:

```dotenv
PRISMA_BACKUP_DIR=/path/outside/the/music/folder/prisma-backups
```

It also reads `PRISMA_MUSIC_HOST_DIR` from the same place (default
`/opt/prisma/music`). A variable set in the environment wins over the file. **The
backup directory must not be inside the music folder** — the script resolves both
paths, links included, and refuses if it is.

Check the settings without writing anything, then make the first backup by hand:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && python3 backend/scripts/backup_state.py --dry-run"
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && python3 backend/scripts/backup_state.py"
```

```
prisma-backup OK prisma-state-20261013T031500Z catalog.db=180224 bytes tracks=69 collection.json=yes kept=7 removed=1 dir=/path/outside/the/music/folder/prisma-backups
```

Then once a day from the crontab of the account that owns `/opt/prisma`
(`crontab -e`), with your own paths in place of the placeholders:

```
15 3 * * * cd /opt/prisma && python3 backend/scripts/backup_state.py >> /path/to/prisma-backup.log 2>&1
```

Success is one line starting `prisma-backup OK` and exit code 0. A failure is one
line starting `prisma-backup FAILED` on standard error and a non-zero exit code.

What it does, and what it will not do:

- `catalog.db` is SQLite in WAL mode and the server is running, so recent writes
  are in `catalog.db-wal` and **a plain `cp` of `catalog.db` is not a usable
  backup**. The script copies through SQLite's backup API from a read-only
  connection: one consistent snapshot, taken while the server keeps working, with
  nothing written to the database.
- The copy is verified with `PRAGMA integrity_check` and taken out of WAL mode, so
  each backup's `catalog.db` is a single self-contained file.
- Each backup is a directory `prisma-state-<UTC timestamp>` holding `catalog.db`,
  `collection.json` if there is one, and `backup.json` (time, size, SHA-256, track
  count). It is built as `...Z.partial` and renamed only once verified.
- Rotation runs only after that. **A backup that fails removes nothing**, so a
  broken catalogue cannot push the good copies out.
- It deletes only directories it made itself, in the backup directory: exactly
  named `prisma-state-<timestamp>` and containing `backup.json`, beyond the newest
  seven, plus `.partial` leftovers of earlier runs that were killed. Anything else
  in that directory is left alone, and nothing under the music folder is ever
  written or removed.

### Restoring

Stop the server first: the catalogue must not be open while its file is replaced.
Set the old files aside rather than deleting them — including any `-wal` and `-shm`,
which belong to the old database and must not be left next to the restored one.

```bash
cd /opt/prisma && docker compose stop backend

STATE=/opt/prisma/music/.prisma                      # PRISMA_MUSIC_HOST_DIR/.prisma
BACKUP=/path/outside/the/music/folder/prisma-backups/prisma-state-20261013T031500Z

mkdir "$STATE/before-restore"
mv "$STATE"/catalog.db* "$STATE/before-restore/"
cp "$BACKUP/catalog.db" "$STATE/catalog.db"

docker compose start backend
```

Then check `/health`: `track_count` is the restored catalogue's, and `missing_files`
says how many of its tracks have no file on disk — `POST /repair` downloads those
again.

The favourites and playlists are inside `catalog.db`, so restoring it restores them
as of that backup. `collection.json` is the server's own second copy, written on
every change and never read back automatically; the backup carries it so that a
collection newer than the restored catalogue is not lost. To put it back, `PUT` its
content to `/collection`.

## Deploy and redeploy

The deploy target is `/opt/prisma` on `your-server`
(`YOUR_SERVER_IP`, also `your-server` over Tailscale MagicDNS).

**Use Windows OpenSSH from PowerShell, not Git Bash.** The deploy key is
passphrase-protected and lives in the Windows `ssh-agent` service, which Git Bash's
bundled `ssh` cannot reach — it fails with `Permission denied (publickey,password)`
even though the key is loaded. PowerShell's `ssh.exe` and `scp.exe` use that agent.

One-time, and the only step that needs root, because `/opt` is root-owned:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP -t "sudo mkdir -p /opt/prisma/music && sudo chown -R YOUR_USER:YOUR_USER /opt/prisma"
```

First install and every redeploy are the same two commands, because the image bakes
in `app/`:

```powershell
scp -r backend docker-compose.yml YOUR_USER@YOUR_SERVER_IP:/opt/prisma/
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose up -d --build"
```

`--build` is required. Without it the container keeps running the old code. Compose
replaces only the `prisma` project's container and leaves every other container on
the host alone.

Do not `scp` a `backend/` tree that contains `__pycache__` from a local test run —
it ends up inside the image. Copy from a clean tree.

Rebuild from scratch, ignoring the layer cache — needed when a base image or an apt
package is the suspect:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose build --no-cache && docker compose up -d"
```

Restart without rebuilding, which also re-runs the yt-dlp self-update:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose restart"
```

## Logs

```powershell
# is it up, and on which port
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose ps"

# follow
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose logs -f"

# last 25 lines, no follow, no ANSI colour
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose logs --tail 25 --no-color"

# since a time
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose logs --since 30m"
```

A healthy start logs pip checking yt-dlp, then `Application startup complete.` and
`Uvicorn running on http://0.0.0.0:8000`. A warning about running pip as the root
user is expected and harmless. If you instead see
`WARNING: yt-dlp self-update failed`, the container still came up but is running the
version baked into the image — check the server's outbound network, then confirm the
version at `/health`.

## Verify a deploy

```powershell
curl.exe -s "http://YOUR_SERVER_IP:8000/health"
curl.exe -s "http://YOUR_SERVER_IP:8000/search?q=daft%20punk%20around%20the%20world&limit=5"
```

A healthy `/health`:

```json
{"ytdlp_version":"2026.8.19","ytmusicapi_version":"1.12.2",
 "music_free_bytes":283578765312,"youtube_music_reachable":true,
 "track_count":9,"album_count":8,"total_bytes_stored":35138452,
 "js_runtime":"deno 2.9.7","po_token_provider_active":false,
 "last_successful_download_at":1789497982,
 "download_cooldown_active":false,"download_cooldown_until":null,
 "missing_files":0}
```

A `missing_files` above 0 means tracks in the catalogue have no file, or the wrong
one; `POST /repair?dry_run=true` names them. `null` means the count is not known
yet, not that it is zero. A `js_runtime` of `null` means deno is missing from the image or yt-dlp stopped
seeing it — check `docker compose exec -T backend deno --version`.
`po_token_provider_active: false` is the image as it is today: downloads work
without a provider, but it is the next thing to look at when YouTube starts
answering with a bot check.

## The yt-dlp smoke test

yt-dlp breaks without warning whenever YouTube changes something server-side
(spec section 3.6). This script is the one-command diagnosis. It is a manual spike
and is deliberately not reachable over HTTP.

It writes its download into `PRISMA_MUSIC_DIR`, so it is run in a throwaway
container with no volume, where that directory is not the library and the file
disappears with the container:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "docker run --rm --entrypoint python -e PRISMA_MUSIC_DIR=/tmp/prisma-smoke prisma-backend:latest scripts/smoke_download.py Jb6gcoR266U"
```

That container runs the yt-dlp baked into the image, not the one the running
container updated itself to at its last start; compare `ytdlp_version` at `/health`
if the two might differ. To test the running container's own yt-dlp, the script has
to be told that writing into the real library is intended — without the flag
`scripts/guard.py` refuses, as it does for the tests. The file lands in the library
root as `<video_id>.m4a` and nothing removes it afterwards:

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose exec -T backend python scripts/smoke_download.py Jb6gcoR266U --write-into-the-real-library"
```

`-T` is required over SSH: without it `docker compose exec` tries to allocate a TTY
and aborts with `the input device is not a TTY`. The compose *service* is named
`backend`; the *container* it creates is named `prisma-backend`.

It prints the path, the size in bytes and the ffprobe audio-stream lines. Exit code
0 and `codec_name=aac` mean the pipeline is intact. Known-good output:

```
path:  /tmp/prisma-smoke/Jb6gcoR266U.m4a
bytes: 6948385
ffprobe:
  codec_name=aac
  profile=LC
  sample_rate=44100
  channels=2
  bit_rate=127999
```

Format selection is locked by spec section 3.2: `bestaudio[ext=m4a]/bestaudio`,
downloaded as a pure copy with no re-encoding — itag 140, AAC-LC 128 kbps. Only if
no m4a exists for a given video does the script transcode to AAC 192 kbps. In that
case it **keeps** the source file next to the result, so a bad transcode stays
diagnosable — delete it by hand if you do not want it.

## Known issues to carry into the next phase

**Downloaded files are owned by root.** The container runs as root, so
`/opt/prisma/music/*.m4a` comes out `root:root`. Nothing in phase 1a cares, but
pointing Navidrome at the same directory (spec section 3.7) will, and so will any
cleanup from a non-root account.

## The JavaScript runtime

yt-dlp needs a JavaScript runtime to solve YouTube's player challenges; without one
it warns that "YouTube extraction without a JS runtime has been deprecated, and some
formats may be missing". The image therefore carries **deno**, the runtime yt-dlp
supports, unpacked into `/usr/local/bin/deno` from the official
`deno-x86_64-unknown-linux-gnu.zip` release.

It is pinned twice, by `ARG DENO_VERSION` and by `ARG DENO_ZIP_SHA256`: the binary
comes from outside the distro's package signing, so an unverified "latest" would be
neither reproducible nor checkable. To move to a new deno, bump both — the checksum
is published next to the zip as `.sha256sum`. The build unpacks it with the Python
already in the base image (no build-only apt packages) and runs `deno --version`,
which fails the build if the binary is wrong. The binary is 96 MB, and that is
what it adds to the image.

The JavaScript yt-dlp feeds to deno ships as **yt-dlp-ejs**, pulled in by the
`[default]` extra rather than pinned here: its version has to match what the
installed yt-dlp pins, so letting the extra resolve it is what keeps the two in step.

```powershell
ssh YOUR_USER@YOUR_SERVER_IP "cd /opt/prisma && docker compose exec -T backend deno --version"
```

## Why yt-dlp is updated at every container start

`pip install -U 'yt-dlp[default]'` runs in `CMD`, before uvicorn. A pinned yt-dlp
silently rots, so the tradeoff is deliberate: slightly slower starts and a dependency on
outbound network at boot, in exchange for not waking up to a download pipeline that
broke because a pin went stale. A failed update is logged and tolerated rather than
fatal, and the version actually in use is always visible at `/health`.
