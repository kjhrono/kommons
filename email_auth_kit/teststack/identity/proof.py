#!/usr/bin/env python3
"""Central-identity prototype proof (Phase 0 of docs/CENTRAL_IDENTITY.md).

Identity stack A = the kit's teststack (CLI-managed, kit functions live).
Project stack B  = teststack/identity (docker-compose): its own database
(project_b), its own PostgREST + a signup-disabled GoTrue, both carrying
A's JWT secret.

Proves: kit-on-A mints a confirmed user → A's JWT verifies on B →
B's RLS keys on the foreign token's auth.uid() → other users and anon
get nothing → B's own GoTrue refuses signups → the kit's ban kill-switch
(embedded kit_banned_until claim + ban-aware auth.uid()) denies a banned
account on B and unban restores it.
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
# NOTE: the address is computed ONCE — calling int(time.time()) four times
# raced the second boundary on CI and signed in a user that was never
# created (st=400 on 3c, only when the boundary happened to be crossed).
dave_email = f"dave{int(time.time())}@kit.test"
st, body = post(EV, {"action": "signup", "email": dave_email, "password": password})
mail = latest_mail(dave_email, "confirmation code")
dave_code = re.search(r"\b(\d{6})\b", mail.get("Text", "")).group(1)
post(EV, {"action": "verify", "email": dave_email, "code": dave_code})
st, dbody = post(f"{A_API}/auth/v1/token?grant_type=password",
                 {"email": dave_email, "password": password}, {"apikey": A_ANON})
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

# ------------------------------------------------- 5. revocation crosses
# The honest revocation model for stateless JWT verification:
#
#   * plain sign-out on A revokes A's REFRESH tokens only — the unexpired
#     ACCESS JWT remains self-sufficient, and with no verifier-side session
#     lookup (prototype PostgREST-B has none; production kong `jwt` checks
#     signature + exp, not sessions) it stays valid on B until exp.
#   * what DOES propagate before expiry is a BAN: A-side ban makes GoTrue
#     reject the account; for data-plane enforcement the project can keep
#     token lifetimes short and re-check on refresh.
#
# So this section proves what is actually true — and documents the gap.
import base64
claims = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
sid = claims.get("session_id", "")
check("5a the token carries a session_id (auditable, not statelessly checked)",
      bool(sid), str(claims)[:120])

st, body = post(f"{A_API}/auth/v1/logout", {}, {"apikey": A_ANON, "authorization": f"Bearer {jwt}"})
check("5b sign-out on A revokes the refresh path", st in (200, 204), f"st={st} {str(body)[:120]}")

# A-side proof: GoTrue itself now refuses the bearer (the account's
# session is dead server-side).
st, body = post(f"{A_API}/auth/v1/user", {}, {"apikey": A_ANON, "authorization": f"Bearer {jwt}"})
check("5c A refuses the signed-out bearer (session revoked server-side)", st == 403, f"st={st} {str(body)[:160]}")

# B-side truth: the unexpired access JWT is STILL accepted by the
# stateless data plane — the known limitation of signature+exp
# verification, closed operationally by short expiries.
st, body = rest("GET", "/identity_proof", jwt=jwt)
check("5d B still accepts the unexpired token (stateless; documented gap)",
      st == 200, f"st={st} {str(body)[:160]}")

# --------------------------------------- 6. the kit's ban kill-switch
# The data-plane revocation primitive (migration
# 20260930000000_email_auth_kit_bans.sql): identity embeds a
# kit_banned_until claim in every token minted or refreshed while a ban
# is live (custom access token hook); B's ban-aware auth.uid() returns
# NULL on a live claim, so every auth.uid()-keyed policy denies — with B
# knowing nothing about A. Closes the ban-shaped half of section 5's gap:
# refresh re-mints with the claim, so the kill lands within one refresh
# cycle. Still honest: pre-ban tokens carry no claim and live until exp.
import os
SVC = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip().strip('"')
check("6a proof environment: service-role key available (run_phase0.sh)", bool(SVC), "exported by run_phase0.sh")

def svc_rpc(name, body):
    h = {"apikey": SVC, "authorization": f"Bearer {SVC}", "content-type": "application/json"}
    req = urllib.request.Request(f"{A_API}/rest/v1/rpc/{name}",
                                 data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]

def admin_patch(uid_, body_):
    # Admin user update: some GoTrue builds expose PUT, others PATCH —
    # try both (405 = "wrong verb on this build").
    h = {"apikey": A_ANON, "authorization": f"Bearer {SVC}", "content-type": "application/json"}
    for m in ("PUT", "PATCH"):
        req = urllib.request.Request(f"{A_API}/auth/v1/admin/users/{uid_}",
                                     data=json.dumps(body_).encode(), headers=h, method=m)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            if e.code == 405:
                continue
            return e.code, e.read().decode()[:200]
    return 405, "both PUT and PATCH refused"

st, body = svc_rpc("auth_kit_set_ban", {"p_email": email,
                                        "p_banned_until": "2035-01-01T00:00:00Z",
                                        "p_reason": "proof kill-switch"})
check("6b ban written through the kit's service-role RPC", st == 200 and body is True,
      f"st={st} {str(body)[:140]}")

st, body = post(f"{A_API}/auth/v1/token?grant_type=password",
                {"email": email, "password": password}, {"apikey": A_ANON})
banned_jwt = body.get("access_token", "")
banned_claims = (json.loads(base64.urlsafe_b64decode(banned_jwt.split(".")[1] + "=="))
                 if banned_jwt else {})
check("6c fresh token carries the live kit_banned_until claim",
      st == 200 and str(banned_claims.get("kit_banned_until", "")).startswith("2035-01-01"),
      f"st={st} claims={json.dumps(banned_claims, default=str)[:180]}")

st, body = rest("GET", "/identity_proof", jwt=banned_jwt)
check("6d B: banned token's RLS view is empty", st == 200 and body == [],
      f"st={st} {str(body)[:140]}")
st, body = rest("POST", "/identity_proof", {"label": "banned tries to write"}, jwt=banned_jwt)
check("6e B: banned token cannot insert (RLS WITH CHECK denies)",
      st in (401, 403, 404), f"st={st} {str(body)[:140]}")
st, body = rest("POST", "/rpc/whoami", {}, jwt=banned_jwt)
check("6f B: whoami() is null for the banned token", st == 200 and body is None,
      f"st={st} {str(body)[:140]}")
st, body = rest("POST", "/rpc/jwt_debug", {}, jwt=banned_jwt)
check("6g B: the claim rides the token itself (jwt_debug sees it)",
      st == 200 and isinstance(body, str) and "kit_banned_until" in body,
      f"st={st} {str(body)[:180]}")

st, body = rest("GET", "/identity_proof", jwt=jwt)
check("6h B: the PRE-ban token is still honored (stateless until exp; documented)",
      st == 200 and len(body) == 1, f"st={st} {str(body)[:140]}")

# GoTrue's native ban (what the kit's edge functions set via the admin
# API) closes the AUTH plane: sign-in and refresh refuse outright.
st, body = admin_patch(uid, {"ban_duration": "876000h"})
check("6i A: native ban set through the admin API", st == 200, f"st={st} {str(body)[:140]}")
st, body = post(f"{A_API}/auth/v1/token?grant_type=password",
                {"email": email, "password": password}, {"apikey": A_ANON})
check("6j A: sign-in refused while natively banned", st in (400, 403),
      f"st={st} {str(body)[:140]}")
st, body = admin_patch(uid, {"ban_duration": "none"})
check("6k A: native ban lifted", st == 200, f"st={st} {str(body)[:140]}")

# The two planes are independent: auth open again (native lifted), data
# still closed (kit claim live) — then the kit RPC reopens data too.
st, body = post(f"{A_API}/auth/v1/token?grant_type=password",
                {"email": email, "password": password}, {"apikey": A_ANON})
still_claimed = (json.loads(base64.urlsafe_b64decode(body["access_token"].split(".")[1] + "=="))
                 if st == 200 and body.get("access_token") else {})
check("6l A: auth-plane open again, data-plane claim still live",
      st == 200 and "kit_banned_until" in still_claimed,
      f"st={st} claims={json.dumps(still_claimed, default=str)[:160]}")

st, body = svc_rpc("auth_kit_set_ban", {"p_email": email, "p_banned_until": None})
check("6m kit RPC lifts the ban (null banned_until)", st == 200 and body is True,
      f"st={st} {str(body)[:140]}")

st, body = post(f"{A_API}/auth/v1/token?grant_type=password",
                {"email": email, "password": password}, {"apikey": A_ANON})
clean_jwt = body.get("access_token", "")
clean_claims = (json.loads(base64.urlsafe_b64decode(clean_jwt.split(".")[1] + "=="))
                if clean_jwt else {})
check("6n A: fresh token is claim-free again", st == 200 and "kit_banned_until" not in clean_claims,
      f"st={st} claims={json.dumps(clean_claims, default=str)[:160]}")
st, body = rest("POST", "/rpc/whoami", {}, jwt=clean_jwt)
check("6o B: access fully restored after the unban", st == 200 and body == uid,
      f"st={st} {str(body)[:140]}")

print("\nCENTRAL-IDENTITY PROOF: ALL PASS" if all(results) else "\nFAILURES PRESENT")
