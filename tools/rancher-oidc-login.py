#!/usr/bin/env python3
"""Log in to Rancher through Keycloak the way a browser would (authorization
code flow) and print a Rancher API token. Used by `hpcctl verify`.

usage: rancher-oidc-login.py <rancher-url> <username>   (password in $OIDC_PASSWORD)
"""
import html
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

rancher, username = sys.argv[1].rstrip("/"), sys.argv[2]
password = os.environ["OIDC_PASSWORD"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)


def fetch(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        r = opener.open(req, timeout=30)
    except urllib.error.HTTPError as e:
        r = e
    return r.status if hasattr(r, "status") else r.code, r.headers, r.read().decode(errors="replace")


_, _, body = fetch(rancher + "/v3-public/authProviders")
provider = next(p for p in json.loads(body)["data"] if p["id"] == "keycloakoidc")
auth_url = provider["redirectUrl"] + "&scope=" + urllib.parse.quote(provider["scopes"]) + "&state=verify"

status, headers, page = fetch(auth_url)
m = re.search(r'<form[^>]+id="kc-form-login"[^>]+action="([^"]+)"', page) or re.search(r'action="([^"]+)"', page)
if not m:
    sys.exit("no Keycloak login form (HTTP %s)" % status)
status, headers, page = fetch(html.unescape(m.group(1)),
                              urllib.parse.urlencode({"username": username, "password": password}).encode())
location = headers.get("Location", "")
if status != 302 or "code=" not in location:
    sys.exit("Keycloak rejected the login for %s (HTTP %s)" % (username, status))
code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)["code"][0]

status, _, body = fetch(provider["actions"]["login"],
                        json.dumps({"code": code, "responseType": "token", "description": "hpc-verify",
                                    "ttl": 600000}).encode(), {"Content-Type": "application/json"})
if status not in (200, 201):
    sys.exit("Rancher rejected the login for %s (HTTP %s): %s" % (username, status, body[:200]))
print(json.loads(body)["token"])
