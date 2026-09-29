#!/usr/bin/env python3
"""Mint a session on identity stack A for a given email+password (the
account must already exist and be confirmed). Prints the access token."""
import json, sys, urllib.request

A_API = "http://127.0.0.1:54321"
ANON = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"

email, password = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"{A_API}/auth/v1/token?grant_type=password",
    data=json.dumps({"email": email, "password": password}).encode(),
    headers={"content-type": "application/json", "apikey": ANON},
    method="POST",
)
try:
    body = json.loads(urllib.request.urlopen(req).read())
    print(body["access_token"])
except urllib.error.HTTPError as e:
    print(f"sign-in failed: {e.code} {e.read().decode()[:200]}", file=sys.stderr)
    sys.exit(1)
