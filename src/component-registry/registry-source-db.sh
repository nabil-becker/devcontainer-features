#!/usr/bin/env bash
# registry-source-db: the component registry's `db` source. A layer is the rows a query returns
# from a database, rendered into one .layer file in the layer copy. Review and release are the
# database owner's; the registry only pins what to read and how to log in. Installed on PATH by
# the component-registry Feature; dcf-registry calls it.
#
#   registry-source-db fetch <layer> <dest> driver=<d> <connection> (table=|query=)<x> [auth.secret=...]
#                                         the rendered rows into <dest>/<layer>.layer (and, for a
#                                         text value that is not one plain line, <dest>/text/<n>.txt)
#   registry-source-db version <layer> driver=<d> ...
#                                         sha256 of the rendered files (the query runs, nothing is kept)
#   registry-source-db supports           the verbs it implements
#
# Drivers: sqlite (path=<file>) and postgres (host, port, database, user, sslmode; the password is
# auth.secret, a dcf-secret name). Any other driver: exit 3. The client is the CLI on PATH, sqlite3
# or psql, never installed by this Feature; absent, the source says how to install it (exit 1).
#
# Rows: table=<name> reads "SELECT section, key, type, data, locked FROM <name> ORDER BY section,
# key"; query=<select> is a single SELECT (or WITH) statement whose result has those five column
# names, in the order it returns them. section is a [path] (without the brackets), key and type
# (value, list, text, ref) make "key:type = data", locked (1, t, true, yes) adds "lock key".
# All five are read as hex (so a newline or a tab in data cannot change the shape of the file) and
# every row is checked: ONE bad row, or no rows at all, fails the fetch (exit 1) with the reason
# and nothing is written, so resolve keeps the last good copy rather than a layer with a lock
# silently missing. The database is opened read-only (sqlite -readonly, postgres read-only
# transaction); a query may not hold a semicolon (one statement).
#
# Secret: the postgres password is read with dcf-secret and handed to psql in its own environment
# (PGPASSWORD), never an argument, never a file, never logged; the connection itself goes through
# PGHOST, PGPORT, PGDATABASE, PGUSER and PGSSLMODE, so psql's command line holds nothing but flags.
# Without dcf-secret on PATH the source says so and goes on without a password.
#
# Test hook: REGISTRY_SOURCE_DB_CONNECT_TIMEOUT (seconds, default 10).
#
# Exit: 0 done, 1 failed (unreachable, query error, bad rows, no client), 2 bad use, 3 not supported.
set -uo pipefail

die() { local rc="$1"; shift; printf 'registry-source-db: %s\n' "$*" >&2; exit "$rc"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  supports) printf 'fetch\nversion\nsupports\n'; exit 0 ;;
  fetch) [ $# -ge 2 ] || die 2 "usage: fetch <layer> <dest> driver=<d> ..."; layer="$1" dest="$2"; shift 2 ;;
  version) [ $# -ge 1 ] || die 2 "usage: version <layer> driver=<d> ..."; layer="$1"; shift ;;
  '') die 2 "usage: registry-source-db fetch|version|supports ..." ;;
  *) die 3 "verb '$verb' is not supported (fetch, version, supports)" ;;
esac

driver='' path='' host='' port='' database='' duser='' sslmode='' table='' query='' asecret=''
for kv in "$@"; do
  case "$kv" in
    driver=*) driver="${kv#driver=}" ;;
    path=*) path="${kv#path=}" ;;
    host=*) host="${kv#host=}" ;;
    port=*) port="${kv#port=}" ;;
    database=*) database="${kv#database=}" ;;
    user=*) duser="${kv#user=}" ;;
    sslmode=*) sslmode="${kv#sslmode=}" ;;
    table=*) table="${kv#table=}" ;;
    query=*) query="${kv#query=}" ;;
    auth.secret=*) asecret="${kv#auth.secret=}" ;;
    allow-insecure=*) die 2 "layer $layer: a db source has no allow-insecure (set sslmode for postgres)" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (driver, path, host, port, database, user, sslmode, table, query, auth.secret)" ;;
  esac
done

case "$driver" in
  sqlite | postgres) ;;
  '') die 2 "layer $layer: a db source needs driver (sqlite or postgres)" ;;
  *) die 3 "layer $layer: driver '$driver' is not supported (sqlite, postgres)" ;;
esac
if [ -n "$table" ] && [ -n "$query" ]; then die 2 "layer $layer: give table or query, not both"; fi
[ -n "$table" ] || [ -n "$query" ] || die 2 "layer $layer: a db source needs table or query"
if [ -n "$table" ]; then
  [[ "$table" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$ ]] || die 2 "layer $layer: table '$table' is not a table name (letters, digits, _, one optional schema.)"
  query="SELECT section, key, type, data, locked FROM $table ORDER BY section, key"
fi
case "$query" in
  *\;*) die 2 "layer $layer: the query may not hold a semicolon (one statement)" ;;
  *[[:cntrl:]]*) die 2 "layer $layer: the query may not hold a control character" ;;
esac
shopt -s nocasematch
[[ "$query" =~ ^[[:space:]]*(select|with)[[:space:]] ]] || die 2 "layer $layer: the query must be a SELECT (or WITH) statement"
shopt -u nocasematch

case "$driver" in
  sqlite)
    [ -n "$path" ] || die 2 "layer $layer: a sqlite source needs path"
    [ -z "$host$port$database$duser$sslmode$asecret" ] || die 2 "layer $layer: a sqlite source takes path only (the file's own permissions are its log-in)"
    command -v sqlite3 >/dev/null 2>&1 || die 1 "layer $layer: sqlite3 is not installed (apt-get install sqlite3); this Feature does not add it"
    [ -f "$path" ] || die 1 "layer $layer: the sqlite file $path does not exist" ;;
  postgres)
    [ -z "$path" ] || die 2 "layer $layer: a postgres source takes host, port, database, user, sslmode and auth.secret, not path"
    [ -n "$host" ] && [ -n "$database" ] && [ -n "$duser" ] || die 2 "layer $layer: a postgres source needs host, database and user"
    [[ "$host" =~ ^[A-Za-z0-9._:/-]+$ ]] || die 2 "layer $layer: host '$host' holds a character a host name does not"
    port="${port:-5432}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die 2 "layer $layer: port must be a number"
    [[ "$database" =~ ^[A-Za-z0-9._$-]+$ ]] || die 2 "layer $layer: database '$database' holds a character a database name does not"
    [[ "$duser" =~ ^[A-Za-z0-9._@$-]+$ ]] || die 2 "layer $layer: user '$duser' holds a character a user name does not"
    case "${sslmode:-prefer}" in disable | allow | prefer | require | verify-ca | verify-full) ;; *) die 2 "layer $layer: sslmode is disable, allow, prefer, require, verify-ca or verify-full" ;; esac
    command -v psql >/dev/null 2>&1 || die 1 "layer $layer: psql is not installed (apt-get install postgresql-client); this Feature does not add it" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

pw=''
if [ "$driver" = postgres ] && [ -n "$asecret" ]; then
  if ! command -v dcf-secret >/dev/null 2>&1; then
    echo "registry-source-db: layer $layer: auth.secret is set but dcf-secret (the openbao Feature) is not installed; reading without a password" >&2
  else
    pw="$(dcf-secret get "$asecret")" || die 1 "layer $layer: dcf-secret could not read $asecret (exit $?)"
  fi
fi

# The five columns as hex, one row per line, fields split by |: the shape cannot be broken by data.
if [ "$driver" = sqlite ]; then
  sql="SELECT hex(CAST(coalesce(\"section\",'') AS TEXT)), hex(CAST(coalesce(\"key\",'') AS TEXT)), hex(CAST(coalesce(\"type\",'') AS TEXT)), hex(CAST(coalesce(\"data\",'') AS TEXT)), hex(CAST(coalesce(\"locked\",'') AS TEXT)) FROM (
$query
) AS q"
else
  hx() { printf "encode(convert_to(coalesce(q.\"%s\"::text,''),'UTF8'),'hex')" "$1"; }
  sql="SELECT $(hx section) || '|' || $(hx key) || '|' || $(hx type) || '|' || $(hx data) || '|' || $(hx locked) FROM (
$query
) AS q"
fi

# run_query: the rows into $tmp/rows, or the failure said (client's first line of error)
run_query() {
  local rc
  if [ "$driver" = sqlite ]; then
    sqlite3 -readonly -batch -separator '|' "$path" "$sql" >"$tmp/rows" 2>"$tmp/err"; rc=$?
  else
    # the password lives in this subshell's environment and psql's: not in an argument, not exported on
    ( export PGHOST="$host" PGPORT="$port" PGDATABASE="$database" PGUSER="$duser" PGSSLMODE="${sslmode:-prefer}" \
        PGCONNECT_TIMEOUT="${REGISTRY_SOURCE_DB_CONNECT_TIMEOUT:-10}" PGOPTIONS='-c default_transaction_read_only=on' PGPASSFILE=/dev/null
      [ -z "$pw" ] || export PGPASSWORD="$pw"
      printf '%s\n' "$sql" | psql -X -q -w -A -t -v ON_ERROR_STOP=1 -f - ) >"$tmp/rows" 2>"$tmp/err"; rc=$?
  fi
  [ "$rc" -eq 0 ] || die 1 "layer $layer: the $driver query failed (exit $rc): $(grep -m 1 . "$tmp/err")"
}

# unhex <hex>: the bytes, into UNHEXED (a trailing sentinel keeps trailing newlines)
unhex() {
  local h="$1" fmt
  UNHEXED=''
  [ -n "$h" ] || return 0
  [[ "$h" =~ ^([0-9A-Fa-f]{2})+$ ]] || return 1
  fmt="$(printf '%s' "$h" | sed 's/../\\x&/g')"
  # shellcheck disable=SC2059  # the format holds only \xNN escapes made from hex digits
  UNHEXED="$(printf "${fmt}x")"; UNHEXED="${UNHEXED%x}"
}

# render: rows -> $tmp/out/<layer>.layer (+ text/<n>.txt), or die with the first bad row's reason
render() {
  local sec key typ dat lck n=0 prev=$'\x01' entry nt=0 f
  mkdir -p "$tmp/out"
  : > "$tmp/out/$layer.layer"
  while IFS='|' read -r sec key typ dat lck _ || [ -n "$sec" ]; do
    n=$((n + 1))
    for f in sec key typ dat lck; do
      unhex "${!f}" || die 1 "layer $layer: row $n: column $f is not readable (the client's output was not what the query asked for)"
      printf -v "$f" '%s' "$UNHEXED"
    done
    [[ "$sec" =~ ^!?/?[A-Za-z0-9_.*/-]+$ ]] || die 1 "layer $layer: row $n: section '$sec' is not a path (letters, digits, . _ - / and the wildcards * **, an optional leading !)"
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || die 1 "layer $layer: row $n ([$sec]): key '$key' is empty or holds a character a key does not"
    case "$typ" in value | list | text | ref) ;; *) die 1 "layer $layer: row $n ([$sec] $key): type '$typ' is not value, list, text or ref" ;; esac
    case "${lck,,}" in 1 | t | true | yes | y) lck=1 ;; 0 | f | false | no | n | '') lck=0 ;; *) die 1 "layer $layer: row $n ([$sec] $key): locked '$lck' is not 1, 0, true or false" ;; esac
    case "$sec" in !*) die 1 "layer $layer: row $n: an exclusion section ([$sec]) takes no entries" ;; esac
    if [ "$typ" = text ]; then
      # one plain line goes in the .layer; anything else (a newline, a leading @ or edge blanks) in a file
      if [[ "$dat" == *$'\n'* || "$dat" == *$'\r'* || "$dat" == @* || "$dat" == [[:space:]]* || "$dat" == *[[:space:]] ]]; then
        nt=$((nt + 1)); mkdir -p "$tmp/out/text"
        printf '%s' "$dat" > "$tmp/out/text/$nt.txt"
        entry="$key:text = @file text/$nt.txt"
      else
        entry="$key:text = $dat"
      fi
    else
      [[ "$dat" != *$'\n'* && "$dat" != *$'\r'* ]] || die 1 "layer $layer: row $n ([$sec] $key): a $typ value is one line; data holds a line break (only text may)"
      [[ "$dat" != @* ]] || die 1 "layer $layer: row $n ([$sec] $key): data may not start with @"
      entry="$key:$typ = $dat"
    fi
    if [ "$sec" != "$prev" ]; then
      [ "$n" -eq 1 ] || printf '\n' >> "$tmp/out/$layer.layer"
      printf '[%s]\n' "$sec" >> "$tmp/out/$layer.layer"; prev="$sec"
    fi
    printf '%s\n' "$entry" >> "$tmp/out/$layer.layer"
    [ "$lck" -eq 0 ] || printf 'lock %s\n' "$key" >> "$tmp/out/$layer.layer"
  done < "$tmp/rows"
  [ "$n" -gt 0 ] || die 1 "layer $layer: the query returned no rows"
}

run_query
render

case "$verb" in
  version)
    # the .layer then each text file in name order, so a change in either is another version
    printf 'sha256:%s\n' "$({ cat "$tmp/out/$layer.layer"; [ ! -d "$tmp/out/text" ] || find "$tmp/out/text" -type f | LC_ALL=C sort | while read -r f; do printf '\0%s\0' "${f#"$tmp/out/"}"; cat "$f"; done; } | sha256sum | cut -d' ' -f1)" ;;
  fetch)
    [ -d "$dest" ] || die 2 "layer $layer: the destination $dest is not a folder"
    cp -R "$tmp/out/." "$dest/" || die 1 "layer $layer: could not write into $dest" ;;
esac
exit 0
