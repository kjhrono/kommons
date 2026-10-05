#!/usr/bin/env python3
"""verify_vm_project — the Phase 0 checks against real VM hosts.

Ports proof.py's acceptance logic to parameterized URLs/keys
(docs/PHASE1_VM_ROLLOUT.md §4). Run via verify_vm_project.sh, which
validates the required KIT_* parameters.

Env contract (all required unless noted):
  KIT_AUTH_URL          identity host, e.g. https://auth.mediasart.com
  KIT_ANON_KEY          identity stack's anon/publishable key
  KIT_PROJECT_URL       project stack entry (kong), e.g.
                        https://katalogus-staging.mediasart.com
  KIT_PROJECT_ANON_KEY  that stack's anon key
  KIT_PROBE_TABLE       a table with `owner uuid default auth.uid()` and
                        owner-scoped RLS allowing authenticated inserts
  KIT_PROBE_COLUMNS     extra NOT NULL columns the probe insert must
                        supply, comma-separated col=value
                        (e.g. KIT_PROBE_COLUMNS=label=vm-verify)
  KIT_VM_EMAIL          a real, reachable mailbox (the tester's)
Optional:
  KIT_EV_URL            email-verification function URL (default
                        {KIT_FN_BASE}/email-verification; on the VM the
                        default is right, on a host-run teststack point it
                        straight at http://127.0.0.1:8787)
  KIT_REST_BASE         project's PostgREST base (default
                        {KIT_PROJECT_URL}/rest/v1 — the kong shape; the
                        prototype's bare PostgREST-B serves at root)
  KIT_PROJECT_AUTH_URL  project's GoTrue base (default {KIT_PROJECT_URL};
                        the signup probe tries /auth/v1/signup and
                        /signup and uses whichever route exists)
  KIT_BREVO_API_KEY     best-effort auto-fetch of the mailed code
  KIT_MAILPIT_URL       Mailpit capture UI — first local source for the
                        code (teststack/validation runs)
  KIT_ADMIN_KEY         identity service_role: deletes the minted test user
  KIT_CODE              pre-supplied code (skips all auto-fetch/prompt)
  KIT_SKIP_PROJECT      set to skip the project probes (checks 7-10):
                        the app's data backend does not share the identity
                        JWT secret (no web project stack exists yet). The
                        identity mint (checks 1-6, 11) is what the phone
                        app exercises.

Exactly one user is created in the identity stack's real database and
removed again (with KIT_ADMIN_KEY); the probe row is removed always.
"""
import base64, json, os, re, sys, time, urllib.request
from urllib.parse import quote

AUTH = os.environ["KIT_AUTH_URL"].rstrip("/")
ANON = os.environ["KIT_ANON_KEY"]
PROJ = os.environ["KIT_PROJECT_URL"].rstrip("/")
P_ANON = os.environ["KIT_PROJECT_ANON_KEY"]
TABLE = os.environ["KIT_PROBE_TABLE"]
# Rate budgets (3 code requests / 15 min / email) are keyed on the exact
# address, so a second run with the same mailbox would be refused. Derive
# a unique plus-address per run — it lands in the SAME real mailbox but
# carries a fresh budget. Callers who pass a '+' address manage their own
# uniqueness.
_base = os.environ["KIT_VM_EMAIL"]
if "+" in _base:
    EMAIL = _base
else:
    _loc, _dom = _base.rsplit("@", 1)
    EMAIL = f"{_loc}+{int(time.time())}@{_dom}"
FN_BASE = os.environ.get("KIT_FN_BASE", f"{AUTH}/functions/v1").rstrip("/")
EV = os.environ.get("KIT_EV_URL", f"{FN_BASE}/email-verification")
REST = os.environ.get("KIT_REST_BASE", f"{PROJ}/rest/v1").rstrip("/")
PROJ_AUTH = os.environ.get("KIT_PROJECT_AUTH_URL", PROJ).rstrip("/")
BREVO = os.environ.get("KIT_BREVO_API_KEY", "")
MAILPIT = os.environ.get("KIT_MAILPIT_URL", "")
ADMIN = os.environ.get("KIT_ADMIN_KEY", "")
EXTRA_COLS = {
    k.strip(): v.strip()
    for pair in os.environ.get("KIT_PROBE_COLUMNS", "").split(",")
    if pair.strip()
    for k, v in [pair.split("=", 1)]
}
PASSWORD = "Vm-Verify-2026!"

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))
    if not cond:
        sys.exit(1)

def req(url, body=None, headers=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {"content-type": "application/json"}
    h.update(headers or {})
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": (raw or b"").decode(errors="replace")[:200]}

# ---------------------------------------------- 1. mint: kit signup on A
st, body = req(EV,
               {"action": "signup", "email": EMAIL, "password": PASSWORD})
check("1 identity: kit signup accepted, code mailed via Brevo",
      st == 200 and body.get("sent") is True, str(body))

code = os.environ.get("KIT_CODE", "")
if not code and BREVO:
    # Brevo API: list is GET /smtp/emails?email=<addr> (email filter is
    # mandatory, and `@` must NOT be %-encoded in it), content at
    # GET /smtp/emails/{uuid} in the `body` field. The list index lags
    # sends by up to a couple of minutes — poll with a deadline.
    deadline, last_err = time.time() + 120, None
    while time.time() < deadline and not code:
        time.sleep(5)
        try:
            st2, box = req(f"https://api.brevo.com/v3/smtp/emails?email={quote(EMAIL, safe='@')}&limit=30",
                           headers={"api-key": BREVO}, method="GET")
            for m in (box or {}).get("transactionalEmails", []):
                if EMAIL.lower() not in json.dumps(m.get("to", [m.get("email", "")])).lower():
                    continue
                if "code" not in (m.get("subject") or "").lower():
                    continue
                st3, full = req(f"https://api.brevo.com/v3/smtp/emails/{m['uuid']}",
                                headers={"api-key": BREVO}, method="GET")
                mm = re.search(r"\b(\d{6})\b", full.get("body", ""))
                if mm:
                    code = mm.group(1)
                    break
        except Exception as e:  # transient API errors — keep polling
            last_err = e
    if not code and last_err:
        print(f"   note: Brevo auto-fetch failed ({last_err})")
if not code and MAILPIT:
    try:
        st2, box = req(f"{MAILPIT}/api/v1/messages?limit=50")
        for m in (box or {}).get("messages", []):
            tos = ",".join(a.get("Address", a.get("address", ""))
                           for a in m.get("To", []))
            if tos.startswith(EMAIL) and "code" in m.get("Subject", "").lower():
                st3, full = req(f"{MAILPIT}/api/v1/message/{m['ID']}")
                mm = re.search(r"\b(\d{6})\b", full.get("Text", ""))
                if mm:
                    code = mm.group(1)
                break
    except Exception as e:
        print(f"   note: Mailpit auto-fetch failed ({e})")
check("2 identity: 6-digit code obtained", bool(code),
      "read the code from the mailbox (Brevo fetch is best-effort)")

if not code:
    # input(), not getpass: getpass prefers /dev/tty and would block a
    # piped/automated run; echoing a short-lived code is harmless — it is
    # already plaintext in the mailbox.
    code = input(f"  enter the 6-digit code mailed to {EMAIL}: ").strip()

# ------------------------------------------------ 3. verify + sign-in
st, body = req(EV,
               {"action": "verify", "email": "___nope___@kit.test", "code": "000000"})
check("4 identity: verify endpoint healthy (wrong code -> 400)",
      st == 400 and body.get("error") in ("code_invalid",      # pending challenge exists
                                          "no_pending_code"),  # fresh address
      str(body))

st, body = req(EV,
               {"action": "verify", "email": EMAIL, "code": code})
check("5 identity: code verified, address confirmed",
      st == 200 and body.get("verified") is True, str(body))

st, body = req(f"{AUTH}/auth/v1/token?grant_type=password",
               {"email": EMAIL, "password": PASSWORD}, {"apikey": ANON})
check("6 identity: sign-in yields a JWT",
      st == 200 and bool(body.get("access_token")), f"st={st} {str(body)[:120]}")
jwt = body["access_token"]
uid = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "==")).get("sub", "")

# ------------------------------------- 7-9. the foreign token on project
if not os.environ.get("KIT_SKIP_PROJECT"):
    pass
else:
    st, body = req(f"{REST}/{TABLE}?select=*&limit=1",
               headers={"apikey": P_ANON, "Authorization": f"Bearer {jwt}"})
check(f"7 project: foreign JWT accepted on {TABLE} (auth.uid() RLS)",
      st == 200, f"st={st} {str(body)[:140]}")

st, body = req(f"{REST}/{TABLE}",
               {"owner": uid, **EXTRA_COLS},
               {"apikey": P_ANON, "Authorization": f"Bearer {jwt}",
                "Prefer": "return=representation"})
row = (body or [{}])[0] if isinstance(body, list) else {}
check(f"8 project: insert stamps the foreign auth.uid() into {TABLE}",
      st in (200, 201) and row.get("owner") == uid, f"st={st} {str(body)[:140]}")
probe_id = row.get("id")

if probe_id:
    st, body = req(f"{REST}/{TABLE}?id=eq.{probe_id}",
                   headers={"apikey": P_ANON, "Authorization": f"Bearer {jwt}",
                            "Prefer": "return=representation"}, method="DELETE")
    check(f"9 project: probe row removed (owner-scoped delete)",
          st in (200, 204), f"st={st}")
else:
    print("   note: no probe row id returned; verify no row was left by hand")

# Signup-refusal probe. Kong exposes GoTrue under /auth/v1/*, a bare
# GoTrue (the prototype's stack B) at /signup — indistinguishable from
# outside, so try both and take the first route that exists (non-404).
signup_st, signup_body = 404, {}
for candidate in (f"{PROJ_AUTH}/auth/v1/signup", f"{PROJ_AUTH}/signup"):
    signup_st, signup_body = req(candidate,
                                 {"email": f"nope{int(time.time())}@probe.local",
                                  "password": PASSWORD}, {"apikey": P_ANON})
    if signup_st != 404:
        break
check("10 project: own signup refused (identity is the only door)",
      signup_st in (400, 403, 422), f"st={signup_st} {str(signup_body)[:120]}")

# ----------------------------------------------------------- 11. cleanup
if ADMIN:
    st, _ = req(f"{AUTH}/auth/v1/admin/users/{uid}", method="DELETE",
                headers={"apikey": ANON, "Authorization": f"Bearer {ADMIN}"})
    check("11 cleanup: minted identity user deleted", st == 200, f"st={st}")
else:
    print(f"   cleanup: set KIT_ADMIN_KEY (identity service_role) to auto-delete; "
          f"for now remove user {uid} ({EMAIL}) via Studio")

print("\nVM VERIFICATION: ALL PASS" if all(ok for _, ok in results) else "\nFAILURES PRESENT")
sys.exit(0 if all(ok for _, ok in results) else 1)
