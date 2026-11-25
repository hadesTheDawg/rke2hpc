#!/usr/bin/env python3
"""Log in to the cluster realm through the upstream identity provider, the way
a browser would: realm login -> upstream login form -> back through
Keycloak's broker (first-login flow links the account) -> authorization code ->
token. Prints the cluster realm's preferred_username. Used by verify.yml.

usage: upstream-login.py <keycloak-url> <realm> <idp-alias> <username>   (password in $UPSTREAM_PASSWORD)
Exits non-zero when any step refuses the login.
"""
import base64
import html
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

kc, realm, alias, username = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3], sys.argv[4]
password = os.environ["UPSTREAM_PASSWORD"]
REDIRECT = "http://localhost:8000/"
CLIENT = "kubernetes"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)


def fetch(url, data=None):
    req = urllib.request.Request(url, data=data)
    try:
        r = opener.open(req, timeout=30)
    except urllib.error.HTTPError as e:
        r = e
    return (r.status if hasattr(r, "status") else r.code), r.headers, r.read().decode(errors="replace")


def follow(status, headers, page, url):
    """Follow redirects until a page, or the client's redirect URI."""
    for _ in range(20):
        if status not in (301, 302, 303, 307):
            return status, page, url
        url = urllib.parse.urljoin(url, headers["Location"])
        if url.startswith(REDIRECT):
            return status, "", url
        status, headers, page = fetch(url)
    sys.exit("too many redirects")


def message(page):
    m = re.search(r'class="[^"]*(?:kc-feedback-text|alert-error|pf-m-danger)[^"]*"[^>]*>\s*(?:<[^>]+>\s*)*([^<]+)', page)
    return html.unescape(m.group(1).strip()) if m else "no login form"


auth = "%s/realms/%s/protocol/openid-connect/auth?%s" % (kc, realm, urllib.parse.urlencode({
    "client_id": CLIENT, "redirect_uri": REDIRECT, "response_type": "code", "scope": "openid",
    "state": "verify", "nonce": "verify", "kc_idp_hint": alias}))
status, page, url = follow(*fetch(auth), auth)
m = re.search(r'<form[^>]+id="kc-form-login"[^>]+action="([^"]+)"', page)
if not m:
    sys.exit("no upstream login form (HTTP %s at %s): %s" % (status, url.split("?")[0], message(page)))
action = html.unescape(m.group(1))
status, page, url = follow(*fetch(action, urllib.parse.urlencode(
    {"username": username, "password": password}).encode()), action)
if not url.startswith(REDIRECT):
    sys.exit("login of %s refused (HTTP %s at %s): %s" % (username, status, url.split("?")[0], message(page)))
code = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("code", [""])[0]
if not code:
    sys.exit("no authorization code for %s" % username)

status, _, body = fetch("%s/realms/%s/protocol/openid-connect/token" % (kc, realm), urllib.parse.urlencode({
    "grant_type": "authorization_code", "client_id": CLIENT, "code": code, "redirect_uri": REDIRECT}).encode())
if status != 200:
    sys.exit("token exchange failed (HTTP %s): %s" % (status, body[:200]))
payload = json.loads(body)["id_token"].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
print(claims.get("preferred_username", ""))
