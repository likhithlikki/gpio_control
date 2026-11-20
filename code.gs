/**
 * Internet GPIO controller - Google Apps Script backend.
 * Deploy as Web app: Execute as = Me, Who has access = Anyone.
 *
 * Database = a Google Sheet. Its ID is read from Script Properties (key: SHEET_ID).
 * If the property is missing, DEFAULT_SHEET_ID below is used.
 *   Sheet "History": time + desired/actual of every pin. A row is written on every change
 *                    and also every SNAPSHOT_EVERY_MS as a heartbeat.
 *   Sheet "State"  : always the latest values, one row per pin.
 *   Sheet "Log"    : event log (set, actual, board online, board start).
 * All times in the sheets are IST, 12-hour with AM/PM, e.g. 20-Nov-2026 11:24:05 PM
 *
 * Board API (plain text, called with GET):  ?action=poll | report   (&key=SECRET)
 * Page API (google.script.run):             webStatus(key), webSetPin(key, id, value)
 * Also reachable over HTTP for testing:     ?action=status | setPin&pin=ID&value=0|1
 */

/* ===================== CONFIG ===================== */
const SECRET = '12345';   // must match KEY in /etc/gpio-agent.conf
const DEFAULT_SHEET_ID = '1wsmtaFpyFbFDpd7pPB5M8zRsZH4BtZWYR0QshaumFxE';

const PINS = [
  { id: 'sys_led',  name: 'System LED', gpio: 8,  dir: 'out', led: 'sys_led'  },
  { id: 'usr_led',  name: 'User LED',   gpio: 54, dir: 'out', led: 'usr_led'  },
  { id: 'usr_gpio', name: 'User GPIO',  gpio: 55, dir: 'out', led: 'usr_gpio' },
];

const OFFLINE_MS        = 10000;   // no report for this long => board offline
const GRACE_MS          = 10000;   // "Pending" may last this long before "Mismatch"
const SNAPSHOT_EVERY_MS = 300000;  // heartbeat row in History every 5 min even if nothing changed
const MAX_ROWS          = 5000;    // trim History / Log above this
const TZ                = 'Asia/Kolkata';
const TIME_FMT          = 'dd-MMM-yyyy hh:mm:ss a';   // 12-hour with AM/PM
/* ================================================== */

const CACHE_TTL = 21600; // 6 h (CacheService maximum)

/* ---------- storage helpers: Cache = fast, Properties = durable ---------- */
function load_(key, durable) {
  const cache = CacheService.getScriptCache();
  const hit = cache.get(key);
  if (hit) return JSON.parse(hit);
  if (durable) {
    const p = PropertiesService.getScriptProperties().getProperty(key);
    if (p) { cache.put(key, p, CACHE_TTL); return JSON.parse(p); }
  }
  return null;
}
function save_(key, obj, durable) {
  const s = JSON.stringify(obj);
  CacheService.getScriptCache().put(key, s, CACHE_TTL);
  if (durable) PropertiesService.getScriptProperties().setProperty(key, s);
}

/* ---------- time (IST, AM/PM) ---------- */
function ist_(ms) {
  return Utilities.formatDate(ms ? new Date(ms) : new Date(), TZ, TIME_FMT);
}

/* ---------- Google Sheet database ---------- */
let ssCache_ = null;
function ss_() {
  if (ssCache_) return ssCache_;
  const id = PropertiesService.getScriptProperties().getProperty('SHEET_ID') || DEFAULT_SHEET_ID;
  ssCache_ = SpreadsheetApp.openById(id);
  return ssCache_;
}

function sheet_(name, header) {
  const ss = ss_();
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  const cur = sh.getLastRow() > 0 ? sh.getRange(1, 1, 1, header.length).getValues()[0] : [];
  if (cur.join('|') !== header.join('|')) {
    sh.getRange(1, 1, 1, header.length).setValues([header]);
    sh.setFrozenRows(1);
  }
  return sh;
}

// append a row; column A (time) is kept as plain text so Sheets does not reformat it
function addRow_(sh, row) {
  const r = sh.getLastRow() + 1;
  sh.getRange(r, 1).setNumberFormat('@');
  sh.getRange(r, 1, 1, row.length).setValues([row]);
}

function trim_(sh) {
  if (sh.getLastRow() > MAX_ROWS) sh.deleteRows(2, 1000);
}

function historyHeader_() {
  const h = ['Time (IST)', 'Source'];
  PINS.forEach(function (p) { h.push(p.id + ' desired'); h.push(p.id + ' actual'); });
  return h;
}

/* Event log */
function log_(event, pin, value, source) {
  try {
    const sh = sheet_('Log', ['Time (IST)', 'Event', 'Pin', 'Value', 'Source']);
    addRow_(sh, [ist_(), event, pin, value, source]);
    trim_(sh);
  } catch (err) { /* logging must never break the API */ }
}

/* Snapshot of all pins at this moment: one History row + refresh of the State sheet.
   d = desired map {id:{v,t}}, actual = map {id:'0'|'1'|'E'} */
function snapshot_(source, d, actual) {
  try {
    d = d || {}; actual = actual || {};

    const hs = sheet_('History', historyHeader_());
    const row = [ist_(), source];
    PINS.forEach(function (p) {
      row.push(p.dir === 'out' ? (d[p.id] ? d[p.id].v : 0) : '');
      row.push(actual[p.id] !== undefined ? actual[p.id] : '');
    });
    addRow_(hs, row);
    trim_(hs);

    const st = sheet_('State', ['Pin', 'Name', 'GPIO', 'Dir', 'Desired', 'Actual', 'Updated (IST)']);
    const rows = PINS.map(function (p) {
      return [
        p.id, p.name, p.gpio, p.dir,
        p.dir === 'out' ? (d[p.id] ? d[p.id].v : 0) : '',
        actual[p.id] !== undefined ? actual[p.id] : '',
        ist_()
      ];
    });
    st.getRange(2, 7, Math.max(st.getMaxRows() - 1, 1), 1).setNumberFormat('@');
    st.getRange(2, 1, rows.length, 7).setValues(rows);
  } catch (err) { /* never break the API */ }
}

/** Run once from the editor: creates the sheets with headers. */
function initSheets() {
  sheet_('History', historyHeader_());
  sheet_('State', ['Pin', 'Name', 'GPIO', 'Dir', 'Desired', 'Actual', 'Updated (IST)']);
  sheet_('Log', ['Time (IST)', 'Event', 'Pin', 'Value', 'Source']);
  const rep = load_('rep', false);
  snapshot_('init', load_('desired', true) || {}, rep && rep.s ? rep.s : {});
}

function pinById_(id) { return PINS.find(function (p) { return p.id === id; }); }

/* ---------- core API (private: trailing underscore => not callable from the browser) ---------- */
function setPin_(id, value, source) {
  const pin = pinById_(id);
  if (!pin) return { ok: false, error: 'unknown pin' };
  if (pin.dir !== 'out') return { ok: false, error: 'pin is not an output' };
  const sv = String(value);
  if (sv !== '0' && sv !== '1') return { ok: false, error: 'value must be 0 or 1' };
  const v = Number(sv);
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);
  try {
    const d = load_('desired', true) || {};
    if (!d[id] || d[id].v !== v) {
      d[id] = { v: v, t: Date.now() };
      save_('desired', d, true);
      log_('set', id, v, source || 'web');
      const rep = load_('rep', false);
      snapshot_(source || 'web', d, rep && rep.s ? rep.s : {});
    }
  } finally { lock.releaseLock(); }
  return { ok: true };
}

// Board asks what to do. Plain text, easy to parse in sh:
//   OK
//   TIME|2026-11-20 17:35:00        (UTC on purpose: the board sets its clock with date -u)
//   P|id|gpio|dir|wanted|led        (wanted is empty for inputs)
function poll_(boot) {
  let d = load_('desired', true) || {};
  if (boot) { // board just (re)started: it forces all outputs LOW, so make the record match
    const lock = LockService.getScriptLock();
    lock.waitLock(5000);
    try {
      d = load_('desired', true) || {};
      const now = Date.now();
      PINS.forEach(function (p) { if (p.dir === 'out') d[p.id] = { v: 0, t: now }; });
      save_('desired', d, true);
      log_('board start', 'all outputs', 0, 'board');
      snapshot_('board start', d, {});
    } finally { lock.releaseLock(); }
  }
  const lines = ['OK', 'TIME|' + Utilities.formatDate(new Date(), 'UTC', 'yyyy-MM-dd HH:mm:ss')];
  PINS.forEach(function (p) {
    const want = p.dir === 'out' ? (d[p.id] ? d[p.id].v : 0) : '';
    lines.push(['P', p.id, p.gpio, p.dir, want, p.led || ''].join('|'));
  });
  return lines.join('\n');
}

// Board reports what it really read: "id:0,id:1,id:E" (E = the board could not drive/read the pin)
function report_(s) {
  const now = Date.now();
  const prev = load_('rep', false);
  const cur = {};
  String(s || '').split(',').forEach(function (kv) {
    const i = kv.indexOf(':');
    if (i < 1) return;
    const id = kv.slice(0, i), v = kv.slice(i + 1);
    if (pinById_(id) && /^[01E]$/.test(v)) cur[id] = v;
  });

  if (!prev || now - prev.t > OFFLINE_MS) log_('board online', '', '', 'board');

  let changed = !prev || !prev.s;
  Object.keys(cur).forEach(function (id) {
    if (!prev || !prev.s || prev.s[id] !== cur[id]) {
      changed = true;
      log_('actual', id, cur[id], 'board');
    }
  });

  save_('rep', { t: now, s: cur }, false); // cache only: written every cycle, not worth Properties

  // History row + State refresh: on any change, and as a heartbeat every SNAPSHOT_EVERY_MS
  const last = load_('snap', false);
  if (changed || !last || now - last.t >= SNAPSHOT_EVERY_MS) {
    snapshot_('board', load_('desired', true) || {}, cur);
    save_('snap', { t: now }, false);
  }
  return 'OK';
}

function status_() {
  const now = Date.now();
  const d = load_('desired', true) || {};
  const rep = load_('rep', false);
  const online = !!rep && (now - rep.t) <= OFFLINE_MS;
  const pins = PINS.map(function (p) {
    const a = rep && rep.s && rep.s[p.id] !== undefined ? rep.s[p.id] : null;
    const o = { id: p.id, name: p.name, gpio: p.gpio, dir: p.dir, desired: null, actual: a, state: 'pending', detail: '' };
    if (p.dir === 'in') {
      if (a === 'E') { o.state = 'error'; o.detail = 'board could not read pin'; }
      else if (online && a !== null) o.state = 'input';
      return o;
    }
    const want = d[p.id] ? d[p.id].v : 0;
    const t = d[p.id] ? d[p.id].t : 0;
    o.desired = want;
    if (!online) { o.detail = 'board offline'; }
    else if (a === null) { o.detail = 'waiting for board'; }
    else if (a === 'E') { o.state = 'error'; o.detail = 'board could not drive pin'; }
    else if (Number(a) === want) { o.state = 'confirmed'; }
    else if (now - t > GRACE_MS) { o.state = 'error'; o.detail = 'mismatch'; }
    else { o.detail = 'waiting for board'; }
    return o;
  });
  return {
    ok: true, online: online,
    seenAgo: rep ? Math.round((now - rep.t) / 1000) : null,
    seenAt: rep ? ist_(rep.t) : null,
    now: ist_(),
    pins: pins
  };
}

/* ---------- functions the page may call (key required) ---------- */
function webStatus(key) {
  return key === SECRET ? status_() : { ok: false, error: 'badkey' };
}
function webSetPin(key, id, value) {
  return key === SECRET ? setPin_(id, value, 'web') : { ok: false, error: 'badkey' };
}

/* ---------- HTTP layer ---------- */
function text_(s) { return ContentService.createTextOutput(s); }
function json_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }

function api_(p) {
  if (!p.key || p.key !== SECRET) {
    return (p.action === 'poll' || p.action === 'report') ? text_('ERR|badkey') : json_({ ok: false, error: 'badkey' });
  }
  switch (p.action) {
    case 'poll':   return text_(poll_(p.boot === '1'));
    case 'report': return text_(report_(p.s));
    case 'setPin': return json_(setPin_(p.pin, p.value, 'http'));
    case 'status': return json_(status_());
    default:       return json_({ ok: false, error: 'unknown action' });
  }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.action) return api_(p);
  return HtmlService.createHtmlOutputFromFile('Index')
    .setTitle('GPIO Controller')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

function doPost(e) { return api_((e && e.parameter) || {}); }

/** Run this once from the editor (Run button) to grant permissions before deploying. */
function authorizeOnce() {
  ss_();                       // needs Google Sheets permission
  PropertiesService.getScriptProperties();
  CacheService.getScriptCache();
  LockService.getScriptLock();
}
