#!/usr/bin/env python3
# A pretend iCloud calendar server on 127.0.0.1 for `Dateline --accounts-check`: one user, a Home calendar
# with one event, a Reminders list and an inbox (both must stay out of Dateline), iCloud's version checks on changes,
# and its managed attachments (RFC 8607: POST ?action=attachment-add / attachment-remove, the file at its own address).
# Prints its address, then serves until killed. Holds everything in memory, writes nothing.
import base64, http.server, uuid
from urllib.parse import urlsplit, parse_qs, unquote
from xml.sax.saxutils import escape

AUTH = "Basic " + base64.b64encode(b"t@example.com:pw").decode()
SEED = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:seed1\r\nDTSTART:20261030T150000Z\r\nDTEND:20261030T160000Z\r\nSUMMARY:Seed event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
files = {"/1/calendars/home/seed1.ics": (SEED, '"e0"')}
blobs = {}  # managed id -> the attached file's bytes

def ms(*responses):
    return ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">'
            + "".join(f"<d:response><d:href>{h}</d:href><d:propstat><d:prop>{p}</d:prop></d:propstat></d:response>" for h, p in responses)
            + "</d:multistatus>")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, body="", headers={}):
        b = body.encode()
        self.send_response(code)
        for k, v in headers.items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def gate(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.raw = self.rfile.read(n) if n else b""
        self.body = self.raw.decode(errors="replace")
        if self.headers.get("Authorization") != AUTH:
            self.reply(401); return False
        return True

    def do_PROPFIND(self):
        if not self.gate(): return
        base = f"http://{self.headers['Host']}"
        if "current-user-principal" in self.body:
            return self.reply(207, ms((self.path, "<d:current-user-principal><d:href>/1/principal/</d:href></d:current-user-principal>")))
        if "calendar-home-set" in self.body:  # iCloud answers with a full address on another host
            return self.reply(207, ms((self.path, f"<c:calendar-home-set><d:href>{base}/1/calendars/</d:href></c:calendar-home-set>")))
        rw = "<d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>"
        self.reply(207, ms(
            ("/1/calendars/home/", f"<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Home</d:displayname><a:calendar-color>#FF2968FF</a:calendar-color>{rw}"
                                   '<c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>'),
            ("/1/calendars/tasks/", f"<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Reminders</d:displayname>{rw}"
                                    '<c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>'),
            ("/1/calendars/inbox/", "<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>")))

    def do_REPORT(self):
        if not self.gate(): return
        self.reply(207, ms(*[(h, f"<d:getetag>{escape(e)}</d:getetag><c:calendar-data>{escape(t)}</c:calendar-data>")
                            for h, (t, e) in files.items() if h.startswith(self.path)]))

    def do_PUT(self):
        if not self.gate(): return
        have = files.get(self.path)
        if self.headers.get("If-None-Match") == "*" and have: return self.reply(412)
        if "If-Match" in self.headers and (not have or have[1] != self.headers["If-Match"]): return self.reply(412)
        etag = f'"{uuid.uuid4().hex[:8]}"'
        files[self.path] = (self.body, etag)
        self.reply(204 if have else 201, headers={"ETag": etag})

    def do_GET(self):
        if not self.gate(): return
        if self.path.startswith("/attachments/"):
            b = blobs.get(self.path.rsplit("/", 1)[1])
            if b is None: return self.reply(404)
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        have = files.get(self.path)
        if not have: return self.reply(404)
        self.reply(200, have[0], {"ETag": have[1], "Content-Type": "text/calendar"})

    def do_POST(self):
        if not self.gate(): return
        u = urlsplit(self.path); q = parse_qs(u.query); have = files.get(u.path)
        if not have: return self.reply(404)
        if "If-Match" in self.headers and have[1] != self.headers["If-Match"]: return self.reply(412)
        text, action = have[0].replace("\r\n ", "").replace("\r\n\t", ""), q.get("action", [""])[0]  # unfolded, so a long ATTACH line is one line
        if action == "attachment-add":
            mid = uuid.uuid4().hex[:6]; blobs[mid] = self.raw
            d = self.headers.get("Content-Disposition", "")
            name = unquote(d.split("filename*=UTF-8''", 1)[1]) if "filename*=" in d else d.split('filename="', 1)[1].split('"', 1)[0]
            line = f'ATTACH;MANAGED-ID={mid};FMTTYPE={self.headers.get("Content-Type")};SIZE={len(self.raw)};FILENAME={name}:http://{self.headers["Host"]}/attachments/{mid}'
            text = text.replace("END:VEVENT", line + "\r\nEND:VEVENT")  # every instance, as with no rid
            code, extra = 201, {"Cal-Managed-ID": mid}
        elif action == "attachment-remove":
            mid = q.get("managed-id", [""])[0]
            if mid not in blobs: return self.reply(409)
            del blobs[mid]
            text = "\r\n".join(l for l in text.split("\r\n") if f"MANAGED-ID={mid};" not in l)
            code, extra = 204, {}
        else: return self.reply(400)
        etag = f'"{uuid.uuid4().hex[:8]}"'
        files[u.path] = (text, etag)
        self.reply(code, headers={"ETag": etag, **extra})

    def do_DELETE(self):
        if not self.gate(): return
        have = files.get(self.path)
        if not have: return self.reply(404)
        if "If-Match" in self.headers and have[1] != self.headers["If-Match"]: return self.reply(412)
        del files[self.path]
        self.reply(204)

s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(f"http://127.0.0.1:{s.server_port}/", flush=True)
s.serve_forever()
