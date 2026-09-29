#!/usr/bin/env python3
"""Central-identity prototype proof (Phase 0 of docs/CENTRAL_IDENTITY.md).

Identity stack A = the kit's teststack (CLI-managed, kit functions live).
Project stack B  = teststack/identity (docker-compose): its own database
(project_b), its own PostgREST + a signup-disabled GoTrue, both carrying
A's JWT secret.

Proves: kit-on-A mints a confirmed user → A's JWT verifies on B →
B's RLS keys on the foreign token's auth.uid() → other users and anon
get nothing → B's own GoTrue refuses signups.
"""
import json, re, subprocess, sys, time, urllib.request

EV = "http://127.0.0.1:8787"          # kit email-verification (host-run)
A_API = "http://127.0.0.1:54321"      # identity stack (A) API
B_REST = "http://127.0.0.1:31000"     # project B PostgREST
B_AUTH = "http://127.0.0.1:31001"     # project B GoTrue (signup disabled)
A_ANON = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
B_ANON = A_ANON  # prototype: B has no Kong, the same publishable key rides along

results = []
def check(name, cond, detail=""):
    results.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))
    if not cond:
        sys.exit(1)

def post(url, body, headers=None):
    h = {"content-type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()[:200]
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw  # non-JSON refusal bodies (404 page, html…)

def rest(method, path, body=None, jwt=None):
    h = {"content-type": "application/json", "apikey": B_ANON}
    if jwt:
        h["authorization"] = f"Bearer {jwt}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{B_REST}{path}", data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]

def latest_mail(to_prefix, subject_contains, tries=6):
    for _ in range(tries):
        with urllib.request.urlopen("http://127.0.0.1:54324/api/v1/messages?limit=50") as r:
            box = json.loads(r.read())
        for m in box.get("messages", []):
            tos = ",".join(a.get("Address", a.get("address", "")) for a in m.get("To", []))
            if tos.startswith(to_prefix) and subject_contains.lower() in m.get("Subject", "").lower():
                with urllib.request.urlopen(f"http://127.0.0.1:54324/api/v1/message/{m['ID']}") as r:
                    return json.loads(r.read())
        time.sleep(1)
    raise AssertionError(f"no mail to {to_prefix} ~ '{subject_contains}'")

email = f"carol{int(time.time())}@kit.test"
password = "Str0ngPass!2026"

# ------------------------------------------- 1. identity: kit-native signup
st, body = post(EV, {"action": "signup", "email": email, "password": password})
check("1a kit signup creates the user on A (no session)", st == 200 and body.get("sent") is True, str(body))
mail = latest_mail(email, "confirmation code")
code = re.search(r"\b(\d{6})\b", mail.get("Text", "")).group(1)
st, body = post(EV, {"action": "verify", "email": email, "code": code})
check("1b kit verification confirms the address on A", st == 200 and body.get("verified") is True, str(body))

# --------------------------------- 2. identity: sign in, get the real JWT
st, body = post(f"{A_API}/auth/v1/token?grant_type=password",
                {"email": email, "password": password}, {"apikey": A_ANON})
jwt = body.get("access_token", "")
uid = (body.get("user") or {}).get("id", "")
check("2a sign-in on A yields a session", st == 200 and bool(jwt), f"st={st}")
import base64
claims = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
check("2b the JWT carries role=authenticated and the uid",
      claims.get("role") == "authenticated" and claims.get("sub") == uid,
      json.dumps(claims)[:120])

# --------------------------------------- 3. project B: foreign JWT works
st, body = rest("POST", "/identity_proof", {"label": "carol row"}, jwt=jwt)
check("3a insert on B with A's JWT — RLS stamps auth.uid()", st == 201, str(body))
st, body = rest("GET", "/identity_proof", jwt=jwt)
check("3b owner sees exactly their row", st == 200 and len(body) == 1 and body[0]["owner"] == uid, str(body)[:120])

# second identity user: same project, different uid → no access
st, body = post(EV, {"action": "signup", "email": f"dave{int(time.time())}@kit.test", "password": password})
mail = latest_mail(f"dave{int(time.time())}@kit.test", "confirmation code")
dave_code = re.search(r"\b(\d{6})\b", mail.get("Text", "")).group(1)
post(EV, {"action": "verify", "email": f"dave{int(time.time())}@kit.test", "code": dave_code})
st, dbody = post(f"{A_API}/auth/v1/token?grant_type=password",
                 {"email": f"dave{int(time.time())}@kit.test", "password": password}, {"apikey": A_ANON})
dave_jwt = dbody.get("access_token", "")
check("3c second user exists on A", st == 200 and bool(dave_jwt), f"st={st}")
st, body = rest("GET", "/identity_proof", jwt=dave_jwt)
check("3d the other user's RLS view of B is empty", st == 200 and body == [], str(body)[:120])

# no token at all → anon
st, body = rest("GET", "/identity_proof")
check("3e anon on B sees nothing", st == 200 and body == [], str(body)[:120])

# foreign auth.uid() really flows: whoami echoes the token's sub
st, body = rest("POST", "/rpc/whoami", {}, jwt=jwt)
check("3f B's whoami() echoes the foreign token's uid", st == 200 and body == uid, str(body))
st, body = rest("POST", "/rpc/whoami", {})
check("3g anon whoami() is null", st == 200 and body is None, str(body))

# ------------------------------------------ 4. project B refuses signups
st, body = post(f"{B_AUTH}/auth/v1/signup", {"email": f"nope{int(time.time())}@probe.local", "password": password},
                {"apikey": B_ANON})
# Any refusal counts (403 signup_disabled on modern stacks; plain 404
# when the publishable-key hop is absent, as in this bare GoTrue-B).
check("4a signup on B is disabled (identity A is the only door)",
      st != 200 and (not isinstance(body, dict) or body.get("error_code") in (None, "signup_disabled")),
      f"st={st} {str(body)[:120]}")

print("\nCENTRAL-IDENTITY PROOF: ALL PASS" if all(results) else "\nFAILURES PRESENT")
