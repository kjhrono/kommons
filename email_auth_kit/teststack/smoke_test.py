#!/usr/bin/env python3
"""End-to-end smoke test for the email-auth-kit edge functions.

Drives: confirmation-code request -> verify (with wrong-code + lockout
counters) -> signup (autoconfirm OFF) -> reset link -> confirm -> temp
password extracted from the mailbox -> real sign-in -> Google identity
linking (the hosted-authorize remedy). Mail is captured by Mailpit; DB
assertions go through psql.
"""
import hashlib, json, os, re, subprocess, sys, time, urllib.request

# Driven by run_phase0.sh-style env when present (any teststack restart
# regenerates the API keys and Mailpit's address, so the defaults below
# are only a convenience for manual runs against a long-lived stack).
API = os.environ.get("KIT_API_URL", "http://127.0.0.1:54321")
EV = os.environ.get("KIT_EV_URL", "http://127.0.0.1:8787")     # email-verification
PR = os.environ.get("KIT_PR_URL", "http://127.0.0.1:8788")     # password-reset
MAILPIT = os.environ.get("KIT_MAILPIT_URL", "http://127.0.0.1:54324")
ANON = os.environ.get("KIT_ANON_KEY",
                      "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH")
DB = os.environ.get("KIT_DB_CONTAINER", "supabase_db_email-auth-kit-test")

def post(url, body, headers=None):
    h = {"content-type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def psql(sql):
    out = subprocess.run(["docker", "exec", DB, "psql", "-U", "postgres", "-tAc", sql],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"psql failed: {out.stderr.strip()}")
    return out.stdout.strip()

def latest_mail(to_prefix, subject_contains, tries=6):
    """Newest Mailpit message to `to_prefix` whose subject contains the text."""
    for _ in range(tries):
        with urllib.request.urlopen(f"{MAILPIT}/api/v1/messages?limit=50") as r:
            box = json.loads(r.read())
        for m in box.get("messages", []):
            tos = ",".join(a.get("Address", a.get("address", "")) for a in m.get("To", []))
            if tos.startswith(to_prefix) and subject_contains.lower() in m.get("Subject", "").lower():
                with urllib.request.urlopen(f"{MAILPIT}/api/v1/message/{m['ID']}") as r:
                    return json.loads(r.read())
        time.sleep(1)
    raise AssertionError(f"no mail to {to_prefix} with subject ~ '{subject_contains}'")

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))
    if not cond:
        sys.exit(1)

# ---------------------------------------------------------------- step 1
email = f"alice{int(time.time())}@kit.test"
st, body = post(f"{EV}", {"action": "request", "email": email})
check("1a code request accepted", st == 200 and body.get("sent") is True, str(body))
check("1b mail really delivered via SMTP", body.get("delivered") is True, str(body))
mail = latest_mail(email, "confirmation code")
code_m = re.search(r"\b(\d{6})\b", mail.get("Text", ""))
code = code_m.group(1) if code_m else ""
check("1c 6-digit code found in the mailbox", bool(code), mail.get("Text", "")[:120])
row = psql(f"select kind, attempts, consumed_at is null from auth_events where email='{email}' order by created_at desc limit 1")
check("1d challenge row stored hashed+pending", row.startswith("email_code|0|t"), row)

# ---------------------------------------------------------------- step 2
st, body = post(f"{EV}", {"action": "verify", "email": email, "code": "000000"})
check("2a wrong code rejected with attempts_left", st == 400 and body.get("error") == "code_invalid" and body.get("attempts_left", 0) >= 4, str(body))

# ------------------------------------------------------- step 3: signup
password = "Str0ngPass!2026"
st, body = post(f"{API}/auth/v1/signup", {"email": email, "password": password}, {"apikey": ANON})
check("3a signup accepted, unconfirmed (autoconfirm off)", st == 200 and body.get("session") in (None, ""), str(body)[:160])
uid = psql(f"select id from auth.users where email='{email}'")
conf = psql(f"select email_confirmed_at is not null from auth.users where email='{email}'")
check("3b user exists and is NOT yet confirmed", bool(uid) and conf == "f", f"uid={uid} confirmed={conf}")

# ------------------------------------------------- step 2b: now verify
st, body = post(f"{EV}", {"action": "verify", "email": email, "code": code})
check("2b correct code verifies", st == 200 and body.get("verified") is True, str(body))
row = psql(f"select consumed_at is not null from auth_events where email='{email}' and kind='email_code' order by created_at desc limit 1")
check("2c code single-use (consumed)", row == "t", row)
conf = psql(f"select email_confirmed_at is not null from auth.users where email='{email}'")
check("3c verify flipped the confirmation", conf == "t", conf)

# ---------------------------------------------------------------- step 4
st, body = post(f"{PR}", {"action": "request", "email": email, "redirect_to": "https://katalogus.mediasart.com/reset"})
check("4a reset link request accepted", st == 200 and body.get("sent") is True, str(body))
mail = latest_mail(email, "reset your password")
link_m = re.search(r"https?://\S+", mail.get("Text", ""))
check("4b reset link present in the mail", bool(link_m), mail.get("Text", "")[:160])
tok_m = re.search(r"token=([0-9a-f]{64})", link_m.group(0)) if link_m else None
token = tok_m.group(1) if tok_m else ""
check("4c 64-hex token embedded in the link", bool(token), link_m.group(0) if link_m else "")

# ---------------------------------------------------------------- step 5
st, body = post(f"{PR}", {"action": "confirm", "email": email, "token": "f" * 64})
check("5a wrong token rejected", st == 400 and body.get("error") == "token_invalid", str(body))
st, body = post(f"{PR}", {"action": "confirm", "email": email, "token": token})
check("5b confirm sets temp password", st == 200 and body.get("temp_password_sent") is True and body.get("must_change_password") is True, str(body))
mail = latest_mail(email, "temporary password")
html = mail.get("HTML", "") or ""
tmp_m = re.search(r'border-radius:6px\">([^<]+)</p>', html)
temp = tmp_m.group(1).strip() if tmp_m else ""
check("5c temp password delivered to the mailbox", len(temp) >= 10, (html or mail.get("Text", ""))[:160])
st, body = post(f"{API}/auth/v1/token?grant_type=password", {"email": email, "password": password}, {"apikey": ANON})
check("5d old password now rejected", st == 400, f"st={st}")

# ---------------------------------------------------------------- step 6
st, body = post(f"{API}/auth/v1/token?grant_type=password", {"email": email, "password": temp}, {"apikey": ANON})
check("6 sign-in with the e-mailed temp password works", st == 200 and bool(body.get("access_token")), f"st={st} {str(body)[:120]}")
jwt = body.get("access_token", "")
jwt_uid = (body.get("user") or {}).get("id", "")

# ---------------------------------------------------------------- step 7
# The optional "your password was changed" notice: the notify action is
# deployed with --no-verify-jwt, so it verifies the caller's JWT itself
# (anon client + GoTrue getUser) and refuses anyone but the caller.
check("7a the JWT belongs to the DB user", jwt_uid == uid, f"jwt={jwt_uid} db={uid}")

st, body = post(f"{PR}", {"action": "notify", "user_id": jwt_uid})
check("7b notify without a bearer is rejected", st == 401 and body.get("error") == "missing_bearer", str(body))

st, body = post(
    f"{PR}",
    {"action": "notify", "user_id": jwt_uid},
    {"authorization": f"Bearer {jwt}", "apikey": ANON},
)
check("7c notify with the user's own JWT fires", st == 200 and body.get("notified") is True, str(body))
mail = latest_mail(email, "password was changed")
check("7d the notice really arrived", "changed" in (mail.get("Subject") or "").lower(), mail.get("Subject", ""))

st, body = post(
    f"{PR}",
    {"action": "notify", "user_id": "00000000-0000-0000-0000-000000000000"},
    {"authorization": f"Bearer {jwt}", "apikey": ANON},
)
check("7e a mismatched user_id is refused", st == 403 and body.get("error") == "user_mismatch", str(body))

# ---------------------------------------------------------------- step 8
# ban-management (the kill-switch's ops surface). EVERY action is gated:
# the bearer must be the exact service-role key (the kit's functions run
# behind VERIFY_JWT=false, so an exact-secret match — not a decodable
# claim — is the unforgable credential). Read-only actions get the key
# here; the gate itself is exercised with and without it.
BM = os.environ.get("KIT_BM_URL", "http://127.0.0.1:8789")
SVC = os.environ.get("KIT_SVC_KEY", "")
BM_H = {"authorization": f"Bearer {SVC}"} if SVC else {}

st, body = post(f"{BM}", {"action": "status", "email": f"nobody{int(time.time())}@kit.test"})
check("8a status without a bearer is refused (every action gated)",
      st == 401 and body.get("error") == "service_role_required", f"st={st} {str(body)[:120]}")
st, body = post(f"{BM}", {"action": "ban", "email": email, "until": "2035-01-01T00:00:00Z"})
check("8b ban without the service-role key refused", st == 401, f"st={st} {str(body)[:120]}")

if BM_H:
    st, body = post(f"{BM}", {"action": "status", "email": f"nobody{int(time.time())}@kit.test"}, BM_H)
    check("8c status with the key: unknown address reported honestly",
          st == 200 and body.get("known") is False, f"st={st} {str(body)[:120]}")
    st, body = post(f"{BM}", {"action": "list"}, BM_H)
    check("8d list with the key answers", st == 200 and isinstance(body.get("bans"), list),
          f"st={st} {str(body)[:120]}")
    st, body = post(f"{BM}", {"action": "ban", "email": email,
                              "until": "2035-01-01T00:00:00Z", "reason": "smoke"}, BM_H)
    check("8e ban drives both planes (kit claim + native)", st == 200 and body.get("banned") is True
          and body.get("native_ban") is True, f"st={st} {str(body)[:140]}")
    row = psql(f"select banned_until::text from auth_kit_bans where user_id='{uid}'")
    check("8f kit ban row present", row.startswith("2035-01-01"), row)
    st, body = post(f"{BM}", {"action": "status", "email": email}, BM_H)
    check("8g status reflects the ban", st == 200 and body.get("banned") is True
          and body.get("native_ban") is True, f"st={st} {str(body)[:160]}")
    st, body = post(f"{BM}", {"action": "unban", "email": email}, BM_H)
    check("8h unban lifts both planes", st == 200 and body.get("banned") is False
          and body.get("kit_lifted") is True and body.get("native_lifted") is True,
          f"st={st} {str(body)[:140]}")
    row = psql(f"select count(*) from auth_kit_bans where user_id='{uid}'")
    check("8i kit ban row removed", row == "0", row)
else:
    check("8c KIT_SVC_KEY provided (bearer-gated checks skipped)", False,
          "export KIT_SVC_KEY via run_phase0.sh")

# ---------------------------------------------------------------- step 9
# Google identity linking (the hosted-authorize remedy). A real
# Google OAuth sign-in mints a STRANGER account: a fresh user
# carrying exactly one google identity whose identity_data email
# matches the password member's address. The member proved the
# account by signing in with the password (alice's `jwt` from
# step 6); the app now moves the identity onto that account.
# NB: auth.identities.email is a GENERATED column in this GoTrue
# generation — insert identity_data only, never the email.
def mint_google_stranger(tag, google_email):
    """Fresh signup user whose email identity is swapped for a
    google one — what a hosted-authorize Google sign-in leaves
    behind. Returns (user id, google provider id)."""
    address = f"{tag}{int(time.time())}@kit.test"
    post(f"{API}/auth/v1/signup", {"email": address, "password": password},
         {"apikey": ANON})
    stranger = psql(f"select id from auth.users where email='{address}'")
    sub = f"gsub-{tag}-{int(time.time())}"
    psql(f"delete from auth.identities where user_id='{stranger}' and provider='email'")
    psql(f"insert into auth.identities (provider_id, user_id, identity_data, provider) "
         f"values ('{sub}', '{stranger}', "
         f"jsonb_build_object('email','{google_email}','sub','{sub}'), 'google')")
    return stranger, sub

rpc = f"{API}/rest/v1/rpc/auth_kit_link_google_identity"
link_headers = {"apikey": ANON, "authorization": f"Bearer {jwt}"}

stranger, gsub = mint_google_stranger("gstranger", email)
row = psql(f"select provider, email from auth.identities where user_id='{stranger}'")
check("9a the minted stranger carries exactly one google identity with the member's email",
      row == f"google|{email}", row)

st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": stranger,
                      "p_expected_email": email}, link_headers)
check("9b link with the member's JWT answers true", st == 200 and body is True, f"st={st} {body}")
owner = psql(f"select user_id from auth.identities where provider='google' and provider_id='{gsub}'")
check("9c the identity now sits on the password account", owner == uid, f"owner={owner} member={uid}")
check("9d the minted stranger is deleted",
      psql(f"select count(*) from auth.users where id='{stranger}'") == "0")
providers = psql(f"select raw_app_meta_data->'providers' from auth.users where id='{uid}'")
check("9e the member's provider metadata gains google", '"google"' in providers, providers)
expected_hash = hashlib.sha256(gsub.encode()).hexdigest()
row = psql(f"select kind, code_hash from auth_events where kind='identity_linked' "
           f"and email='{email}' order by created_at desc limit 1")
check("9f audit row written with the sha256 of the google sub",
      row == f"identity_linked|{expected_hash}", f"{row} != identity_linked|{expected_hash}")

st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": stranger,
                      "p_expected_email": email}, link_headers)
check("9g a replay (stranger already gone) is idempotent: false, not an error",
      st == 200 and body is False, f"st={st} {body}")

# Refusals — each maps to a typed client reason.
mismatch_stranger, _ = mint_google_stranger("gmismatch", "other@example.com")
st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": mismatch_stranger,
                      "p_expected_email": email}, link_headers)
check("9h a stranger with a different google email is refused: email_mismatch",
      st == 400 and body.get("message") == "email_mismatch", f"st={st} {body}")
# An EXISTING account without a google identity (a fresh signup
# keeps its email identity) is not a minted stranger.
plain = f"plain{int(time.time())}@kit.test"
post(f"{API}/auth/v1/signup", {"email": plain, "password": password}, {"apikey": ANON})
plain_uid = psql(f"select id from auth.users where email='{plain}'")
st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": plain_uid,
                      "p_expected_email": email}, link_headers)
check("9i an account without a google identity is refused: google_identity_missing",
      st == 400 and body.get("message") == "google_identity_missing", f"st={st} {body}")
st, body = post(rpc, {"p_password_session": "not-a-jwt", "p_google_user_id": stranger,
                      "p_expected_email": email}, link_headers)
check("9j a malformed session JWT is refused: invalid_session",
      st == 400 and body.get("message") == "invalid_session", f"st={st} {body}")
st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": stranger,
                      "p_expected_email": email}, {"apikey": ANON})
check("9k anon (no member JWT) is refused: execute revoked from anon",
      st == 401 and "permission denied" in body.get("message", ""), f"st={st} {body}")

# The race the row lock closes: another transaction moves the
# identity while the RPC sits between its proof-2 read and its
# locked re-read. The RPC must see the move and refuse — never
# steal an identity that found a new owner mid-flight.
third, gsub3 = mint_google_stranger("grace", email)
fourth = f"fourth{int(time.time())}@kit.test"
post(f"{API}/auth/v1/signup", {"email": fourth, "password": password}, {"apikey": ANON})
fourth_uid = psql(f"select id from auth.users where email='{fourth}'")
mover = subprocess.Popen(
    ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-tAc",
     f"begin; update auth.identities set user_id='{fourth_uid}' "
     f"where provider='google' and provider_id='{gsub3}'; "
     f"select pg_sleep(4); commit;"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(1.5)  # let the uncommitted move take its row lock
st, body = post(rpc, {"p_password_session": jwt, "p_google_user_id": third,
                      "p_expected_email": email}, link_headers)
check("9l a mid-flight identity move is refused: identity_owned_elsewhere",
      st == 400 and body.get("message") == "identity_owned_elsewhere", f"st={st} {body}")
mover.wait(timeout=20)
check("9m the racing move really committed (identity kept its new owner)",
      psql(f"select user_id from auth.identities where provider_id='{gsub3}'") == fourth_uid)

print("\nSMOKE SUITE: ALL PASS" if all(ok for _, ok in results) else "\nFAILURES PRESENT")
