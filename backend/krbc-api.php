<?php
// KRBC grid reservations API, called by the map page on GitHub Pages.
// Setup steps are in backend/README.md.

// Sites allowed to call this API
const ALLOWED_ORIGINS = ['https://birdcountindia.github.io'];

// Names and eBird profile IDs are kept here. The file starts with a PHP line that
// stops it running, so it can't be downloaded even though it sits next to this one.
const DATA_FILE = __DIR__ . '/krbc-data.php';
const DATA_HEADER = "<?php exit; ?>\n";

const MAX_PER_CELL = 3;   // people per cell
const MAX_PER_USER = 50;  // cells per person not yet marked surveyed

$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if (in_array($origin, ALLOWED_ORIGINS, true)) {
    header('Access-Control-Allow-Origin: ' . $origin);
    header('Vary: Origin');
}
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    header('Access-Control-Allow-Methods: POST');
    header('Access-Control-Allow-Headers: Content-Type');
    exit;
}

$p = json_decode(file_get_contents('php://input'), true);
if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !is_array($p)) {
    respond(fail('Bad request'));
}

// One request at a time, so simultaneous clicks can't get past the limits
$lock = fopen(DATA_FILE . '.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX)) {
    respond(fail('The server is busy. Try again.'));
}
$db = load();
respond(handle($p, $db));


function handle(array $p, array &$db): array {
    switch ($p['action'] ?? '') {
        case 'state':
            return state($db);
        case 'login':
            return login($p, $db);
        case 'reserve':
        case 'release':
        case 'done':
        case 'undone':
            return change($p, $db);
        default:
            return fail('Unknown action.');
    }
}

// Sign in, or sign up on first visit. The eBird profile ID identifies a person;
// the username is what others see, and must be unique.
function login(array $p, array &$db): array {
    $name = clean($p['name'] ?? '', 60);
    $pid = profile_id($p['profileId'] ?? '');
    $wanted = clean($p['username'] ?? '', 30);
    if ($name === '') return fail('Enter your name.');
    if ($pid === null) return fail('Enter a valid eBird profile ID.');

    $now = date('c');
    if (isset($db['users'][$pid])) {
        $u = &$db['users'][$pid];
        if (lower($u['name']) !== lower($name)) {
            return fail('This eBird profile ID is registered under a different name. Use the same name as last time.');
        }
        $u['last_login'] = $now;
        save($db);
        return state($db) + ['user' => ['name' => $u['name'], 'username' => $u['username'], 'profileId' => $pid]];
    }

    if ($wanted !== '' && !preg_match('/^[A-Za-z0-9 ._-]{3,30}$/', $wanted)) {
        return fail('Usernames are 3 to 30 letters, numbers, spaces, dots, dashes or underscores.', true);
    }
    $username = $wanted !== '' ? $wanted : $name;
    foreach ($db['users'] as $u) {
        if (lower($u['username']) === lower($username)) {
            return fail($wanted !== ''
                ? 'That username is taken. Try another.'
                : 'Someone with this name has already signed up. Choose a username so people can tell you apart.', true);
        }
    }
    $db['users'][$pid] = ['name' => $name, 'username' => $username, 'created' => $now, 'last_login' => $now];
    save($db);
    return state($db) + ['created' => true,
                         'user' => ['name' => $name, 'username' => $username, 'profileId' => $pid]];
}

function change(array $p, array &$db): array {
    $pid = profile_id($p['profileId'] ?? '');
    if ($pid === null || !isset($db['users'][$pid])
        || lower($db['users'][$pid]['name']) !== lower(clean($p['name'] ?? '', 60))) {
        return fail('Please sign in again.');
    }
    $cell = (string)($p['cell'] ?? '');
    if (!preg_match('/^-?\d+_-?\d+$/', $cell)) return fail('Unknown cell.');

    $onCell = 0;
    $mine = null;
    $active = 0;
    foreach ($db['reservations'] as $x => $r) {
        if ($r['cell'] === $cell) {
            $onCell++;
            if ($r['profile_id'] === $pid) $mine = $x;
        }
        if ($r['profile_id'] === $pid && $r['status'] !== 'done') $active++;
    }

    $now = date('c');
    if ($p['action'] === 'reserve') {
        if ($mine !== null) return fail('You have already reserved this cell.');
        if ($onCell >= MAX_PER_CELL) return fail('This cell already has ' . MAX_PER_CELL . ' people.');
        if ($active >= MAX_PER_USER) {
            return fail('You already have ' . MAX_PER_USER . ' cells. Release some or mark them surveyed first.');
        }
        $db['reservations'][] = [
            'cell' => $cell,
            'cell_name' => clean($p['cellName'] ?? '', 60),
            'district' => clean($p['district'] ?? '', 60),
            'profile_id' => $pid,
            'status' => 'reserved',
            'reserved_at' => $now,
            'updated_at' => $now,
        ];
    } elseif ($mine === null) {
        return fail('You have not reserved this cell.');
    } elseif ($p['action'] === 'release') {
        array_splice($db['reservations'], $mine, 1);
    } else {
        $db['reservations'][$mine]['status'] = $p['action'] === 'done' ? 'done' : 'reserved';
        $db['reservations'][$mine]['updated_at'] = $now;
    }
    save($db);
    return state($db);
}

// Who has reserved which cell. Only usernames go out, never profile IDs.
function state(array $db): array {
    $out = [];
    foreach ($db['reservations'] as $r) {
        $out[] = ['cell' => $r['cell'], 'user' => $db['users'][$r['profile_id']]['username'] ?? '?',
                  'status' => $r['status']];
    }
    return ['ok' => true, 'reservations' => $out];
}


function load(): array {
    $empty = ['users' => [], 'reservations' => []];
    if (!is_file(DATA_FILE)) return $empty;
    $raw = file_get_contents(DATA_FILE);
    if (strncmp($raw, DATA_HEADER, strlen(DATA_HEADER)) === 0) $raw = substr($raw, strlen(DATA_HEADER));
    $db = json_decode($raw, true);
    if (!is_array($db)) respond(fail('The reservation data could not be read.'));
    return $db + $empty;
}

// Write a new copy, then swap it in, so a failed write never leaves a broken file
function save(array $db): void {
    $tmp = DATA_FILE . '.tmp';
    $json = json_encode($db, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if (file_put_contents($tmp, DATA_HEADER . $json) === false || !rename($tmp, DATA_FILE)) {
        respond(fail('The reservation could not be saved. Check that the folder is writable.'));
    }
}

// Accepts a bare ID or a full profile link like https://ebird.org/profile/MjYxNjIwMg/world
function profile_id($s): ?string {
    $s = trim((string)$s);
    if (preg_match('~profile/([^/?#\s]+)~', $s, $m)) $s = $m[1];
    return preg_match('/^[A-Za-z0-9_-]{3,64}$/', $s) ? $s : null;
}

function clean($s, int $max): string {
    $s = trim(preg_replace('/\s+/u', ' ', (string)$s) ?? '');
    return function_exists('mb_substr') ? mb_substr($s, 0, $max) : substr($s, 0, $max);
}

function lower(string $s): string {
    return function_exists('mb_strtolower') ? mb_strtolower($s) : strtolower($s);
}

function fail(string $error, bool $needUsername = false): array {
    return ['ok' => false, 'error' => $error] + ($needUsername ? ['needUsername' => true] : []);
}

function respond(array $o): void {
    echo json_encode($o, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
