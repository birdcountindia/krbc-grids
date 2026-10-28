# KRBC reservation server

Copy this whole folder to the server. It handles sign-ins and cell reservations
for the map on GitHub Pages.

| File | What it is |
|---|---|
| `krbc-api.php` | The API. This is the file the map calls. |
| `start.sh` | Starts the API with PHP's built-in server. Only for option B below. |
| `.htaccess` | Keeps the data private on Apache servers. Hidden on most systems; copy it too. |

The data is saved in `krbc-data.php`, created here on the first sign-in.

## Option A: the server already runs PHP websites (Apache or nginx)

Nothing needs to be run.

1. Copy this folder into the website's public folder, e.g. as `krbc-server/`.
2. Open `https://your-domain/krbc-server/krbc-api.php` in a browser. You should see
   `{"ok":false,"error":"Bad request"}`.
3. Send that URL to be added to `config.js` in the repo.

If reserving later fails with "could not be saved", let PHP write to the folder:
`chmod 775 krbc-server` (or set 775 in the host's file manager).

## Option B: a server without a web server for PHP

1. Install PHP 7.4 or newer (`sudo apt install php-cli` on Ubuntu/Debian).
2. Run `sh start.sh` in this folder. The API listens on port 8080.
3. Open `http://your-server:8080/krbc-api.php` to check for
   `{"ok":false,"error":"Bad request"}`.
4. The map needs https. Put the API behind an https proxy, e.g. Caddy with this
   `Caddyfile`, which gets a certificate automatically:

   ```
   api.your-domain.org {
       reverse_proxy localhost:8080
   }
   ```

   The URL to use is then `https://api.your-domain.org/krbc-api.php`.
5. To keep it running after logout and restarts, run `start.sh` as a service
   (systemd, or `pm2 start start.sh`).

PHP's built-in server handles one request at a time, which is fine for a volunteer
group; option A is better if the server has Apache or nginx.

## Settings

At the top of `krbc-api.php`:

- `ALLOWED_ORIGINS`: sites that may call the API (the GitHub Pages site).
- `MAX_PER_CELL`: people per cell (3).
- `MAX_PER_USER`: cells per person not yet marked surveyed (50).

## The data

`krbc-data.php` holds JSON after a first line that stops it running, so visiting it
shows a blank page and names and eBird profile IDs can't be downloaded. Back it up
now and then with the host's file manager or FTP.

- **users:** keyed by eBird profile ID, with name, username, first and last sign-in.
- **reservations:** cell key (grid indices), cell name, district, eBird profile ID,
  status (`reserved` or `done`) and timestamps.

The map only ever receives usernames and reservation status.

## Rules

- A person is identified by their eBird profile ID and must sign in with the same
  name each time.
- Usernames are what others see. A new person whose name is taken picks a username.
- Up to 3 people per cell; up to 50 unsurveyed cells per person.

There are no passwords. Anyone who knows someone's name and eBird profile ID can
sign in as them, so this suits a volunteer effort, not anything sensitive.
