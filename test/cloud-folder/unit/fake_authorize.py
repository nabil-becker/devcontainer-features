"""A fake `rclone authorize "onedrive" --auth-no-open-browser` for the login tests: rclone's own
browser flow, played on 127.0.0.1 (rclone 1.75.2's lib/oauthutil: a link to /auth on its listener,
/auth redirecting to the provider's sign-in, / taking ?code=&state= and the token printed between
the paste markers on stdout, the notices on stderr).
Environment: FAKE_AUTH_PORT (default 0, any free port), FAKE_AUTH_TOKEN (the token line to print),
FAKE_AUTH_LOG (a file each received path is appended to), FAKE_AUTH_BACK (when set, /auth redirects
straight to <FAKE_AUTH_BACK>?code=fakecode&state=<state>, as if the person signed in at once and
the provider sent the browser back), FAKE_AUTH_STATE (a fixed state instead of a random one),
FAKE_AUTH_FAIL=1 (the token exchange fails: exit 1)."""
import http.server
import os
import secrets
import sys
import urllib.parse

state = os.environ.get("FAKE_AUTH_STATE") or secrets.token_urlsafe(16)
token = os.environ.get("FAKE_AUTH_TOKEN", '{"access_token":"x"}')
log = os.environ.get("FAKE_AUTH_LOG")
back = os.environ.get("FAKE_AUTH_BACK")
done = {"code": None}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if log:
            with open(log, "a") as f:
                f.write(self.path + "\n")
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        if q.get("state", [""])[0] != state:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Auth State Error\n")
            return
        if url.path == "/auth":
            if back:
                loc = back + "?code=fakecode&state=" + state
            else:
                loc = ("https://login.example.invalid/common/oauth2/v2.0/authorize?client_id=fake"
                       "&redirect_uri=http%3A%2F%2Flocalhost%3A53682%2F&response_type=code&state=" + state)
            self.send_response(307)
            self.send_header("Location", loc)
            self.end_headers()
            return
        if url.path == "/" and q.get("code"):
            done["code"] = q["code"][0]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Success! All done. Please go back to rclone.\n")
            return
        self.send_response(404)
        self.end_headers()


srv = http.server.HTTPServer(("127.0.0.1", int(os.environ.get("FAKE_AUTH_PORT", "0"))), Handler)
port = srv.server_address[1]
err = sys.stderr
err.write("2026/10/29 10:00:00 NOTICE: Make sure your Redirect URL is set to \"http://localhost:53682/\" in your custom config.\n")
err.write("2026/10/29 10:00:00 NOTICE: Please go to the following link: http://127.0.0.1:%d/auth?state=%s\n" % (port, state))
err.write("2026/10/29 10:00:00 NOTICE: Log in and authorize rclone for access\n")
err.write("2026/10/29 10:00:00 NOTICE: Waiting for code...\n")
err.flush()
while done["code"] is None:
    srv.handle_request()
err.write("2026/10/29 10:00:01 NOTICE: Got code\n")
if os.environ.get("FAKE_AUTH_FAIL") == "1":
    err.write("2026/10/29 10:00:01 ERROR : Failed to get token: invalid_grant\n")
    sys.exit(1)
print("Paste the following into your remote machine --->\n%s\n<---End paste" % token, flush=True)
