#!/usr/bin/env python3
"""Tiny mock of the Azure DevOps and TeamCity REST endpoints the platform scripts call.

Usage: mock_server.py PORT CALL_LOG
  ADO:  /myorg/<project>/_apis/git/repositories
        /myorg/<project>/_apis/git/repositories/<id>/items?path=/ci.yaml...
  TC:   /app/rest/swagger.json, /app/rest/projects..., /app/rest/vcs-roots
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlparse

PORT = int(sys.argv[1])
CALL_LOG = sys.argv[2]

ADO = {
    "PlatformPilot": [
        # (id, name, defaultBranch, disabled, ci.yaml content or None)
        ("r1", "FA-HELLO", "refs/heads/main", False, None),
        ("r2", "WA-PORTAL", "refs/heads/master", False, None),
        ("r3", "pricing-engine", "refs/heads/main", False, "type: function-app\nazure_name: func-pricing  # comment\n"),
        ("r4", "FA-OLD", "refs/heads/main", True, None),                        # disabled repo
        ("r5", "FA-OPTOUT", "refs/heads/main", False, "enabled: false\n"),       # opted out
        ("r6", "docs", "refs/heads/main", False, None),                          # no match
        ("r7", "weird", "refs/heads/main", False, "type: 'logic-app'\n"),        # unknown type
        ("r8", "empty-repo", None, False, None),                                 # no default branch
    ],
}

TC_PROJECTS = {"_Root", "CREDIT"}


def log(line):
    with open(CALL_LOG, "a") as f:
        f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def do_GET(self):
        u = urlparse(self.path)
        parts = [unquote(p) for p in u.path.strip("/").split("/")]
        q = parse_qs(u.query)
        log(f"GET {u.path}")

        # ---- ADO ----
        if len(parts) >= 5 and parts[0] == "myorg" and parts[2:5] == ["_apis", "git", "repositories"]:
            proj = parts[1]
            if proj not in ADO:
                return self.send_json(404, {"message": "no project"})
            repos = ADO[proj]
            if len(parts) == 5:
                return self.send_json(200, {"value": [
                    {"id": i, "name": n, "isDisabled": d,
                     "webUrl": f"https://dev.azure.com/myorg/{proj}/_git/{n}",
                     **({"defaultBranch": b} if b else {})}
                    for (i, n, b, d, _) in repos]})
            if len(parts) == 7 and parts[6] == "items":
                rid = parts[5]
                assert q.get("path") == ["/ci.yaml"], q
                for (i, n, b, d, ci) in repos:
                    if i == rid and ci is not None:
                        assert q.get("versionDescriptor.version") == [b.replace("refs/heads/", "")], q
                        return self.send_json(200, {"path": "/ci.yaml", "content": ci})
                return self.send_json(404, {"message": "not found"})

        # ---- TeamCity ----
        if parts[:2] == ["app", "rest"]:
            if parts[2] == "swagger.json":
                return self.send_json(200, {"paths": {"/app/rest/projects/{projectLocator}/versionedSettings/contextParameters": {}}})
            if parts[2] == "projects" and len(parts) == 4:
                pid = parts[3].replace("id:", "")
                if pid in TC_PROJECTS:
                    return self.send_json(200, {"id": pid})
                return self.send_json(404, {"message": "not found"})
        self.send_json(404, {"message": "unhandled " + u.path})

    def _write(self, method):
        u = urlparse(self.path)
        b = self.body()
        log(f"{method} {u.path} {b}")
        if u.path == "/app/rest/projects" and method == "POST":
            TC_PROJECTS.add(json.loads(b)["id"])
        self.send_json(200, {})

    def do_POST(self):
        self._write("POST")

    def do_PUT(self):
        self._write("PUT")


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
