#!/usr/bin/env python3
"""Read an upstream identity provider's OpenID configuration and print it as
normalised JSON (deployer side, Python 3 standard library only).

usage: oidc_config.py file <path>     a saved document
       oidc_config.py url  <url>      fetch it (for checking from the deployer)

The file is either the provider's .well-known/openid-configuration document
as it is (JSON), or a flat file with one "key: value" (or "key = value") per
line, using the same key names:

    # site IdP, given to us by the identity team
    issuer:                 https://login.example.org/realms/staff
    authorization_endpoint: https://login.example.org/realms/staff/protocol/openid-connect/auth
    token_endpoint:         https://login.example.org/realms/staff/protocol/openid-connect/token
    jwks_uri:               https://login.example.org/realms/staff/protocol/openid-connect/certs
    userinfo_endpoint:      https://login.example.org/realms/staff/protocol/openid-connect/userinfo
    end_session_endpoint:   https://login.example.org/realms/staff/protocol/openid-connect/logout
    code_challenge_methods_supported: S256
    token_endpoint_auth_methods_supported: client_secret_post, client_secret_basic

Keys ending in _supported take a list (comma- or space-separated).
"""
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request

REQUIRED = ("issuer", "authorization_endpoint", "token_endpoint", "jwks_uri")
URL_KEYS = REQUIRED[1:] + ("userinfo_endpoint", "end_session_endpoint")


def parse_flat(text):
    doc = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_]+)\s*[:=]\s*(.*)$", line)
        if not m:
            sys.exit("line %d: expected 'key: value', got: %s" % (n, raw))
        key, value = m.group(1), m.group(2).strip().strip('"').strip("'")
        if key.endswith("_supported"):
            doc[key] = [v for v in re.split(r"[,\s]+", value) if v]
        else:
            doc[key] = value
    return doc


def parse(text):
    text = text.lstrip("﻿")
    if text.lstrip().startswith("{"):
        try:
            doc = json.loads(text)
        except ValueError as e:
            sys.exit("not valid JSON: %s" % e)
        if not isinstance(doc, dict):
            sys.exit("the JSON document must be an object")
        return doc
    return parse_flat(text)


def check(doc):
    problems = ["missing %s" % k for k in REQUIRED if not doc.get(k)]
    for k in ("issuer",) + URL_KEYS:
        v = doc.get(k)
        if v and urllib.parse.urlparse(v).scheme != "https":
            problems.append("%s is not an https URL: %s" % (k, v))
    if problems:
        sys.exit("upstream OpenID configuration: " + "; ".join(problems))
    return doc


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("file", "url"):
        sys.exit(__doc__)
    if sys.argv[1] == "file":
        with open(sys.argv[2], encoding="utf-8") as f:
            text = f.read()
    else:
        with urllib.request.urlopen(sys.argv[2], context=ssl.create_default_context(), timeout=30) as r:
            text = r.read().decode()
    print(json.dumps(check(parse(text)), sort_keys=True))


if __name__ == "__main__":
    main()
