#!/usr/bin/env python3
"""End-to-end smoke test for the email-auth-kit edge functions.

Drives: confirmation-code request -> verify (with wrong-code + lockout
counters) -> signup (autoconfirm OFF) -> reset link -> confirm -> temp
password extracted from the mailbox -> real sign-in. Mail is captured by
Mailpit; DB assertions go through psql.
"""
import json, re, subprocess, sys, time, urllib.request

API = "http://127.0.0.1:54321"
EV = "http://127.0.0.1:8787"      # email-verification (host-run deno)
PR = "http://127.0.0.1:8788"      # password-reset   (host-run deno)
MAILPIT = "http://127.0.0.1:54324"
ANON = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
DB = "supabase_db_email-auth-kit-test"

def post(url, body, headers=None):
    h = {"content-type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
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

print("\nSMOKE SUITE: ALL PASS" if all(ok for _, ok in results) else "\nFAILURES PRESENT")
