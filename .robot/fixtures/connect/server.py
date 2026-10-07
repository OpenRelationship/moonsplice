# The connect suite's Acme: answers on 127.0.0.1:PORT, refuses a request without the key, and logs each request it
# accepted (method, path, whether the key matched) to LOG, one JSON line each, never the key itself.
import http.server, json, sys

PORT, KEY, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
TICKETS = [{"id": 1, "title": "the lamp flickers", "state": "open"}]


class Acme(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_one(self, method):
        ok = self.headers.get("x-acme-key") == KEY
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": method, "path": self.path, "key_ok": ok}) + "\n")
        if not ok:
            return self.answer(401, {"error": "bad key"})
        path = self.path.split("?")[0]
        if method == "GET" and path == "/api/me":
            return self.answer(200, {"name": "me"})
        if method == "GET" and path == "/api/tickets":
            return self.answer(200, TICKETS)
        if method == "POST" and path == "/api/tickets":
            n = int(self.headers.get("content-length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            t = {"id": len(TICKETS) + 1, "title": body.get("title"), "state": "open"}
            TICKETS.append(t)
            return self.answer(201, t)
        return self.answer(404, {"error": "no such path"})

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")


http.server.HTTPServer(("127.0.0.1", PORT), Acme).serve_forever()
