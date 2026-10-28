# KRBC reservation server: handoff notes

This folder is the backend for the KRBC (Karnataka Bird Count) grid map. It was
written in another Claude Code session on the maintainer's laptop and copied here.
Your job on this server is to get it running at a public **https** URL and verify it.

## The project

- **Map:** https://birdcountindia.github.io/krbc-grids/ (GitHub Pages)
- **Repo:** https://github.com/birdcountindia/krbc-grids (branch `master`). This
  folder is `krbc-server/` in that repo.
- Karnataka is divided into 5 x 5 km grid cells named by district (`Udupi_14`).
  The map shows cells with no eBird checklists so volunteers can survey them.
- Volunteers sign in with their **name and eBird profile ID**, reserve cells, mark
  them surveyed, and download their cells as KML. The map calls `krbc-api.php` here
  for all of that. Until the map knows this server's URL, it runs without sign-in.

A Google Apps Script backend was tried first and dropped: the NCF Google Workspace
does not allow public web apps (every deployment returned 401 or a sign-in page).
Don't suggest going back to it.

## Files

| File | Purpose |
|---|---|
| `krbc-api.php` | The whole API. Single PHP file, PHP 7.4+, no dependencies or database. |
| `start.sh` | Runs it with PHP's built-in server on port 8080 (`PORT=... sh start.sh`). Only for servers with no Apache/nginx PHP setup. |
| `.htaccess` | Apache: blocks `krbc-data*` files and folder listing. |
| `README.md` | Human setup guide (option A: existing PHP web server; option B: `start.sh` behind an https proxy such as Caddy). |

Created at runtime, next to `krbc-api.php`:

- `krbc-data.php`: all users and reservations, as JSON after a first line
  `<?php exit; ?>`, so requesting it over the web returns nothing.
- `krbc-data.tmp.php`: written during each save, then renamed over the data file.
- `krbc-data.php.lock`: `flock` target so requests are handled one at a time.

## What to do

1. Work out how this server serves websites (Apache/nginx with PHP, a control panel
   like cPanel, or nothing). Prefer the existing web server (README option A); use
   `start.sh` behind an https reverse proxy only if there is none (option B).
2. Make sure PHP can write to this folder. Saving fails with "could not be saved"
   otherwise.
3. Verify from outside the server, using the real public URL:

   ```sh
   URL=https://example.org/krbc-server/krbc-api.php

   # Running: expect {"ok":false,"error":"Bad request"}
   curl -s "$URL"

   # Answers the map, with CORS: expect {"ok":true,"reservations":[]} and an
   # access-control-allow-origin: https://birdcountindia.github.io header
   curl -si -X POST -H 'Origin: https://birdcountindia.github.io' \
        --data '{"action":"state"}' "$URL"

   # Data file is private: expect an empty body, a 403, or (with start.sh) the
   # "Bad request" message. Never names, profile IDs or "users"
   curl -s "${URL%krbc-api.php}krbc-data.php"
   ```

   The POST test doesn't create anything. Don't leave test sign-ins or reservations
   in the live data; if you add any, delete `krbc-data.php` before handing over (it
   is recreated on the next sign-in).
4. Hand over the working https URL. The map is connected by setting it in
   `config.js` at the repo root, then committing and pushing to `master`:

   ```js
   window.KRBC_BACKEND = 'https://example.org/krbc-server/krbc-api.php';
   ```

   If this server has push access to the repo, you can do that; otherwise give the
   URL to the maintainer.

## Constraints

- **https is required.** The map is served over https, so browsers block calls to an
  http API.
- **Keep the data private.** `krbc-data.php` holds names and eBird profile IDs. Never
  serve it, commit it or paste its contents anywhere. The API itself only returns
  usernames and reservation status.
- **Allowed origins:** `ALLOWED_ORIGINS` at the top of `krbc-api.php` lists the sites
  allowed to call the API (only `https://birdcountindia.github.io`). Add another only
  if the maintainer asks, e.g. a local test address.
- **Rules are agreed with the maintainer; don't change them without asking:** a
  person is identified by eBird profile ID and must use the same name each time;
  usernames are unique (a new person whose name is taken picks one); up to 3 people
  per cell (`MAX_PER_CELL`); up to 50 cells per person not yet marked surveyed
  (`MAX_PER_USER`). There are no passwords, by design.
- Back up `krbc-data.php` now and then; it is the only copy of the reservations.

## API reference

One endpoint. `POST` a JSON body (sent as `text/plain` by the map, so browsers skip
the CORS preflight; `OPTIONS` is answered anyway). Every response is JSON with `ok`.

| `action` | Other fields | Returns |
|---|---|---|
| `state` | none | `reservations: [{cell, user, status}]` |
| `login` | `name`, `profileId` (ID or full eBird profile link), optional `username` | state plus `user: {name, username, profileId}`; `created: true` for a new sign-up; `needUsername: true` with an error when the name is taken |
| `reserve`, `release`, `done`, `undone` | `name`, `profileId`, `cell` (grid key `"i_j"`), `cellName`, `district` | state, or `ok: false` with `error` |

`cell` is the cell's grid indices, which stay the same when the map data is
refreshed; `cellName` and `district` are stored only as labels.

## Testing

The API was tested on PHP 8.3 (via php-wasm) with 27 checks covering sign-in,
usernames, both limits, release and mark surveyed, CORS, and that the data and temp
files can't be read over the web. It hasn't been run on this server yet. For a quick
local check: `sh start.sh`, then run the curl commands above against
`http://localhost:8080/krbc-api.php`.
