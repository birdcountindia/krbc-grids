# Reservation backend

Sign-ins and cell reservations are stored in a Google Sheet. A Google Apps Script
attached to the sheet serves them to the map page.

## Setup (once)

1. Create a new Google Sheet, e.g. **KRBC grid reservations**, in the Google account
   that should own the data.
2. In the sheet, open **Extensions → Apps Script**. Delete the starter code and paste
   in everything from `Code.gs`. Save.
3. In the editor's function menu, choose `setup` and click **Run**. Approve the
   permissions it asks for. The sheet now has two tabs, `Users` and `Reservations`.
4. Click **Deploy → New deployment**. Choose the type **Web app**, and set:
   - **Execute as:** Me
   - **Who has access:** Anyone
5. Click **Deploy** and copy the **Web app URL** (it ends in `/exec`).
6. Paste that URL into `config.js` in this repo:

   ```js
   window.KRBC_BACKEND = 'https://script.google.com/macros/s/.../exec';
   ```

   Commit and push. The page now asks people to sign in.

After changing `Code.gs` later, use **Deploy → Manage deployments → Edit → New
version** so the same URL keeps working.

## What is stored

- **Users:** eBird profile ID, name, username, first sign-in and last sign-in.
- **Reservations:** one row per person per cell, with the cell key (grid indices),
  cell name, district, username, eBird profile ID, status (`reserved` or `done`)
  and timestamps.

The page only ever receives usernames and reservation status. Names and eBird
profile IDs stay in the sheet.

## Rules

- A person is identified by their eBird profile ID, and must sign in with the same
  name each time.
- Usernames are what others see. A new person whose name is already taken is
  asked to pick a different username.
- Up to 3 people can reserve a cell.
- A person can hold up to 50 cells that are not yet marked surveyed.

There are no passwords. Anyone who knows someone's name and eBird profile ID can
sign in as them, so this suits a volunteer effort, not anything sensitive.
