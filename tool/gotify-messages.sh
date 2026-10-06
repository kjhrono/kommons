#!/usr/bin/env bash
# gotify-messages.sh — audit recent Gotify deliveries without Docker access.
#
# Reads the Gotify SQLite database directly and prints the most recent
# messages with their title, priority, application and age.  It needs only
# read access to the database file: no `docker` command, no root, no HTTP
# credentials, no Gotify admin login.  On the monitoring VM the database is
# world-readable, so the audit runs from any shell:
#
#   ssh -i <key> ubuntu@vm-kjhrono '~/bin/gotify-messages.sh -n 10'
#
# Why not the HTTP API: this Gotify (2.9.1) only exposes /message and
# /health through its proxy — /api/messages, /api/clients, /api/apps and
# /api/config all return 404 — so the database is the only queryable record
# of what was delivered.  A row here means "the alert reached Gotify";
# Gotify keeps no per-device delivery acknowledgement.
#
# The database is opened read-only (`mode=ro`) so the audit never locks or
# mutates the live file.  If it cannot be opened read-only (for example a
# WAL database on a read-only filesystem), the script snapshots the file
# and its -wal/-shm sidecars to a temp directory and reads that copy.
# Requires python3 (the stdlib sqlite3 module is enough; the sqlite3 CLI is
# not installed on the VM).
#
# Configuration (env):
#   GOTIFY_DB   path to gotify.db (default: $HOME/gotify/data/gotify.db)
#
# Usage:
#   gotify-messages.sh [-n N] [filters] [--json|--counts|--count]
#
# Options:
#   -n, --limit N        show at most N messages (default 20; 0 = all)
#   -p, --priority LIST  only these priorities, comma-separated (e.g. 5,8)
#       --min-priority N only messages with priority >= N
#   -a, --app NAME       only this application (e.g. jwt-alerts)
#   -t, --title TEXT     only titles containing TEXT (case-insensitive)
#   -s, --since MINUTES  only messages delivered in the last MINUTES
#       --since-hours N  only messages delivered in the last N hours
#   -m, --message        also print each message body
#   -j, --json           emit a JSON array instead of the table
#       --counts         aggregate: totals by priority/app, newest, oldest
#       --count          print only the number of matching messages
#       --age-seconds    print the age in seconds of the newest matching
#                        message, or -1 when none match (ignores --limit)
#       --report         alert-history report over the selected range: which
#                        monitor fires most, how each monitor compares with the
#                        preceding window of the same length (rose/fell), volume
#                        over time, and breakdowns by priority and application
#                        (ignores --limit)
#       --db PATH        database path (overrides GOTIFY_DB)
#   -h, --help           show this help and exit
#
# Exit status: 0 success (also when nothing matches), 1 database or runtime
# error, 2 usage error.
set -euo pipefail

LIMIT=20
PRIORITIES=""
MIN_PRIORITY=""
APP=""
TITLE=""
SINCE=""
SINCE_HOURS=""
SHOW_MESSAGE=""
OUT_JSON=""
OUT_COUNTS=""
OUT_COUNT=""
OUT_AGE=""
OUT_REPORT=""
DB="${GOTIFY_DB:-$HOME/gotify/data/gotify.db}"

usage_error() { echo "gotify-messages: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--limit)          [ "$#" -ge 2 ] || usage_error "--limit needs a value"; LIMIT="$2"; shift 2 ;;
    -p|--priority)       [ "$#" -ge 2 ] || usage_error "--priority needs a value"; PRIORITIES="$2"; shift 2 ;;
    --min-priority)      [ "$#" -ge 2 ] || usage_error "--min-priority needs a value"; MIN_PRIORITY="$2"; shift 2 ;;
    -a|--app)            [ "$#" -ge 2 ] || usage_error "--app needs a value"; APP="$2"; shift 2 ;;
    -t|--title)          [ "$#" -ge 2 ] || usage_error "--title needs a value"; TITLE="$2"; shift 2 ;;
    -s|--since)          [ "$#" -ge 2 ] || usage_error "--since needs a value"; SINCE="$2"; shift 2 ;;
    --since-hours)       [ "$#" -ge 2 ] || usage_error "--since-hours needs a value"; SINCE_HOURS="$2"; shift 2 ;;
    -m|--message)        SHOW_MESSAGE=1; shift ;;
    -j|--json)           OUT_JSON=1; shift ;;
    --counts)            OUT_COUNTS=1; shift ;;
    --count)             OUT_COUNT=1; shift ;;
    --age-seconds)       OUT_AGE=1; shift ;;
    --report)            OUT_REPORT=1; shift ;;
    --db)                [ "$#" -ge 2 ] || usage_error "--db needs a value"; DB="$2"; shift 2 ;;
    -h|--help)           sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *)                   usage_error "unknown option: $1" ;;
  esac
done

for num in "$LIMIT" "$SINCE" "$SINCE_HOURS" "$MIN_PRIORITY"; do
  [ -z "$num" ] && continue
  case "$num" in *[!0-9]*) usage_error "expected a non-negative integer, got '$num'" ;; esac
done
if [ -n "$PRIORITIES" ]; then
  case "$PRIORITIES" in *[!0-9,]*) usage_error "--priority must be a comma-separated list of integers" ;; esac
fi

# --since-hours is a convenience alias for --since; it wins when both are given.
if [ -n "$SINCE_HOURS" ]; then
  SINCE=$((SINCE_HOURS * 60))
fi

modes=0
[ -n "$OUT_JSON" ]   && modes=$((modes + 1))
[ -n "$OUT_COUNTS" ] && modes=$((modes + 1))
[ -n "$OUT_COUNT" ]  && modes=$((modes + 1))
[ -n "$OUT_AGE" ]    && modes=$((modes + 1))
[ -n "$OUT_REPORT" ] && modes=$((modes + 1))
[ "$modes" -le 1 ] || usage_error "--json, --counts, --count, --age-seconds and --report are mutually exclusive"

[ -e "$DB" ] || { echo "gotify-messages: database not found: $DB" >&2; exit 1; }
[ -r "$DB" ] || { echo "gotify-messages: database not readable: $DB (check file permissions)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "gotify-messages: python3 is required" >&2; exit 1; }

export GM_DB="$DB"
export GM_LIMIT="$LIMIT"
export GM_PRIORITIES="$PRIORITIES"
export GM_MIN_PRIORITY="$MIN_PRIORITY"
export GM_APP="$APP"
export GM_TITLE="$TITLE"
export GM_SINCE="$SINCE"
export GM_MESSAGE="${SHOW_MESSAGE:-}"
export GM_JSON="${OUT_JSON:-}"
export GM_COUNTS="${OUT_COUNTS:-}"
export GM_COUNT="${OUT_COUNT:-}"
export GM_AGE="${OUT_AGE:-}"
export GM_REPORT="${OUT_REPORT:-}"

exec python3 - <<'PY'
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import urllib.parse
from datetime import datetime, timedelta, timezone

PROG = "gotify-messages"


def die(msg, code=1):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(code)


db_path = os.environ["GM_DB"]
limit = int(os.environ["GM_LIMIT"])
priorities = [int(x) for x in os.environ.get("GM_PRIORITIES", "").split(",") if x.strip()]
min_priority = os.environ.get("GM_MIN_PRIORITY", "")
app = os.environ.get("GM_APP", "")
title = os.environ.get("GM_TITLE", "")
since_min = os.environ.get("GM_SINCE", "")
as_json = os.environ.get("GM_JSON") == "1"
as_counts = os.environ.get("GM_COUNTS") == "1"
as_count = os.environ.get("GM_COUNT") == "1"
as_age = os.environ.get("GM_AGE") == "1"
as_report = os.environ.get("GM_REPORT") == "1"
show_message = os.environ.get("GM_MESSAGE") == "1"


def open_db():
    """Return (connection, mode).  Prefers a read-only in-place open."""
    uri = "file:%s?mode=ro" % urllib.parse.quote(os.path.abspath(db_path))
    try:
        con = sqlite3.connect(uri, uri=True, timeout=5)
        con.execute("select 1 from messages limit 1")
        return con, "live"
    except sqlite3.Error:
        pass
    # Fallback for databases that must be opened read-write (e.g. WAL mode on
    # a read-only filesystem): work on a snapshot copy of the file + sidecars.
    try:
        tmp = tempfile.mkdtemp(prefix="gotify-audit.")
        base = os.path.basename(db_path)
        for suffix in ("", "-wal", "-shm"):
            src = db_path + suffix
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(tmp, base + suffix))
        con = sqlite3.connect(os.path.join(tmp, base), timeout=5)
        con.execute("select 1 from messages limit 1")
        return con, "snapshot"
    except (sqlite3.Error, OSError) as exc:
        die(f"cannot read {db_path}: {exc}")


con, mode = open_db()

where, params = [], []
if priorities:
    where.append("m.priority in (%s)" % ",".join("?" * len(priorities)))
    params += priorities
if min_priority:
    where.append("m.priority >= ?")
    params.append(int(min_priority))
if app:
    where.append("a.name = ?")
    params.append(app)
if title:
    where.append("lower(m.title) like lower(?)")
    params.append(f"%{title}%")
if since_min:
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=int(since_min)))
    where.append("m.date >= ?")
    params.append(cutoff.strftime("%Y-%m-%d %H:%M:%S+00:00"))

sql = (
    "select m.id, m.date, m.priority, coalesce(a.name, '(unknown)'), "
    "m.title, m.message from messages m "
    "left join applications a on a.id = m.application_id"
)
if where:
    sql += " where " + " and ".join(where)
sql += " order by m.date desc, m.id desc"
if as_age:
    sql += " limit 1"
elif not as_report and limit > 0:
    sql += " limit ?"
    params.append(limit)

try:
    rows = con.execute(sql, params).fetchall()
    total = con.execute("select count(*) from messages").fetchone()[0]
    oldest = con.execute("select min(date) from messages").fetchone()[0]
except sqlite3.Error as exc:
    die(f"query failed: {exc}")

now = datetime.now(timezone.utc)


def parse_date(value):
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(.*)$", value.strip())
    if not m:
        return None
    frac = (m.group(3) or "0")[:6].ljust(6, "0")
    iso = f"{m.group(1)}T{m.group(2)}.{frac}{m.group(4) or ''}"
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# The oldest message on record.  A window reaching further back than this is
# only partly covered, and the comparison below must say so rather than report
# the unrecorded part of the preceding window as zero alerts.
history_start = parse_date(oldest) if oldest else None


def human_duration(seconds):
    secs = max(0, int(seconds))
    if secs < 60:
        return f"{secs}s"
    mins, secs = divmod(secs, 60)
    hours, mins = divmod(mins, 60)
    days, hours = divmod(hours, 24)
    if days:
        return f"{days}d{hours:02d}h"
    if hours:
        return f"{hours}h{mins:02d}m"
    return f"{mins}m"


def human_age(dt):
    if dt is None:
        return "?"
    return human_duration((now - dt).total_seconds())


def monitor_of(title):
    """The monitor that raised an alert: the title before its host suffix.

    Alert titles read "<monitor> — <host>", so the part before the dash
    identifies the firing monitor.
    """
    for sep in (" \u2014 ", " \u2013 ", " - "):
        if sep in title:
            return title.split(sep, 1)[0].strip()
    return title.strip()


def bucket_minutes_for(span_minutes):
    """Bucket width that keeps a report to a readable number of rows."""
    if span_minutes <= 180:
        return 15
    if span_minutes <= 2880:
        return 60
    if span_minutes <= 43200:
        return 1440
    return 10080


def bucket_name(minutes):
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 1440:
        return f"{minutes // 60}h"
    if minutes == 1440:
        return "daily"
    return "weekly"


def bucket_stamp(when, minutes):
    if minutes < 1440:
        return when.strftime("%Y-%m-%d %H:%M")
    if minutes == 1440:
        return when.strftime("%Y-%m-%d")
    return "week of " + when.strftime("%Y-%m-%d")


def align_to_bucket(when, minutes):
    """Snap a timestamp down to its wall-clock bucket boundary.

    Buckets are anchored to the clock rather than to the range start, so
    labels read as natural boundaries ("18:00") instead of odd offsets
    inherited from whenever the range happened to begin ("17:46").
    """
    epoch_minutes = int(when.timestamp()) // 60
    aligned = epoch_minutes - epoch_minutes % minutes
    return datetime.fromtimestamp(aligned * 60, tz=timezone.utc)


def date_param(when):
    """Render a datetime the way the stored `date` text is written.

    The date column is compared as text, so this must match Gotify's own
    format — the same one the --since filter already relies on.
    """
    return when.strftime("%Y-%m-%d %H:%M:%S+00:00")


def monitor_counts_between(start, end):
    """Per-monitor alert counts in [start, end), under the same filters.

    monitor_of() runs in Python over the title, so the grouping cannot happen
    in SQL; only the date range and the other filters are pushed down.
    """
    where2, params2 = [], []
    if priorities:
        where2.append("m.priority in (%s)" % ",".join("?" * len(priorities)))
        params2 += priorities
    if min_priority:
        where2.append("m.priority >= ?")
        params2.append(int(min_priority))
    if app:
        where2.append("a.name = ?")
        params2.append(app)
    if title:
        where2.append("lower(m.title) like lower(?)")
        params2.append(f"%{title}%")
    where2.append("m.date >= ?")
    params2.append(date_param(start))
    where2.append("m.date < ?")
    params2.append(date_param(end))

    sql2 = (
        "select m.title from messages m "
        "left join applications a on a.id = m.application_id "
        "where " + " and ".join(where2)
    )
    counts = {}
    try:
        for (row_title,) in con.execute(sql2, params2):
            name = monitor_of(row_title)
            counts[name] = counts.get(name, 0) + 1
    except sqlite3.Error as exc:
        die(f"query failed: {exc}")
    return counts


def render_monitor_trend(monitors, prev_counts, previous_start, previous_end, span_seconds):
    """Compare this window's per-monitor counts with the preceding window's.

    The bars under "Volume over time" show the shape of the alert stream but
    not its direction, and shape alone cannot say whether a monitor is getting
    noisier — which is what an operator acts on.  The `trend:` line is liftable
    by callers, the way `busiest:` already is.
    """
    names = sorted(set(monitors) | set(prev_counts))
    moved = [(n, monitors.get(n, 0), prev_counts.get(n, 0)) for n in names]
    # Biggest mover first: the direction of the trend is the story here.
    moved.sort(key=lambda row: (-abs(row[1] - row[2]), row[0]))

    cur_total = sum(monitors.values())
    prev_total = sum(prev_counts.values())

    print()
    print("By monitor vs previous window")
    print(
        "  Previous: %s \u2192 %s UTC  (%s)"
        % (
            previous_start.strftime("%Y-%m-%d %H:%M"),
            previous_end.strftime("%Y-%m-%d %H:%M"),
            human_duration(span_seconds),
        )
    )
    if history_start is not None and history_start > previous_start:
        print(
            "  (partly covered: this history begins %s UTC)"
            % history_start.strftime("%Y-%m-%d %H:%M")
        )
    for name, cur, prev in moved:
        delta = cur - prev
        mark = "\u25b2" if delta > 0 else ("\u25bc" if delta < 0 else "=")
        print(f"  {name:<34}  {prev:>4} \u2192 {cur:>4}  {delta:+d}  {mark}")

    rose = sum(1 for _, cur, prev in moved if cur > prev)
    fell = sum(1 for _, cur, prev in moved if cur < prev)
    flat = sum(1 for _, cur, prev in moved if cur == prev)
    if not moved:
        tally = "no monitor fired in either window"
    else:
        tally = f"{rose} rose, {fell} fell"
        if flat:
            tally += f", {flat} flat"
    if cur_total > prev_total:
        direction = "up"
    elif cur_total < prev_total:
        direction = "down"
    else:
        direction = "flat"
    if cur_total == prev_total:
        change = "no change"
    elif prev_total == 0:
        change = "from none"
    else:
        change = "%+d%%" % round((cur_total - prev_total) / prev_total * 100)
    print(f"  trend: {direction} {prev_total} \u2192 {cur_total} ({change}) \u2014 {tally}")


def render_report():
    valid = sorted(
        ((parse_date(r[1]), r) for r in rows if parse_date(r[1]) is not None),
        key=lambda item: item[0],
    )

    if since_min:
        range_start = now - timedelta(minutes=int(since_min))
        range_end = now
    elif valid:
        range_start, range_end = valid[0][0], valid[-1][0]
    else:
        range_start = range_end = now

    span_minutes = max(0.0, (range_end - range_start).total_seconds() / 60.0)
    width = bucket_minutes_for(span_minutes)

    print("Gotify alert report")
    print(
        "Range:   %s \u2192 %s UTC  (%s)"
        % (
            range_start.strftime("%Y-%m-%d %H:%M"),
            range_end.strftime("%Y-%m-%d %H:%M"),
            human_duration(span_minutes * 60),
        )
    )
    print(f"Matched: {len(rows)} of {total} message(s) in the database")

    # Per-monitor counts, from the rows this report already selected.
    monitors = {}
    for _, row in valid:
        name = monitor_of(row[4])
        monitors[name] = monitors.get(name, 0) + 1

    # The window to mirror: the same length immediately before this one.
    span_seconds = max(0.0, (range_end - range_start).total_seconds())

    if not valid:
        print()
        print("No messages matched the filters.")
        # Silence is only informative against what came before it, so still
        # state the direction when the preceding window had alerts.
        if span_seconds > 0:
            previous_end = range_start
            previous_start = range_start - timedelta(seconds=span_seconds)
            prev_counts = monitor_counts_between(previous_start, previous_end)
            if prev_counts:
                render_monitor_trend(
                    monitors, prev_counts, previous_start, previous_end, span_seconds
                )
        return

    # --- which monitor fires most ---
    ranked = sorted(monitors.items(), key=lambda kv: (-kv[1], kv[0]))
    print()
    print("By monitor (fires most first)")
    for name, count in ranked:
        print(f"  {count:>5}  {name}")
    if len(ranked) == 1 or ranked[0][1] > ranked[1][1]:
        print(f"  busiest: {ranked[0][0]} ({ranked[0][1]})")
    else:
        # Reporting one monitor as "busiest" on a tie would be arbitrary.
        tied = sum(1 for _, count in ranked if count == ranked[0][1])
        print(f"  busiest: no clear leader \u2014 {tied} monitors tied at {ranked[0][1]}")

    # --- the same breakdown, against the preceding window ---
    if span_seconds > 0:
        previous_end = range_start
        previous_start = range_start - timedelta(seconds=span_seconds)
        prev_counts = monitor_counts_between(previous_start, previous_end)
        render_monitor_trend(
            monitors, prev_counts, previous_start, previous_end, span_seconds
        )

    # --- volume over time ---
    grid_start = align_to_bucket(range_start, width)
    bucket_seconds = width * 60
    counts = {}
    for when, _ in valid:
        idx = max(0, int((when - grid_start).total_seconds() // bucket_seconds))
        counts[idx] = counts.get(idx, 0) + 1
    last_idx = int((range_end - grid_start).total_seconds() // bucket_seconds)
    indices = list(range(0, max(last_idx, max(counts)) + 1))

    print()
    print(f"Volume over time ({bucket_name(width)} buckets, UTC)")
    if len(indices) > 60:
        print("  (empty buckets omitted)")
        indices = [i for i in indices if counts.get(i)]
    labels = [
        bucket_stamp(grid_start + timedelta(minutes=width * i), width) for i in indices
    ]
    label_width = max(len(lab) for lab in labels)
    peak = max(counts.values())
    bar_width = 40
    for k, idx in enumerate(indices):
        count = counts.get(idx, 0)
        # 1 cell minimum for a non-empty bucket so a lone delivery stays visible
        bar = "#" * max(1, round(count / peak * bar_width)) if count else ""
        print(f"  {labels[k]:<{label_width}}  {bar:<{bar_width}}  {count:>3}")
    peak_idx = max(counts, key=lambda idx: (counts[idx], -idx))
    print(
        "  peak: %s (%d)"
        % (
            bucket_stamp(grid_start + timedelta(minutes=width * peak_idx), width),
            counts[peak_idx],
        )
    )

    # --- breakdowns ---
    print()
    print("By priority")
    per_priority = {}
    for _, row in valid:
        per_priority[row[2]] = per_priority.get(row[2], 0) + 1
    for pri in sorted(per_priority):
        print(f"  {pri:>5}  x{per_priority[pri]}")

    print()
    print("By app")
    per_app = {}
    for _, row in valid:
        per_app[row[3]] = per_app.get(row[3], 0) + 1
    for name in sorted(per_app):
        print(f"  {name}  x{per_app[name]}")


if as_age:
    if not rows:
        print(-1)
    else:
        newest_date = parse_date(rows[0][1])
        print(-1 if newest_date is None else max(0, int((now - newest_date).total_seconds())))
    sys.exit(0)

if as_report:
    render_report()
    sys.exit(0)

if as_count:
    print(len(rows))
    sys.exit(0)

if as_json:
    out = [
        {
            "id": r[0],
            "date": r[1],
            "priority": r[2],
            "app": r[3],
            "title": r[4],
            "message": r[5],
        }
        for r in rows
    ]
    print(json.dumps(out, indent=2, ensure_ascii=False))
    sys.exit(0)

if as_counts:
    print(f"total: {len(rows)} message(s) matched (database holds {total})")
    if rows:
        per_priority = {}
        per_app = {}
        for r in rows:
            per_priority[r[2]] = per_priority.get(r[2], 0) + 1
            per_app[r[3]] = per_app.get(r[3], 0) + 1
        print("by priority:")
        for pri in sorted(per_priority):
            print(f"  {pri:>3}  x{per_priority[pri]}")
        print("by app:")
        for name in sorted(per_app):
            print(f"  {name}  x{per_app[name]}")
        newest, oldest = rows[0], rows[-1]
        print(f"newest: {newest[1][:19]}  id={newest[0]} pri={newest[2]} age={human_age(parse_date(newest[1]))}  {newest[4]}")
        print(f"oldest: {oldest[1][:19]}  id={oldest[0]} pri={oldest[2]} age={human_age(parse_date(oldest[1]))}  {oldest[4]}")
    sys.exit(0)

if not rows:
    print(f"{PROG}: no messages matched", file=sys.stderr)
    sys.exit(0)

def clip(value, width):
    value = " ".join(value.split())
    return value if len(value) <= width else value[: width - 1] + "…"

TITLE_WIDTH = 60
header = ("ID", "PRI", "AGE", "DELIVERED (UTC)", "APP", "TITLE")
body = [
    (
        str(r[0]),
        str(r[2]),
        human_age(parse_date(r[1])),
        r[1][:19],
        r[3],
        clip(r[4], TITLE_WIDTH),
    )
    for r in rows
]
widths = [max(len(header[i]), *(len(row[i]) for row in body)) for i in range(len(header))]
line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(header))
print(line.rstrip())
print("  ".join("-" * widths[i] for i in range(len(header))))
for idx, row in enumerate(body):
    print("  ".join(row[i].ljust(widths[i]) for i in range(len(header))).rstrip())
    if show_message:
        for text_line in rows[idx][5].splitlines() or [""]:
            print(f"      | {text_line}")

print(f"-- {len(rows)} of {total} message(s) in {db_path} [{mode} read]", file=sys.stderr)
PY
