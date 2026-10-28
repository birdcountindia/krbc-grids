# Reservation backend

Sign-ins and cell reservations are handled by `krbc-api.php`, a single PHP file on
our own server. The map page on GitHub Pages calls it.

## Setup (once)

1. Make a folder on the server for the backend, for example `krbc/` inside the
   website's public folder, so that it is reachable at
   `https://your-domain/krbc/`.
2. Upload `krbc-api.php` into that folder.
3. Make sure PHP can write to the folder. On most hosts this works as is; if
   saving fails, set the folder's permissions to 755 (or 775) in the file manager.
4. Check it: open `https://your-domain/krbc/krbc-api.php` in a browser. You should
   see `{"ok":false,"error":"Bad request"}`. That means it is running.
5. Put the URL in `config.js` in this repo, then commit and push:

   ```js
   window.KRBC_BACKEND = 'https://your-domain/krbc/krbc-api.php';
   ```

The site must use https, because the map page does.

## Where the data is

Everything is saved in `krbc-data.php`, created next to `krbc-api.php` on the first
sign-in. Despite the name it is a data file: JSON after a first line that stops it
running. Visiting it in a browser shows a blank page, so names and eBird profile IDs
can't be downloaded. To read or back it up, download it with the host's file manager
or FTP.

- **users:** keyed by eBird profile ID, with name, username, first and last sign-in.
- **reservations:** cell key (grid indices), cell name, district, eBird profile ID,
  status (`reserved` or `done`) and timestamps.

The page only ever receives usernames and reservation status.

`krbc-data.php.lock` is used to handle one request at a time; leave it in place.

## Rules

- A person is identified by their eBird profile ID, and must sign in with the same
  name each time.
- Usernames are what others see. A new person whose name is already taken is asked
  to pick a different username.
- Up to 3 people can reserve a cell (`MAX_PER_CELL`).
- A person can hold up to 50 cells not yet marked surveyed (`MAX_PER_USER`).
- Only pages on `https://birdcountindia.github.io` can call the API
  (`ALLOWED_ORIGINS`).

The limits and allowed sites are set at the top of `krbc-api.php`.

There are no passwords. Anyone who knows someone's name and eBird profile ID can
sign in as them, so this suits a volunteer effort, not anything sensitive.
