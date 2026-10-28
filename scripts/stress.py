#!/usr/bin/env python3
"""Hammers the notch API with valid, malformed and hostile traffic; the app must survive and keep answering."""
import json, os, random, socket, subprocess, sys, threading, time, urllib.request

PORT = int(os.environ.get("NOTCH_PORT", "39283"))
HOST = f"127.0.0.1:{PORT}"
failures = []

def pid():
    out = subprocess.run(["pgrep", "-x", "DynamicNotch"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None

def rss_mb(p):
    out = subprocess.run(["ps", "-o", "rss=", "-p", p], capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else -1

def request(method, path, body=None, headers=None, timeout=3):
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    req = urllib.request.Request(f"http://{HOST}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}

def raw(payload, wait=1.0, shutdown=True):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=3)
    try:
        s.sendall(payload)
        if shutdown:
            s.shutdown(socket.SHUT_WR)
        s.settimeout(wait)
        return s.recv(65536)
    except Exception:
        return b""
    finally:
        s.close()

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)

def alive():
    try:
        return request("GET", "/v1/health")[0] == 200
    except Exception:
        return False

p0 = pid()
check("app running", p0 is not None)
if p0 is None:
    sys.exit(1)
mem0 = rss_mb(p0)

# 1. functional basics
check("health", alive())
code, state = request("GET", "/v1/state")
check("state shape", code == 200 and "presentation" in state and "media" in state)

# 2. validation
cases = [
    ("empty toast", "POST", "/v1/toast", {}, 400),
    ("level only", "POST", "/v1/toast", {"level": 0.5}, 200),
    ("level out of range", "POST", "/v1/toast", {"level": 99, "symbol": "star"}, 200),
    ("negative duration", "POST", "/v1/toast", {"text": "x", "duration": -5}, 200),
    ("huge duration", "POST", "/v1/toast", {"text": "x", "duration": 1e12}, 200),
    ("wrong types", "POST", "/v1/toast", {"text": 5, "level": "x", "symbol": [], "tint": {}}, 400),
    ("nan literal (invalid JSON)", "POST", "/v1/toast", {"text": "x", "level": float("nan")}, 400),
    ("bad symbol", "POST", "/v1/toast", {"text": "x", "symbol": "does.not.exist"}, 200),
    ("bad tint", "POST", "/v1/toast", {"text": "x", "tint": "zzz"}, 200),
    ("emoji/unicode", "POST", "/v1/toast", {"text": "🎧 Şarkı değişti — çğüşıö"}, 200),
    ("very long text", "POST", "/v1/toast", {"text": "A" * 100000}, 200),
    ("bool as number", "POST", "/v1/toast", {"text": "x", "level": True}, 400),
    ("activity needs id", "POST", "/v1/activity", {"text": "x"}, 400),
    ("activity bad id", "POST", "/v1/activity", {"id": "bad id!", "text": "x"}, 400),
    ("activity ok", "POST", "/v1/activity", {"id": "dl", "text": "İndiriliyor", "symbol": "arrow.down.circle.fill", "level": 0.4}, 200),
    ("activity update", "POST", "/v1/activity", {"id": "dl", "text": "İndiriliyor", "level": 0.8}, 200),
    ("activities list", "GET", "/v1/activities", None, 200),
    ("activity end", "POST", "/v1/activity/end", {"id": "dl"}, 200),
    ("activity end missing", "POST", "/v1/activity/end", {"id": "nope"}, 200),
    ("timer needs seconds", "POST", "/v1/timer", {}, 400),
    ("timer zero", "POST", "/v1/timer", {"seconds": 0}, 400),
    ("timer huge", "POST", "/v1/timer", {"seconds": 1e9}, 400),
    ("timer ok", "POST", "/v1/timer", {"seconds": 2, "label": "Çay", "id": "tea"}, 200),
    ("body is array", "POST", "/v1/toast", [1, 2], 400),
    ("bad media action", "POST", "/v1/media", {"action": "explode"}, 400),
    ("seek no seconds", "POST", "/v1/media", {"action": "seek"}, 400),
    ("seek negative", "POST", "/v1/media", {"action": "seek", "seconds": -50}, 200),
    ("unknown route", "GET", "/v1/nope", None, 404),
    ("wrong method", "DELETE", "/v1/health", None, 404),
]
for name, m, path, body, want in cases:
    code, _ = request(m, path, body)
    # 409 = notch hidden because a full-screen app is active: a valid request, just not displayable.
    check(f"validation: {name}", code == want or (want == 200 and code == 409 and path == "/v1/toast"), f"got {code}, want {want}")
check("alive after validation", alive())

# 3. malformed / hostile raw traffic
hostile = {
    "garbage bytes": os.urandom(2048),
    "no terminator": b"GET /v1/health HTTP/1.1\r\nHost: " + HOST.encode(),
    "bad content-length": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: abc\r\n\r\n{{}}".encode(),
    "negative content-length": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: -5\r\n\r\n".encode(),
    "huge content-length (>256KB)": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 99999999999\r\n\r\n".encode(),
    "body shorter than length": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n{{\"text\":\"a\"}}".encode(),
    "broken json": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\n{{\"text\":".encode(),
    "binary json": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n".encode() + b"\xff\xfe\x00\x01",
    "no host": b"GET /v1/health HTTP/1.1\r\n\r\n",
    "evil host": b"GET /v1/health HTTP/1.1\r\nHost: evil.example\r\n\r\n",
    "http/1.0": f"GET /v1/health HTTP/1.0\r\nHost: {HOST}\r\n\r\n".encode(),
    "huge header": f"GET /v1/health HTTP/1.1\r\nHost: {HOST}\r\nX: ".encode() + b"A" * 300000 + b"\r\n\r\n",
    "path traversal": f"GET /../../etc/passwd HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode(),
    "null bytes": f"GET /v1/health\x00 HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode(),
    "300KB body": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 300000\r\n\r\n".encode() + b"x" * 300_000,
    "2MB body": f"POST /v1/toast HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: application/json\r\nContent-Length: 2000000\r\n\r\n".encode() + b"x" * 2_000_000,
    "pipelined": (f"GET /v1/health HTTP/1.1\r\nHost: {HOST}\r\n\r\n" * 5).encode(),
}
for name, payload in hostile.items():
    raw(payload)
    check(f"hostile: {name} -> still alive", alive())

# 4. slowloris: many connections that never finish
socks = []
for _ in range(80):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=2)
        s.sendall(b"GET /v1/health HTTP/1.1\r\n")
        socks.append(s)
    except Exception:
        break
time.sleep(0.3)
check("alive during 80 stalled connections", alive())
for s in socks:
    s.close()
check("alive after stalled connections closed", alive())

# 5. concurrency: many parallel valid requests
errors = []
def worker(n):
    for i in range(n):
        try:
            kind = random.choice(["toast", "state", "toast2", "media", "expand", "collapse", "activity"])
            if kind == "toast":
                c, _ = request("POST", "/v1/toast", {"text": f"t{i}", "symbol": "star.fill", "duration": 0.6})
            elif kind == "activity":
                c, _ = request("POST", "/v1/activity", {"id": f"a{random.randint(0,12)}", "text": "job", "level": random.random()})
            elif kind == "toast2":
                c, _ = request("POST", "/v1/toast", {"level": random.random(), "symbol": "bolt.fill"})
            elif kind == "media":
                c, _ = request("POST", "/v1/media", {"action": random.choice(["toggle", "next", "previous"])}) if os.environ.get("STRESS_MEDIA") else (200, {})
            elif kind == "expand":
                c, _ = request("POST", "/v1/expand", {})
            elif kind == "collapse":
                c, _ = request("POST", "/v1/collapse", {})
            else:
                c, _ = request("GET", "/v1/state")
            if c not in (200, 409):
                errors.append((kind, c))
        except Exception as e:
            errors.append(("exc", repr(e)))
t0 = time.time()
threads = [threading.Thread(target=worker, args=(60,)) for _ in range(24)]
[t.start() for t in threads]; [t.join() for t in threads]
check(f"1440 concurrent requests, no errors ({time.time()-t0:.1f}s)", not errors, str(errors[:5]))
check("alive after concurrency", alive())

# 6. burst of toasts + rapid expand/collapse (UI state machine)
for i in range(200):
    request("POST", "/v1/toast", {"text": f"burst {i}", "duration": 0.5})
    if i % 7 == 0:
        request("POST", "/v1/expand", {})
    if i % 11 == 0:
        request("POST", "/v1/collapse", {})
time.sleep(1)
check("alive after UI burst", alive())

# 7. resource usage
p1 = pid()
check("same process (no crash/restart)", p1 == p0, f"{p0} -> {p1}")
mem1 = rss_mb(p1) if p1 else -1
print(f"memory: {mem0:.0f} MB -> {mem1:.0f} MB")
check("memory growth < 150 MB", mem1 - mem0 < 150)
cpu = subprocess.run(["ps", "-o", "%cpu=", "-p", p1], capture_output=True, text=True).stdout.strip()
print(f"idle cpu right after test: {cpu}%")
fds = subprocess.run(["lsof", "-p", p1], capture_output=True, text=True).stdout.count("\n")
print(f"open files: {fds}")
check("open files < 400", fds < 400, str(fds))

request("POST", "/v1/activity/clear", {})  # leave no test activities on the notch
print("\nFAILED: " + ", ".join(failures) if failures else "\nALL PASSED")
sys.exit(1 if failures else 0)
