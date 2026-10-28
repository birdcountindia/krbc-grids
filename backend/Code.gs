// KRBC grid reservations: Google Apps Script web app backed by this spreadsheet.
// Setup steps are in backend/README.md.

const USERS = 'Users';
const RESERVATIONS = 'Reservations';
const MAX_PER_CELL = 3;   // people per cell
const MAX_PER_USER = 50;  // cells per person not yet marked surveyed

const USER_COLS = ['profile_id', 'name', 'username', 'created', 'last_login'];
const RES_COLS = ['cell_key', 'cell_name', 'district', 'username', 'profile_id',
                  'status', 'reserved_at', 'updated_at'];

// Run once from the Apps Script editor to create the two tabs
function setup() {
  const ss = SpreadsheetApp.getActive();
  sheet_(ss, USERS, USER_COLS);
  sheet_(ss, RESERVATIONS, RES_COLS);
}

function doGet(e) {
  return json_(handle_((e && e.parameter) || {}));
}

function doPost(e) {
  let body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return json_({ ok: false, error: 'Bad request' });
  }
  return json_(handle_(body));
}

function handle_(p) {
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
    switch (p.action) {
      case 'state': return Object.assign({ ok: true }, state_());
      case 'login': return login_(p);
      case 'reserve':
      case 'release':
      case 'done':
      case 'undone': return change_(p);
      default: return { ok: false, error: 'Unknown action' };
    }
  } catch (err) {
    return { ok: false, error: String(err.message || err) };
  } finally {
    lock.releaseLock();
  }
}

// Sign in, or sign up on first visit. The eBird profile ID identifies a person;
// the username is what others see, and must be unique.
function login_(p) {
  const name = clean_(p.name, 60);
  const profileId = profileId_(p.profileId);
  const wanted = clean_(p.username, 30);
  if (!name) return fail_('Enter your name.');
  if (!profileId) return fail_('Enter a valid eBird profile ID.');

  const sh = sheet_(SpreadsheetApp.getActive(), USERS, USER_COLS);
  const rows = sh.getDataRange().getValues();
  for (let r = 1; r < rows.length; r++) {
    if (String(rows[r][0]) !== profileId) continue;
    if (norm_(rows[r][1]) !== norm_(name)) {
      return fail_('This eBird profile ID is registered under a different name. Use the same name as last time.');
    }
    sh.getRange(r + 1, 5).setValue(new Date());
    return withState_({ user: { name: rows[r][1], username: rows[r][2], profileId: profileId } });
  }

  if (wanted && !/^[A-Za-z0-9 ._-]{3,30}$/.test(wanted)) {
    return Object.assign(fail_('Usernames are 3 to 30 letters, numbers, spaces, dots, dashes or underscores.'),
                         { needUsername: true });
  }
  const username = wanted || name;
  for (let r = 1; r < rows.length; r++) {
    if (norm_(rows[r][2]) === norm_(username)) {
      return Object.assign(fail_(wanted
        ? 'That username is taken. Try another.'
        : 'Someone with this name has already signed up. Choose a username so people can tell you apart.'),
        { needUsername: true });
    }
  }
  const now = new Date();
  sh.appendRow([profileId, name, username, now, now]);
  return withState_({ user: { name: name, username: username, profileId: profileId }, created: true });
}

function change_(p) {
  const user = auth_(p);
  if (!user) return fail_('Please sign in again.');
  const key = String(p.cell || '');
  if (!/^-?\d+_-?\d+$/.test(key)) return fail_('Unknown cell.');

  const sh = sheet_(SpreadsheetApp.getActive(), RESERVATIONS, RES_COLS);
  const rows = sh.getDataRange().getValues();
  let onCell = 0, myRow = -1, myActive = 0;
  for (let r = 1; r < rows.length; r++) {
    const mine = String(rows[r][4]) === user.profileId;
    if (String(rows[r][0]) === key) {
      onCell++;
      if (mine) myRow = r;
    }
    if (mine && rows[r][5] !== 'done') myActive++;
  }

  const now = new Date();
  if (p.action === 'reserve') {
    if (myRow >= 0) return fail_('You have already reserved this cell.');
    if (onCell >= MAX_PER_CELL) return fail_('This cell already has ' + MAX_PER_CELL + ' people.');
    if (myActive >= MAX_PER_USER) {
      return fail_('You already have ' + MAX_PER_USER + ' cells. Release some or mark them surveyed first.');
    }
    sh.appendRow([key, clean_(p.cellName, 60), clean_(p.district, 60), user.username,
                  user.profileId, 'reserved', now, now]);
  } else {
    if (myRow < 0) return fail_('You have not reserved this cell.');
    if (p.action === 'release') {
      sh.deleteRow(myRow + 1);
    } else {
      sh.getRange(myRow + 1, 6).setValue(p.action === 'done' ? 'done' : 'reserved');
      sh.getRange(myRow + 1, 8).setValue(now);
    }
  }
  return withState_({});
}

function auth_(p) {
  const profileId = profileId_(p.profileId);
  if (!profileId) return null;
  const rows = sheet_(SpreadsheetApp.getActive(), USERS, USER_COLS).getDataRange().getValues();
  for (let r = 1; r < rows.length; r++) {
    if (String(rows[r][0]) === profileId && norm_(rows[r][1]) === norm_(p.name)) {
      return { profileId: profileId, username: String(rows[r][2]) };
    }
  }
  return null;
}

// Public state: who has reserved which cell. Profile IDs are never sent out.
function state_() {
  const rows = sheet_(SpreadsheetApp.getActive(), RESERVATIONS, RES_COLS).getDataRange().getValues();
  const reservations = [];
  for (let r = 1; r < rows.length; r++) {
    reservations.push({ cell: String(rows[r][0]), user: String(rows[r][3]), status: String(rows[r][5]) });
  }
  return { reservations: reservations };
}

function withState_(o) {
  return Object.assign({ ok: true }, o, state_());
}

function sheet_(ss, name, cols) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  if (sh.getLastRow() === 0) {
    sh.appendRow(cols);
    sh.setFrozenRows(1);
    // Keep IDs and cell keys as text so Sheets doesn't reformat them
    sh.getRange('A:A').setNumberFormat('@');
    if (name === RESERVATIONS) sh.getRange('E:E').setNumberFormat('@');
  }
  return sh;
}

// Accepts a bare ID or a full profile link like https://ebird.org/profile/MjYxNjIwMg/world
function profileId_(s) {
  s = String(s || '').trim();
  const m = s.match(/profile\/([^/?#\s]+)/);
  if (m) s = m[1];
  return /^[A-Za-z0-9_-]{3,64}$/.test(s) ? s : '';
}

function clean_(s, max) {
  return String(s || '').replace(/\s+/g, ' ').trim().slice(0, max);
}

function norm_(s) {
  return clean_(s, 100).toLowerCase();
}

function fail_(error) {
  return { ok: false, error: error };
}

function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
