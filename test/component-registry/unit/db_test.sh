#!/usr/bin/env bash
# Docker-free tests of the component-registry `db` source (src/component-registry/
# registry-source-db.sh). sqlite: a real SQLite database (made with python3's sqlite3 module) read
# through a `sqlite3` command line that is a thin python3 shim, because the repository's test images
# do not carry the sqlite3 CLI (the real one is used when it is on PATH). postgres: a stub `psql`
# that records its arguments, its PG* environment and the SQL it was sent, and answers with canned
# rows or an error. Covers the connection keys, the password (read with a stub dcf-secret, in the
# child's environment only, never in an argument, the output or any process list), a query error,
# an empty result, each bad row refused with its reason, a text value with a newline, the version
# (a hash of the rendered files), an unsupported driver (exit 3), a missing client, and through
# dcf-registry resolve: a layer from a database and the last good copy when the database is gone.
# Part of `task lint` (`task test:component-registry-unit`). Needs python3; skipped without.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"
if ! command -v python3 >/dev/null; then echo "skip - python3 is needed"; exit 0; fi

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin" "$T/stubs"
for f in dcf-registry registry-source-db registry-source-path registry-source-git; do cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"; done
SECRET='pg-s3cret-VALUE-77'
# shellcheck disable=SC2016  # the stub expands them when it runs
printf '#!/bin/sh\n[ "$1" = get ] && [ "$2" = registry/db ] && { printf "%%s\\n" "%s"; exit 0; }\necho "not found" >&2; exit 1\n' "$SECRET" > "$bin/dcf-secret"
chmod +x "$bin/dcf-secret"

# The sqlite3 shim (only when the real CLI is absent): -readonly, -separator, path, one SQL argument.
if command -v sqlite3 >/dev/null 2>&1; then have_real=yes; else
  have_real=no
  cat > "$bin/sqlite3" <<'PY'
#!/usr/bin/env python3
import sqlite3, sys
a = sys.argv[1:]; ro = False; sep = '|'; pos = []
i = 0
while i < len(a):
    if a[i] == '-readonly': ro = True
    elif a[i] == '-batch': pass
    elif a[i] == '-separator': i += 1; sep = a[i]
    else: pos.append(a[i])
    i += 1
db = sqlite3.connect('file:%s?mode=%s' % (pos[0], 'ro' if ro else 'rw'), uri=True)
try:
    for row in db.execute(pos[1]): print(sep.join('' if c is None else str(c) for c in row))
except sqlite3.Error as e:
    print('Error: ' + str(e), file=sys.stderr); sys.exit(1)
PY
  chmod +x "$bin/sqlite3"
fi
export PATH="$bin:$PATH"

# The stub psql: records, then answers from $STUB_ROWS (hex rows) or fails with $STUB_ERR.
cat > "$T/stubs/psql" <<'SH'
#!/bin/sh
d="$STUB_DIR"
printf '%s\n' "$@" > "$d/argv"
env | grep '^PG' | sort > "$d/pgenv"
cat > "$d/sql"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
if [ -n "${STUB_ERR:-}" ]; then echo "$STUB_ERR" >&2; exit 3; fi
[ ! -f "$d/rows" ] || cat "$d/rows"
SH
chmod +x "$T/stubs/psql"
export STUB_DIR="$T/pg"; mkdir -p "$STUB_DIR"
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
hexrow() { printf '%s|%s|%s|%s|%s\n' "$(hex "$1")" "$(hex "$2")" "$(hex "$3")" "$(hex "$4")" "$(hex "$5")"; }

# ------------------------------------------------------------------ sqlite ----
S=registry-source-db
DB="$T/reg.db"
python3 -I - "$DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table rows (section text, key text, type text, data text, locked integer)")
c.executemany("insert into rows values (?,?,?,?,?)", [
  ("skills/web", "body", "text", "from the database", 0),
  ("skills/web", "terms", "list", "a, b", 1),
  ("skills/web", "note", "text", "line one\nline two\n", 0),
  ("skills/web", "at", "text", "@not a file", 0),
  ("skills/*", "owner", "value", "naïve café", 0),
])
c.execute("create table empty (section text, key text, type text, data text, locked integer)")
c.commit()
PY
fetch_to() { rm -rf "$T/d"; mkdir "$T/d"; $S fetch l "$T/d" "$@" 2>"$T/err" >"$T/out"; }

fetch_to driver=sqlite "path=$DB" table=rows; check "sqlite table: fetched" 0 $?
reg="$(cat "$T/d/l.layer" 2>/dev/null)"
contains "the first section is rendered" "$reg" "[skills/*]"
contains "a value entry" "$reg" "owner:value = naïve café"
contains "a text entry on one line" "$reg" "body:text = from the database"
contains "a list entry" "$reg" "terms:list = a, b"
contains "a locked row adds a lock line" "$reg" $'terms:list = a, b\nlock terms'
contains "a text value with a newline goes to a file" "$reg" "note:text = @file text/"
contains "a text value starting with @ goes to a file" "$reg" "at:text = @file text/"
check "the file holds the @ text as it is" "@not a file" "$(cat "$T/d/text/1.txt" 2>/dev/null)"
check "the file holds the multi-line text as it is" $'line one\nline two\nx' "$(cat "$T/d/text/2.txt" 2>/dev/null; echo x)"
fetch_to driver=sqlite "path=$DB" "query=SELECT section, key, type, data, locked FROM rows WHERE locked = 1"; check "sqlite query: fetched" 0 $?
check "the query's rows only (a section, an entry, a lock)" "3" "$(wc -l < "$T/d/l.layer" | tr -d ' ')"
fetch_to driver=sqlite "path=$DB" "query=select section, key, type, data, locked from rows"; check "a lower-case select is fine" 0 $?
v1="$($S version l driver=sqlite "path=$DB" table=rows)"; v2="$($S version l driver=sqlite "path=$DB" table=rows)"
contains "version: a sha256" "$v1" "sha256:"
check "version: the same rows, the same version" "$v1" "$v2"
python3 -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"update rows set data='changed' where key='owner'\"); c.commit()" "$DB"
check "version: a changed row is another version" yes "$([ "$($S version l driver=sqlite "path=$DB" table=rows)" != "$v1" ] && echo yes)"
fetch_to driver=sqlite "path=$DB" table=empty; check "an empty result: exit 1" 1 $?
contains "... said" "$(cat "$T/err")" "no rows"
check "... nothing written" 0 "$(find "$T/d" -type f | wc -l)"
fetch_to driver=sqlite "path=$DB" table=nosuch; check "a missing table: exit 1" 1 $?
contains "a query error is said" "$(cat "$T/err")" "no such table"
fetch_to driver=sqlite "path=$T/none.db" table=rows; check "a missing database file: exit 1" 1 $?
fetch_to driver=sqlite "path=$DB" "query=SELECT section, key, type, data, locked FROM rows; DROP TABLE rows"; check "two statements: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB" "query=DELETE FROM rows"; check "a non-SELECT: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB" table=rows "query=select 1"; check "table and query together: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB"; check "neither table nor query: exit 2" 2 $?
fetch_to driver=sqlite table=rows; check "sqlite without path: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB" table=rows host=h; check "sqlite with a host: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB" "table=rows;drop"; check "a table name with a semicolon: exit 2" 2 $?
fetch_to driver=oracle "path=$DB" table=rows; check "an unsupported driver: exit 3" 3 $?
fetch_to "path=$DB" table=rows; check "no driver: exit 2" 2 $?
fetch_to driver=sqlite "path=$DB" table=rows frob=1; check "an unknown setting: exit 2" 2 $?
check "an unknown verb: exit 3" 3 "$($S frobnicate >/dev/null 2>&1; echo $?)"
check "supports lists its verbs" "fetch version supports" "$($S supports | tr '\n' ' ' | sed 's/ $//')"

# Bad rows (one is enough to refuse the layer)
bad() { # <name> <sql values> <expected text>
  python3 -I - "$DB" "$2" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("drop table if exists bad")
c.execute("create table bad (section text, key text, type text, data text, locked text)")
c.execute("insert into bad values ('skills/ok','good','value','1','0')")
c.execute("insert into bad values (%s)" % sys.argv[2])
c.commit()
PY
  fetch_to driver=sqlite "path=$DB" table=bad; check "bad row ($1): exit 1" 1 $?
  contains "bad row ($1): the reason" "$(cat "$T/err")" "$3"
  check "bad row ($1): nothing written" 0 "$(find "$T/d" -type f | wc -l)"
}
bad "unknown type" "'skills/x','k','number','1','0'" "type 'number'"
bad "empty key" "'skills/x','','value','1','0'" "key ''"
bad "section with a bracket" "'skills/x]','k','value','1','0'" "section 'skills/x]'"
bad "empty section" "'','k','value','1','0'" "section ''"
bad "an exclusion with an entry" "'!skills/x','k','value','1','0'" "exclusion"
bad "a line break in a value" "'skills/x','k','value',char(97,10,98),'0'" "one line"
bad "locked that is not a flag" "'skills/x','k','value','1','maybe'" "locked 'maybe'"
bad "data starting with @" "'skills/x','k','value','@f','0'" "start with @"
bad "a lock-injecting key" "'skills/x','k lock z','value','1','0'" "key 'k lock z'"

# ---------------------------------------------------------------- postgres ----
cp "$T/stubs/psql" "$bin/psql"
pgfetch() { rm -rf "$T/d"; mkdir "$T/d"; $S fetch l "$T/d" driver=postgres "$@" 2>"$T/err" >"$T/out"; }
CONN=(host=db.example.invalid port=6543 database=registry user=reader sslmode=require)
{ hexrow skills/pg body text "from postgres" false; hexrow skills/pg terms list "x, y" true; } > "$STUB_DIR/rows"
pgfetch "${CONN[@]}" table=public.registry_rows auth.secret=registry/db; check "postgres: fetched" 0 $?
reg="$(cat "$T/d/l.layer" 2>/dev/null)"
check "postgres: the rendered file" $'[skills/pg]\nbody:text = from postgres\nterms:list = x, y\nlock terms' "$reg"
env="$(cat "$STUB_DIR/pgenv")"
contains "connection: host" "$env" "PGHOST=db.example.invalid"
contains "connection: port" "$env" "PGPORT=6543"
contains "connection: database" "$env" "PGDATABASE=registry"
contains "connection: user" "$env" "PGUSER=reader"
contains "connection: sslmode passed through" "$env" "PGSSLMODE=require"
contains "read-only transaction" "$env" "default_transaction_read_only=on"
contains "the password reaches psql in its environment" "$env" "PGPASSWORD=$SECRET"
lacks "the secret is not in psql's arguments" "$(cat "$STUB_DIR/argv")" "$SECRET"
lacks "the secret is not in the SQL" "$(cat "$STUB_DIR/sql")" "$SECRET"
lacks "the secret is not in the source's output" "$(cat "$T/out" "$T/err")" "$SECRET"
lacks "the secret is not in the layer copy" "$(cat "$T/d"/* 2>/dev/null)" "$SECRET"
contains "the SQL reads the table" "$(cat "$STUB_DIR/sql")" "FROM ("
contains "the table form orders its rows" "$(cat "$STUB_DIR/sql")" "FROM public.registry_rows ORDER BY section, key"
pgfetch host=db.example.invalid database=registry user=reader "query=SELECT 1 AS section"; check "postgres without a password: fetched" 0 $?
lacks "... no PGPASSWORD set" "$(cat "$STUB_DIR/pgenv")" "PGPASSWORD"
contains "port defaults to 5432" "$(cat "$STUB_DIR/pgenv")" "PGPORT=5432"
contains "sslmode defaults to prefer" "$(cat "$STUB_DIR/pgenv")" "PGSSLMODE=prefer"
# ... nor in any process's arguments while the client is running
STUB_SLEEP=2 pgfetch "${CONN[@]}" table=t auth.secret=registry/db &
bg=$!; seen=no; saw=no
for _ in $(seq 15); do
  for c in /proc/[0-9]*/cmdline; do
    [ -r "$c" ] || continue
    args="$(tr '\0' ' ' < "$c" 2>/dev/null)"
    case "$args" in *"$SECRET"*) seen=yes ;; esac
    case "$args" in *psql*) saw=yes ;; esac
  done
  sleep 0.1
done
check "the secret is in no process's arguments" no "$seen"
check "(the client was running when the process list was read)" yes "$saw"
wait "$bg"
pgfetch "${CONN[@]}" table=t auth.secret=registry/nope; check "a secret dcf-secret cannot read: exit 1" 1 $?
lacks "... and nothing of it said" "$(cat "$T/err")" "$SECRET"
STUB_ERR='FATAL:  password authentication failed for user "reader"' pgfetch "${CONN[@]}" table=t auth.secret=registry/db; check "a failed log-in: exit 1" 1 $?
contains "the client's first line of error is said" "$(cat "$T/err")" "password authentication failed"
lacks "... without the secret" "$(cat "$T/err")" "$SECRET"
STUB_ERR='ERROR:  relation "t" does not exist' pgfetch "${CONN[@]}" table=t; check "a query error: exit 1" 1 $?
contains "the query error is said" "$(cat "$T/err")" 'relation "t" does not exist'
: > "$STUB_DIR/rows"; pgfetch "${CONN[@]}" table=t; check "an empty result: exit 1" 1 $?
contains "... said" "$(cat "$T/err")" "no rows"
hexrow skills/x k bogus 1 0 > "$STUB_DIR/rows"; pgfetch "${CONN[@]}" table=t; check "a bad row: exit 1" 1 $?
contains "... with its reason" "$(cat "$T/err")" "type 'bogus'"
printf 'zz|zz|zz|zz|zz\n' > "$STUB_DIR/rows"; pgfetch "${CONN[@]}" table=t; check "output that is not hex: exit 1" 1 $?
hexrow skills/pg body text "t" 0 > "$STUB_DIR/rows"
pgfetch host=h database=d table=t; check "postgres without a user: exit 2" 2 $?
pgfetch "${CONN[@]}" table=t path=x; check "postgres with a path: exit 2" 2 $?
pgfetch "${CONN[@]}" sslmode=sometimes table=t; check "a bad sslmode: exit 2" 2 $?
pgfetch host='h; rm' database=d user=u table=t; check "a host with a space or semicolon: exit 2" 2 $?
pgfetch "${CONN[@]}" port=abc table=t; check "a non-numeric port: exit 2" 2 $?
v1="$($S version l driver=postgres "${CONN[@]}" table=t)"; contains "postgres version: a sha256" "$v1" "sha256:"
check "postgres version: stable" "$v1" "$($S version l driver=postgres "${CONN[@]}" table=t)"
rm "$bin/psql"
pgfetch "${CONN[@]}" table=t; check "no psql: exit 1" 1 $?
contains "... says how to install it" "$(cat "$T/err")" "postgresql-client"
if [ "$have_real" = no ]; then
  mv "$bin/sqlite3" "$bin/sqlite3.off"
  fetch_to driver=sqlite "path=$DB" table=rows; check "no sqlite3: exit 1" 1 $?
  contains "... says how to install it" "$(cat "$T/err")" "apt-get install sqlite3"
  mv "$bin/sqlite3.off" "$bin/sqlite3"
fi

# ------------------------------------------------- through dcf-registry resolve ----
C="$T/case"; mkdir -p "$C/repo/.devcontainer"; cd "$C/repo" || exit 1
export COMPONENT_REGISTRY_STATE_DIR="$C/state" COMPONENT_REGISTRY_SHARE_DIR="$T/none"
python3 -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"update rows set data='naïve café' where key='owner'\"); c.commit()" "$DB"
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: db, driver: sqlite, path: "%s", table: rows }\n' "$DB" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "resolve with a db layer: exit 0" 0 $?
contains "the layer's text is resolved" "$(cat "$C/state/view/meta/skills/web/values/body" 2>/dev/null)" "from the database"
check "the list is resolved" "a
b" "$(cat "$C/state/view/meta/skills/web/values/terms" 2>/dev/null)"
contains "the multi-line text comes through @file" "$(cat "$C/state/view/meta/skills/web/values/note" 2>/dev/null)" "line two"
contains "a lock is kept" "$(dcf-registry explain skills/web 2>&1)" "terms"
mv "$DB" "$DB.gone"
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "the database is gone: resolve still exits 0" 0 "$rc"
contains "the last good copy is said" "$out" "using the last good copy"
contains "the last good copy is still resolved" "$(cat "$C/state/view/meta/skills/web/values/body" 2>/dev/null)" "from the database"
mv "$DB.gone" "$DB"
printf 'layers:\n  - id: rel\n    at: /Corp\n    sources:\n      - { kind: db, driver: sqlite, path: ../reg.db, query: "SELECT section, key, type, data, locked FROM rows" }\n' > .devcontainer/registry.yml
mkdir -p "$C/repo/sub" && cp "$DB" "$C/reg.db"
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "a repository-relative sqlite path with a quoted query: exit 0" 0 $?
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: db, driver: oracle, table: t }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "an unsupported driver is a layer problem, not a crash: exit 0" 0 $?
contains "... named" "$out" "not supported"
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: db, driver: sqlite, path: x }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "a db source without table or query: exit 2" 2 $?
contains "... naming the need" "$out" "exactly one of table, query"
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: db, driver: postgres, host: h, database: d, table: t, url: x }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "a postgres source with a url or without a user: exit 2" 2 $?
contains "... naming the user need" "$out" "needs user"
contains "... and the keys it takes" "$out" "auth.secret only"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
