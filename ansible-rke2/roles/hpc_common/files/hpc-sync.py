#!/usr/bin/env python3
"""hpc-sync: reconcile identity and tenancy from the admin node.

Installed on the admin node as /usr/local/sbin/hpc-sync and driven by the
identity and tenants Ansible roles. Python 3.9 standard library only.
The flat file is read by hpc_flatfile.py (installed next to this tool in
/usr/local/lib/hpc); its FIELDS table defines the file format.

  hpc-sync identity   Keycloak realm + clients, Rancher <-> Keycloak login,
                      platform administrators
  hpc-sync tenants    project groups from the flat file: unix ids, home
                      directories, namespaces/quotas/isolation, Rancher
                      projects, Keycloak users and groups

Settings and secrets come from the environment (config/site.env plus what the
module passes in). Every step is idempotent.
"""
import base64
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

E = os.environ
CA_FILE = "/etc/pki/hpc/ca.crt"
STATE_DIR = "/var/lib/hpc"
IDMAP_FILE = STATE_DIR + "/idmap.json"
ACCOUNTS_FILE = STATE_DIR + "/accounts.json"
PROJECTS_FILE = "/etc/hpc/projects.txt"
PROJECTS_JSON = STATE_DIR + "/projects.json"      # parsed flat file, read by hpc-acct
LIB_DIR = "/usr/local/lib/hpc"                   # hpc_flatfile.py
KUBECTL = ["/var/lib/rancher/rke2/bin/kubectl", "--kubeconfig", "/etc/rancher/rke2/rke2.yaml"]

REALM = E.get("KEYCLOAK_REALM", "hpc")
KC_URL = "https://" + E.get("KEYCLOAK_HOST", "")
RANCHER_URL = "https://" + E.get("RANCHER_HOST", "")
GROUP_PREFIX = E.get("OIDC_GROUP_PREFIX", "oidc:")
ADMIN_GROUP = E.get("PLATFORM_ADMIN_GROUP", "hpc-admins")
APPS_DOMAIN = E.get("APPS_DOMAIN", "")
RANCHER_PROVIDER = "keycloakoidc"


def log(msg):
    print("    [hpc-sync] " + msg, file=sys.stderr, flush=True)


def die(msg):
    print("error: [hpc-sync] " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def truthy(name):
    return E.get(name, "").lower() == "true"


# --------------------------------------------------------------------------- kubectl
def kubectl(*args, stdin=None, check=True):
    p = subprocess.run(KUBECTL + list(args), input=stdin, capture_output=True, text=True)
    if check and p.returncode != 0:
        die("kubectl %s failed: %s" % (" ".join(args[:4]), p.stderr.strip()))
    return p.stdout


def kget(*args):
    """kubectl get ... -o json, or None when the object (or its CRD) is absent."""
    p = subprocess.run(KUBECTL + ["get"] + list(args) + ["-o", "json"], capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else None


def kapply(objs):
    if objs:
        doc = {"apiVersion": "v1", "kind": "List", "items": objs}
        kubectl("apply", "--server-side", "--force-conflicts", "--field-manager=hpc-sync", "-f", "-",
                stdin=json.dumps(doc))


# --------------------------------------------------------------------------- http
class Http:
    def __init__(self):
        # The site CA bundle plus the system store: an upstream identity
        # provider may have a certificate from a public CA.
        self.ctx = ssl.create_default_context()
        self.ctx.load_verify_locations(cafile=CA_FILE)

    def call(self, method, url, body=None, headers=None, form=None, ok=(200, 201, 204)):
        hdrs = dict(headers or {})
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as r:
                status, raw, rhdrs = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            status, raw, rhdrs = e.code, e.read(), e.headers
        if ok and status not in ok:
            die("%s %s -> HTTP %s: %s" % (method, url, status, raw[:400].decode(errors="replace")))
        parsed = None
        if raw:
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = raw.decode(errors="replace")
        return status, parsed, rhdrs


HTTP = Http()


# --------------------------------------------------------------------------- keycloak
class Keycloak:
    """Minimal admin REST client; authenticates as the bootstrap admin."""

    def __init__(self):
        sec = kget("secret", "keycloak-credentials", "-n", "keycloak")
        if not sec:
            die("Keycloak is not deployed (run site.yml --tags keycloak)")
        self.password = base64.b64decode(sec["data"]["admin-password"]).decode()
        self.token = None
        self.expires = 0

    def _auth(self):
        if time.time() > self.expires - 10:
            _, tok, _ = HTTP.call("POST", KC_URL + "/realms/master/protocol/openid-connect/token", form={
                "grant_type": "password", "client_id": "admin-cli", "username": "admin", "password": self.password})
            self.token = tok["access_token"]
            self.expires = time.time() + tok.get("expires_in", 60)
        return {"Authorization": "Bearer " + self.token}

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        status, parsed, hdrs = HTTP.call(method, KC_URL + "/admin/realms" + path, body=body, headers=self._auth(), ok=ok)
        return status, parsed, hdrs

    def get(self, path, ok=(200,)):
        return self.call("GET", path, ok=ok)[1]

    # -- realm
    def ensure_realm(self, realm, display, extra=None):
        rep = {"realm": realm, "enabled": True, "displayName": display, "sslRequired": "all",
               "registrationAllowed": False, "loginWithEmailAllowed": False, "editUsernameAllowed": False,
               "resetPasswordAllowed": False, "bruteForceProtected": True, "accessTokenLifespan": 300}
        rep.update(extra or {})
        if self.call("GET", "/" + realm, ok=(200, 404))[0] == 404:
            self.call("POST", "", rep)
            log("keycloak: created realm %s" % realm)
        else:
            self.call("PUT", "/" + realm, rep)

    # -- clients
    def ensure_client(self, realm, rep, mappers):
        found = self.get("/%s/clients?clientId=%s" % (realm, urllib.parse.quote(rep["clientId"])))
        if found:
            cid = found[0]["id"]
            self.call("PUT", "/%s/clients/%s" % (realm, cid), dict(rep, id=cid))
        else:
            _, _, hdrs = self.call("POST", "/%s/clients" % realm, rep)
            cid = hdrs["Location"].rsplit("/", 1)[1]
            log("keycloak: created client %s in realm %s" % (rep["clientId"], realm))
        base = "/%s/clients/%s/protocol-mappers/models" % (realm, cid)
        have = {m["name"]: m for m in self.get(base)}
        for m in mappers:
            if m["name"] in have:
                self.call("PUT", "%s/%s" % (base, have[m["name"]]["id"]), dict(m, id=have[m["name"]]["id"]))
            else:
                self.call("POST", base, m)
        return cid

    # -- groups
    def group_id(self, realm, name):
        for g in self.get("/%s/groups?search=%s&exact=true" % (realm, urllib.parse.quote(name))):
            if g["name"] == name:
                return g["id"]
        return None

    def ensure_group(self, realm, name):
        gid = self.group_id(realm, name)
        if not gid:
            self.call("POST", "/%s/groups" % realm, {"name": name, "attributes": {"hpc-managed": ["true"]}})
            gid = self.group_id(realm, name)
            log("keycloak: created group %s" % name)
        return gid

    # -- users
    def user(self, realm, username):
        found = self.get("/%s/users?username=%s&exact=true" % (realm, urllib.parse.quote(username)))
        return found[0] if found else None

    def all_users(self, realm):
        out, first = [], 0
        while True:
            page = self.get("/%s/users?first=%d&max=200" % (realm, first))
            out += page
            if len(page) < 200:
                return out
            first += 200

    def ensure_user(self, realm, username, password, temporary, attributes=None):
        """Create the account if needed; an existing account keeps its password."""
        u = self.user(realm, username)
        if u:
            if not u.get("enabled", True):
                self.call("PUT", "/%s/users/%s" % (realm, u["id"]), dict(u, enabled=True))
                log("keycloak: re-enabled user %s" % username)
            return u["id"]
        rep = {"username": username, "enabled": True, "emailVerified": True,
               "email": "%s@%s" % (username, E["CLUSTER_DOMAIN"]), "firstName": username, "lastName": E["CLUSTER_NAME"],
               "attributes": attributes or {},
               "credentials": [{"type": "password", "value": password, "temporary": temporary}]}
        _, _, hdrs = self.call("POST", "/%s/users" % realm, rep)
        log("keycloak: created user %s in realm %s" % (username, realm))
        return hdrs["Location"].rsplit("/", 1)[1]

    def set_memberships(self, realm, uid, want_group_ids, managed_group_ids):
        """Make the user's membership in *managed* groups exactly want_group_ids."""
        have = {g["id"] for g in self.get("/%s/users/%s/groups" % (realm, uid))}
        for gid in want_group_ids - have:
            self.call("PUT", "/%s/users/%s/groups/%s" % (realm, uid, gid))
        for gid in (have & managed_group_ids) - want_group_ids:
            self.call("DELETE", "/%s/users/%s/groups/%s" % (realm, uid, gid))


def group_mapper(name="groups", claim="groups", full_path="false"):
    return {"name": name, "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
            "config": {"claim.name": claim, "full.path": full_path, "id.token.claim": "true",
                       "access.token.claim": "true", "userinfo.token.claim": "true"}}


def audience_mapper(name, client_id):
    return {"name": name, "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
            "config": {"included.client.audience": client_id, "id.token.claim": "true", "access.token.claim": "true"}}


# --------------------------------------------------------------------------- rancher
class Rancher:
    """Talks to the Rancher API as the local admin (password lives in the helm release)."""

    def __init__(self, password):
        self.token = None
        status, out, _ = HTTP.call("POST", RANCHER_URL + "/v3-public/localProviders/local?action=login",
                                   body={"username": "admin", "password": password, "ttl": 600000,
                                         "description": "hpc-sync"}, ok=None)
        if status not in (200, 201):
            die("cannot log in to Rancher as admin (HTTP %s)" % status)
        self.token = out["token"]

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        auth = base64.b64encode(self.token.encode()).decode()
        return HTTP.call(method, RANCHER_URL + path, body=body, headers={"Authorization": "Basic " + auth}, ok=ok)[1]

    def close(self):
        if self.token:
            HTTP.call("POST", RANCHER_URL + "/v3/tokens?action=logout", body={},
                      headers={"Authorization": "Bearer " + self.token}, ok=None)
            self.token = None


def rancher_present():
    return kget("crd", "projects.management.cattle.io") is not None


def rancher_principal(group):
    return "%s_group://%s" % (RANCHER_PROVIDER, group)


def rancher_allowed_principals(extra_groups):
    """Only members of a project group (or platform admins) may log in to Rancher."""
    groups = [ADMIN_GROUP] + sorted(extra_groups)
    return [rancher_principal(g) for g in groups]


def tenant_groups_in_cluster():
    nss = kget("namespaces", "-l", "hpc.io/tenant=true") or {"items": []}
    return {n["metadata"]["labels"].get("hpc.io/project") for n in nss["items"]} - {None}


# --------------------------------------------------------------------------- identity
def cmd_identity(inp):
    kc = Keycloak()
    kc.ensure_realm(REALM, "%s cluster" % E["CLUSTER_NAME"])

    # kubectl on the login node (kubelogin): public client, device flow.
    kc.ensure_client(REALM, {
        "clientId": "kubernetes", "name": "Kubernetes API (kubectl)", "enabled": True, "protocol": "openid-connect",
        "publicClient": True, "standardFlowEnabled": True, "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": truthy("KEYCLOAK_ALLOW_PASSWORD_GRANT"), "serviceAccountsEnabled": False,
        "redirectUris": ["http://localhost:8000/*", "http://localhost:18000/*"], "webOrigins": [],
        "attributes": {"oauth2.device.authorization.grant.enabled": "true", "pkce.code.challenge.method": ""},
    }, [group_mapper(), audience_mapper("audience", "kubernetes")])

    # Rancher dashboards: confidential client.
    kc.ensure_client(REALM, {
        "clientId": "rancher", "name": "Rancher", "enabled": True, "protocol": "openid-connect",
        "publicClient": False, "secret": inp["rancher_oidc_secret"], "standardFlowEnabled": True,
        "implicitFlowEnabled": False, "directAccessGrantsEnabled": False, "serviceAccountsEnabled": False,
        "redirectUris": [RANCHER_URL + "/verify-auth"], "webOrigins": [RANCHER_URL],
        "attributes": {"post.logout.redirect.uris": RANCHER_URL + "/*"},
    }, [group_mapper("Groups Mapper", "groups", "false"), group_mapper("Group Path", "full_group_path", "true"),
        audience_mapper("Client Audience", "rancher")])

    # Platform administrators exist only in Keycloak (no unix account).
    admin_gid = kc.ensure_group(REALM, ADMIN_GROUP)
    for name in E.get("PLATFORM_ADMIN_USERS", "").split():
        uid = kc.ensure_user(REALM, name, inp["passwords"][name], truthy("INITIAL_PASSWORDS_TEMPORARY"))
        kc.set_memberships(REALM, uid, {admin_gid}, {admin_gid})

    # Kubernetes: the admin group is cluster-admin when it comes in over OIDC.
    kapply([{
        "apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
        "metadata": {"name": "hpc-platform-admins"},
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": GROUP_PREFIX + ADMIN_GROUP}],
    }])

    if rancher_present():
        configure_rancher_auth(inp)
    else:
        log("Rancher is not installed; skipping its login configuration")


def oidc_doc_to_keycloak(doc):
    """Keycloak identity-provider settings from an OpenID provider metadata
    document (.well-known/openid-configuration); what Keycloak's own
    import-config does, done here so a saved document works without Keycloak
    fetching anything at configuration time."""
    missing = [k for k in ("issuer", "authorization_endpoint", "token_endpoint", "jwks_uri") if not doc.get(k)]
    if missing:
        die("upstream OpenID configuration lacks %s" % ", ".join(missing))
    conf = {"issuer": doc["issuer"], "authorizationUrl": doc["authorization_endpoint"],
            "tokenUrl": doc["token_endpoint"], "jwksUrl": doc["jwks_uri"],
            "useJwksUrl": "true", "validateSignature": "true"}
    if doc.get("userinfo_endpoint"):
        conf["userInfoUrl"] = doc["userinfo_endpoint"]
    if doc.get("end_session_endpoint"):
        conf["logoutUrl"] = doc["end_session_endpoint"]
    return conf


def upstream_settings(doc, conf):
    """Client authentication and PKCE: what the provider says it supports,
    unless the site set it."""
    auth = E.get("UPSTREAM_OIDC_CLIENT_AUTH", "")
    methods = doc.get("token_endpoint_auth_methods_supported") or ["client_secret_basic"]
    if not auth:
        auth = "client_secret_post" if "client_secret_post" in methods else "client_secret_basic"
    pkce = "S256" in (doc.get("code_challenge_methods_supported") or [])
    conf.update({"clientAuthMethod": auth, "pkceEnabled": str(pkce).lower()})
    if pkce:
        conf["pkceMethod"] = "S256"
    return conf


def configure_upstream(kc, inp):
    """Optional: broker an upstream OIDC provider. Upstream authenticates, the flat
    file authorises: a login only succeeds when the upstream username claim
    matches an account this deployment created.

    Where the provider's settings come from (first one set wins):
      UPSTREAM_OIDC_CONFIG          a saved openid-configuration document (JSON,
                                    normalised on the deployer by the upstream_idp role)
      UPSTREAM_OIDC_DISCOVERY_URL   the document's URL (Keycloak fetches it)
      UPSTREAM_OIDC_ISSUER          <issuer>/.well-known/openid-configuration
    """
    issuer = E.get("UPSTREAM_OIDC_ISSUER", "")
    discovery = E.get("UPSTREAM_OIDC_DISCOVERY_URL", "")
    saved = E.get("UPSTREAM_OIDC_CONFIG", "")
    client_id = E.get("UPSTREAM_OIDC_CLIENT_ID", "")
    secret = inp.get("upstream_oidc_secret", "")
    alias = E.get("UPSTREAM_OIDC_ALIAS", "upstream")
    if truthy("UPSTREAM_OIDC_SPOOF"):
        # A second realm in this Keycloak plays the upstream provider.
        sim = REALM + "-upstream-sim"
        kc.ensure_realm(sim, "Simulated upstream IdP")
        client_id = "hpc-keycloak"
        issuer = "%s/realms/%s" % (KC_URL, sim)
        kc.ensure_client(sim, {
            "clientId": client_id, "enabled": True, "protocol": "openid-connect", "publicClient": False,
            "secret": secret, "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
            "redirectUris": ["%s/realms/%s/broker/%s/endpoint" % (KC_URL, REALM, alias)],
        }, [])
    if not (saved or discovery or issuer):
        return
    if not client_id:
        die("an upstream identity provider needs hpc_upstream_oidc_client_id")
    base = "/%s/identity-provider" % REALM
    if saved:
        doc = json.loads(saved)
        conf = oidc_doc_to_keycloak(doc)
        source = "saved configuration (issuer %s)" % doc["issuer"]
    else:
        url = discovery or issuer.rstrip("/") + "/.well-known/openid-configuration"
        status, doc, _ = HTTP.call("GET", url, ok=None)
        if status != 200 or not isinstance(doc, dict):
            log("upstream: %s not readable from the admin node (HTTP %s); Keycloak fetches it itself" % (url, status))
            doc = {}
        status, conf, _ = kc.call("POST", base + "/import-config", {"providerId": "oidc", "fromUrl": url}, ok=None)
        if status != 200 or not isinstance(conf, dict):
            die("Keycloak could not read the upstream OpenID configuration at %s (HTTP %s). Check the URL, "
                "that Keycloak's pods reach it and trust its certificate, or use hpc_upstream_oidc_config_file"
                % (url, status))
        source = url
    if issuer and conf.get("issuer") and conf["issuer"].rstrip("/") != issuer.rstrip("/"):
        die("upstream issuer is %s, but hpc_upstream_oidc_issuer says %s" % (conf["issuer"], issuer))
    conf = upstream_settings(doc, conf)
    conf.update({"clientId": client_id, "clientSecret": secret,
                 "defaultScope": E.get("UPSTREAM_OIDC_SCOPES", "openid profile email"),
                 "syncMode": "IMPORT", "useJwksUrl": "true"})

    # First login through the broker: attach to the pre-created account with the
    # same username; never create accounts on the fly.
    flow = "hpc first broker login"
    flows = {f["alias"]: f for f in kc.get("/%s/authentication/flows" % REALM)}
    if flow not in flows:
        kc.call("POST", "/%s/authentication/flows" % REALM,
                {"alias": flow, "providerId": "basic-flow", "topLevel": True, "builtIn": False,
                 "description": "link upstream identities to existing accounts by username"})
        fpath = "/%s/authentication/flows/%s/executions" % (REALM, urllib.parse.quote(flow))
        for provider in ("idp-detect-existing-broker-user", "idp-auto-link"):
            kc.call("POST", fpath + "/execution", {"provider": provider})
        for ex in kc.get(fpath):
            kc.call("PUT", fpath, dict(ex, requirement="REQUIRED"))
        log("keycloak: created authentication flow '%s'" % flow)

    rep = {"alias": alias, "displayName": E.get("UPSTREAM_OIDC_DISPLAY_NAME", "Site login"), "providerId": "oidc",
           "enabled": True, "trustEmail": True, "storeToken": False, "linkOnly": False,
           "firstBrokerLoginFlowAlias": flow, "config": conf}
    status, cur, _ = kc.call("GET", "%s/instances/%s" % (base, alias), ok=(200, 404))
    if status == 404:
        kc.call("POST", base + "/instances", rep)
        log("keycloak: added identity provider '%s' from %s" % (alias, source))
    else:
        # Keycloak masks the stored secret; compare everything else.
        keep = dict(cur.get("config") or {}, clientSecret=secret)
        if any(cur.get(k) != rep[k] for k in ("displayName", "enabled", "firstBrokerLoginFlowAlias")) \
                or any(keep.get(k) != v for k, v in conf.items()):
            log("keycloak: updated identity provider '%s' from %s" % (alias, source))
        kc.call("PUT", "%s/instances/%s" % (base, alias), dict(cur, **rep))
    claim = E.get("UPSTREAM_OIDC_USERNAME_CLAIM", "preferred_username")
    mapper = {"name": "username", "identityProviderAlias": alias, "identityProviderMapper": "oidc-username-idp-mapper",
              "config": {"syncMode": "INHERIT", "template": "${CLAIM.%s}" % claim, "target": "LOCAL"}}
    have = {m["name"]: m for m in kc.get("%s/instances/%s/mappers" % (base, alias))}
    if "username" in have:
        kc.call("PUT", "%s/instances/%s/mappers/%s" % (base, alias, have["username"]["id"]),
                dict(mapper, id=have["username"]["id"]))
    else:
        kc.call("POST", "%s/instances/%s/mappers" % (base, alias), mapper)


def configure_rancher_auth(inp):
    oidc = "%s/realms/%s/protocol/openid-connect" % (KC_URL, REALM)
    r = Rancher(inp["rancher_admin_password"])
    try:
        cur = r.call("GET", "/v3/keyCloakOIDCConfigs/" + RANCHER_PROVIDER)
        want = {
            "enabled": True, "accessMode": "restricted",
            "allowedPrincipalIds": rancher_allowed_principals(tenant_groups_in_cluster()),
            "clientId": "rancher", "clientSecret": inp["rancher_oidc_secret"],
            "issuer": "%s/realms/%s" % (KC_URL, REALM), "authEndpoint": oidc + "/auth",
            "tokenEndpoint": oidc + "/token", "userInfoEndpoint": oidc + "/userinfo", "jwksUrl": oidc + "/certs",
            "endSessionEndpoint": oidc + "/logout", "rancherUrl": RANCHER_URL + "/verify-auth",
            "scope": "openid profile email", "groupsClaim": "groups", "groupSearchEnabled": False,
            "certificate": open(CA_FILE).read(),
        }
        cur.update(want)
        r.call("PUT", "/v3/keyCloakOIDCConfigs/" + RANCHER_PROVIDER, cur)
        log("rancher: Keycloak login enabled (restricted to project groups and %s)" % ADMIN_GROUP)
    finally:
        r.close()

    # New users get the minimal global role: they see only what a project grants.
    for role, default in (("user", False), ("user-base", True)):
        kubectl("patch", "globalroles.management.cattle.io", role, "--type", "merge",
                "-p", json.dumps({"newUserDefault": default}))
    kapply([{
        "apiVersion": "management.cattle.io/v3", "kind": "GlobalRoleBinding",
        "metadata": {"name": "hpc-platform-admins"},
        "globalRoleName": "admin", "groupPrincipalName": rancher_principal(ADMIN_GROUP),
    }, {
        # project-member without "create namespaces": every namespace in a project
        # is created by this tool so that quota, isolation and node pinning apply.
        "apiVersion": "management.cattle.io/v3", "kind": "RoleTemplate",
        "metadata": {"name": "hpc-project-user"},
        "displayName": "HPC Project User", "context": "project", "roleTemplateNames": ["edit"],
        "rules": [
            {"apiGroups": ["ui.cattle.io"], "resources": ["navlinks"], "verbs": ["get", "list", "watch"]},
            {"apiGroups": ["management.cattle.io"], "resources": ["projectroletemplatebindings", "clusterevents"],
             "verbs": ["get", "list", "watch"]},
            {"apiGroups": ["management.cattle.io"], "resources": ["clusters"], "verbs": ["get"]},
            {"apiGroups": [""], "resources": ["persistentvolumes"], "verbs": ["get", "list", "watch"]},
            {"apiGroups": ["storage.k8s.io"], "resources": ["storageclasses"], "verbs": ["get", "list", "watch"]},
            {"apiGroups": ["apiregistration.k8s.io"], "resources": ["apiservices"], "verbs": ["get", "list", "watch"]},
            {"apiGroups": ["metrics.k8s.io"], "resources": ["pods"], "verbs": ["get", "list", "watch"]},
        ],
    }])


# --------------------------------------------------------------------------- flat file
def flatfile():
    """The ingestion module (format defined by its FIELDS table)."""
    sys.path.insert(0, LIB_DIR)
    import hpc_flatfile
    return hpc_flatfile


def parse_projects(path):
    try:
        return flatfile().parse(path)
    except (ValueError, OSError) as e:
        die(str(e))


def load_idmap():
    if os.path.exists(IDMAP_FILE):
        return json.load(open(IDMAP_FILE))
    return {"users": {}, "groups": {}, "next_uid": int(E["UID_START"]), "next_gid": int(E["GID_START"])}


def save_json(path, obj, mode=0o600):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode), "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def system_names():
    """Account names owned by the OS on this node; project users may not shadow them."""
    start = int(E["UID_START"])
    return {l.split(":")[0] for l in open("/etc/passwd") if int(l.split(":")[2]) < start}


# --------------------------------------------------------------------------- tenants
def tenant_objects(p):
    ns, group = p["ns"], p["group"]
    meta = lambda name: {"name": name, "namespace": ns, "labels": {"hpc.io/project": group}}
    same_ns = [{"podSelector": {}}]
    ingress_ctl = [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                    "podSelector": {"matchLabels": {"app.kubernetes.io/name": "rke2-traefik"}}}]
    dns = [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
            "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}]
    return [
        {"apiVersion": "v1", "kind": "Namespace", "metadata": {
            "name": ns,
            "labels": {"hpc.io/tenant": "true", "hpc.io/project": group,
                       "pod-security.kubernetes.io/enforce": E["TENANT_POD_SECURITY"]},
            # PodNodeSelector: every pod in this namespace is forced onto compute nodes.
            "annotations": {"scheduler.alpha.kubernetes.io/node-selector": "hpc.io/role=compute"}}},
        # One quota for the whole group: all members draw from the same pool.
        # Which flat-file columns become which quota entries: QUOTA in hpc_flatfile.py.
        {"apiVersion": "v1", "kind": "ResourceQuota", "metadata": meta("project-quota"),
         "spec": {"hard": flatfile().quota_hard(p)}},
        # Pods that do not state requests/limits get these, so they still count against the quota.
        {"apiVersion": "v1", "kind": "LimitRange", "metadata": meta("project-defaults"), "spec": {"limits": [{
            "type": "Container",
            "defaultRequest": {"cpu": E["TENANT_DEFAULT_CPU_REQUEST"], "memory": E["TENANT_DEFAULT_MEM_REQUEST"]},
            "default": {"cpu": E["TENANT_DEFAULT_CPU_LIMIT"], "memory": E["TENANT_DEFAULT_MEM_LIMIT"]}}]}},
        # Network isolation: pods talk to their own namespace, DNS, the ingress
        # controller and addresses outside the pod network - never to other projects.
        {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("project-isolation"), "spec": {
            "podSelector": {}, "policyTypes": ["Ingress", "Egress"],
            "ingress": [{"from": same_ns}, {"from": ingress_ctl}],
            "egress": [{"to": same_ns}, {"to": ingress_ctl},
                       {"to": dns, "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                       # Outside the cluster: anything except the node network, where only
                       # the API, ingress and user registry on the admin node are reachable
                       # (so pods cannot talk NFS to the storage exports directly).
                       {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": [E["POD_CIDR"]] + E["NODE_CIDRS"].split()}}]},
                       {"to": [{"ipBlock": {"cidr": E["ADMIN_IP"] + "/32"}}],
                        "ports": [{"protocol": "TCP", "port": int(pt)}
                                  for pt in ("6443", "443", E["REGISTRY_USER_PORT"])]}]}},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": meta("project-members"),
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "edit"},
         "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": GROUP_PREFIX + group}]},
    ]


def cluster_policies():
    """Admission rules for every tenant namespace (label hpc.io/tenant=true)."""
    sel = {"matchLabels": {"hpc.io/tenant": "true"}}

    def policy(name, group, resource, ops, validations):
        return [
            {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy",
             "metadata": {"name": name},
             "spec": {"failurePolicy": "Fail",
                      "matchConstraints": {"namespaceSelector": sel, "resourceRules": [{
                          "apiGroups": [group], "apiVersions": ["*"], "operations": ops, "resources": [resource]}]},
                      "validations": validations}},
            {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding",
             "metadata": {"name": name},
             "spec": {"policyName": name, "validationActions": ["Deny"], "matchResources": {"namespaceSelector": sel}}},
        ]

    # The built-in "edit" role can manage NetworkPolicies; in a project namespace
    # that would let a member switch the isolation off, so only the platform may.
    platform = ("request.userInfo.groups.exists(g, g == 'system:masters' || g == '%s%s')"
                " || request.userInfo.username.startsWith('system:serviceaccount:kube-system:')"
                " || (request.userInfo.username.startsWith('system:')"
                " && !request.userInfo.username.startsWith('system:serviceaccount:'))") % (GROUP_PREFIX, ADMIN_GROUP)
    guard = policy("hpc-tenant-networkpolicies", "networking.k8s.io", "networkpolicies",
                   ["CREATE", "UPDATE", "DELETE"], [
        {"expression": platform,
         "message": "network policies in project namespaces are managed by the platform"}])

    host_ok = "h.endsWith('.' + namespaceObject.metadata.name + '.%s')" % APPS_DOMAIN
    return guard + policy("hpc-tenant-pods", "", "pods", ["CREATE"], [
        # nodeName bypasses the scheduler (and with it the node pinning).
        {"expression": "!has(object.spec.nodeName) || object.spec.nodeName == ''",
         "message": "pods in project namespaces may not set spec.nodeName"},
    ]) + policy("hpc-tenant-ingress", "networking.k8s.io", "ingresses", ["CREATE", "UPDATE"], [
        {"expression": "!has(object.spec.defaultBackend)",
         "message": "project ingresses may not define a default backend"},
        {"expression": "!has(object.spec.rules) || object.spec.rules.all(r, has(r.host) && [r.host].all(h, %s))" % host_ok,
         "messageExpression": "'ingress hosts must end with .' + namespaceObject.metadata.name + '.%s'" % APPS_DOMAIN},
        {"expression": "!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, %s))" % host_ok,
         "messageExpression": "'ingress TLS hosts must end with .' + namespaceObject.metadata.name + '.%s'" % APPS_DOMAIN},
    ])


IDENTITY_CM = {"name": "hpc-identities", "namespace": "kube-system"}
OWNER_ANNOTATION = "hpc.io/user"
OWNER_LABEL = "hpc.io/user"      # the same unix name, as a label (kubectl get pods -l hpc.io/user=<name>)

# CEL shared by the policies below. `params` is the hpc-identities ConfigMap:
#   u.<unix name> = uid      k.<keycloak user id> = unix name
#   g.<namespace> = project gid      primary = gid of the common primary group
CEL_VARS = [
    {"name": "uname", "expression": "request.userInfo.username"},
    # people (OIDC or through Rancher) as opposed to controllers
    {"name": "human", "expression": "!variables.uname.startsWith('system:')"},
    {"name": "trusted", "expression":
        "variables.uname.startsWith('system:serviceaccount:kube-system:') || "
        "(variables.uname.startsWith('system:') && !variables.uname.startsWith('system:serviceaccount:'))"},
    # Rancher impersonates its own user id and passes the Keycloak identity along.
    {"name": "principal", "expression":
        "has(request.userInfo.extra) && 'principalid' in request.userInfo.extra "
        "? request.userInfo.extra['principalid'][0].replace('%s_user://', '') : ''" % RANCHER_PROVIDER},
    {"name": "submitter", "expression":
        "!variables.human ? '' : (variables.principal != '' "
        "? (('k.' + variables.principal) in params.data ? params.data['k.' + variables.principal] : '') "
        ": variables.uname)"},
]


def pod_default_policies():
    """Mutating admission for project namespaces:
       - every pod gets the baseline-hardening fields users tend to leave out
       - a pod is owned by the person who submitted it (directly or via a workload) and
         always carries their unix name (annotation + label hpc.io/user)
       - POD_IDENTITY=uid: it also runs as that person's uid/gid unless it names a user
         itself (POD_IDENTITY=name: the image's user, no uid/gid is set)
       - HOME_VOLUME=nfs (needs uid): their home directory is mounted at the same path
         as on the login node."""
    sel = {"matchLabels": {"hpc.io/tenant": "true"}}
    set_uid = "true" if E.get("POD_IDENTITY", "name") == "uid" else "false"
    home = "'%s/' + variables.owner" % E["HOME_ROOT"]                   # path inside the pod
    home_src = "'%s/' + variables.owner" % E["HOME_NFS_PATH"]           # path on the NFS server
    with_home = "variables.known" if E.get("HOME_VOLUME", "nfs") == "nfs" else "false"
    ann = "object.metadata.annotations"
    pod_vars = CEL_VARS + [
        {"name": "owner", "expression":
            "variables.human ? variables.submitter : "
            "(variables.trusted && has(%s) && '%s' in %s ? %s['%s'] : '')"
            % (ann, OWNER_ANNOTATION, ann, ann, OWNER_ANNOTATION)},
        {"name": "known", "expression": "variables.owner != '' && ('u.' + variables.owner) in params.data"},
        {"name": "all", "expression":
            "object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])"},
        # the pod chose its own user somewhere -> leave identity alone
        {"name": "setuid", "expression":
            set_uid + " && variables.known && !(has(object.spec.securityContext) && has(object.spec.securityContext.runAsUser)) && "
            "!variables.all.exists(c, has(c.securityContext) && has(c.securityContext.runAsUser))"},
        {"name": "gkey", "expression": "'g.' + namespaceObject.metadata.name"},
    ]

    def container(kind):
        t = "Object.spec.%s" % kind
        return (
            "%(t)s{name: c.name, "
            "securityContext: %(t)s.securityContext{"
            # (left alone on privileged containers so pod security reports those plainly)
            "?allowPrivilegeEscalation: has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged "
            "? optional.none() : optional.of(has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) "
            "? c.securityContext.allowPrivilegeEscalation : false)}, "
                        "?volumeMounts: %(with_home)s ? optional.of([%(t)s.volumeMounts{name: 'hpc-home', mountPath: %(home)s}]) : optional.none(), "
            "?env: variables.setuid && !(has(c.env) && c.env.exists(e, e.name == 'HOME')) "
            "? optional.of([%(t)s.env{name: 'HOME', value: %(home)s}]) : optional.none()}"
        ) % {"t": t, "home": home, "with_home": with_home}

    pod_expr = (
        "Object{"
        # label only for project users: their unix names are valid label values
        "?metadata: variables.owner != '' ? optional.of(Object.metadata{annotations: {'%(a)s': variables.owner}, "
        "?labels: variables.known ? optional.of({'%(l)s': variables.owner}) : optional.none()}) : optional.none(), "
        "spec: Object.spec{"
        "containers: object.spec.containers.map(c, %(c)s), "
        "?initContainers: has(object.spec.initContainers) ? optional.of(object.spec.initContainers.map(c, %(i)s)) : optional.none(), "
        "?volumes: %(with_home)s ? optional.of([Object.spec.volumes{name: 'hpc-home', "
        "nfs: Object.spec.volumes.nfs{server: '%(srv)s', path: %(home_src)s}}]) : optional.none(), "
        "securityContext: Object.spec.securityContext{"
        "seccompProfile: Object.spec.securityContext.seccompProfile{type: "
        "has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) "
        "? object.spec.securityContext.seccompProfile.type : 'RuntimeDefault'}, "
        "?runAsUser: variables.setuid ? optional.of(int(params.data['u.' + variables.owner])) : optional.none(), "
        "?runAsGroup: variables.setuid ? optional.of(int(params.data['primary'])) : optional.none()}}}"
    ) % {"a": OWNER_ANNOTATION, "l": OWNER_LABEL, "c": container("containers"), "i": container("initContainers"),
         "srv": E["HOME_NFS_SERVER"], "home": home, "home_src": home_src, "with_home": with_home}

    def drop_caps(kind):
        c = "object.spec.%s[i]" % kind
        return (
            "(has(object.spec.%(k)s) ? lists.range(size(object.spec.%(k)s)) : [])"
            ".filter(i, has(%(c)s.securityContext) && !(has(%(c)s.securityContext.privileged) && %(c)s.securityContext.privileged) && "
            "!(has(%(c)s.securityContext.capabilities) && has(%(c)s.securityContext.capabilities.drop)))"
            ".map(i, has(%(c)s.securityContext.capabilities) "
            "? JSONPatch{op: 'add', path: '/spec/%(k)s/' + string(i) + '/securityContext/capabilities/drop', value: ['ALL']} "
            ": JSONPatch{op: 'add', path: '/spec/%(k)s/' + string(i) + '/securityContext/capabilities', "
            "value: Object.spec.%(k)s.securityContext.capabilities{drop: ['ALL']}})"
        ) % {"k": kind, "c": c}

    lists_expr = (
        "%s + %s + "
        # the project group, when the pod runs as its owner
        "(" + set_uid + " && variables.known && variables.gkey in params.data && has(object.spec.securityContext.runAsUser) && "
        "object.spec.securityContext.runAsUser == int(params.data['u.' + variables.owner]) && "
        "!has(object.spec.securityContext.supplementalGroups) "
        "? [JSONPatch{op: 'add', path: '/spec/securityContext/supplementalGroups', "
        "value: [int(params.data[variables.gkey])]}] : [])"
    ) % (drop_caps("containers"), drop_caps("initContainers"))

    def mutating(name, rules, variables, expr, conditions=None, patches=None):
        spec = {"failurePolicy": "Fail", "reinvocationPolicy": "Never",
                "paramKind": {"apiVersion": "v1", "kind": "ConfigMap"},
                "matchConstraints": {"namespaceSelector": sel, "resourceRules": rules},
                "variables": variables,
                "mutations": [{"patchType": "ApplyConfiguration", "applyConfiguration": {"expression": expr}}]}
        if patches:
            spec["mutations"].append({"patchType": "JSONPatch", "jsonPatch": {"expression": patches}})
        if conditions:
            spec["matchConditions"] = conditions
        return [
            {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "MutatingAdmissionPolicy",
             "metadata": {"name": name}, "spec": spec},
            {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "MutatingAdmissionPolicyBinding",
             "metadata": {"name": name},
             "spec": {"policyName": name, "matchResources": {"namespaceSelector": sel},
                      "paramRef": dict(IDENTITY_CM, parameterNotFoundAction="Deny")}},
        ]

    def rule(group, resources, ops):
        return {"apiGroups": [group], "apiVersions": ["*"], "operations": ops, "resources": resources}

    is_human = [{"name": "submitted-by-a-person", "expression": "!request.userInfo.username.startsWith('system:')"}]
    stamp = "{'%s': variables.submitter}" % OWNER_ANNOTATION
    objs = mutating("hpc-tenant-pod-defaults", [rule("", ["pods"], ["CREATE"])], pod_vars, pod_expr,
                    patches=lists_expr)
    # Workloads carry their submitter into the pods their controllers create.
    objs += mutating(
        "hpc-tenant-workload-owner",
        [rule("apps", ["deployments", "statefulsets", "daemonsets", "replicasets"], ["CREATE", "UPDATE"]),
         rule("batch", ["jobs"], ["CREATE", "UPDATE"]), rule("", ["replicationcontrollers"], ["CREATE", "UPDATE"])],
        CEL_VARS,
        "Object{spec: Object.spec{template: Object.spec.template{metadata: "
        "Object.spec.template.metadata{annotations: %s}}}}" % stamp, is_human)
    objs += mutating(
        "hpc-tenant-cronjob-owner", [rule("batch", ["cronjobs"], ["CREATE", "UPDATE"])], CEL_VARS,
        "Object{spec: Object.spec{jobTemplate: Object.spec.jobTemplate{spec: Object.spec.jobTemplate.spec{"
        "template: Object.spec.jobTemplate.spec.template{metadata: "
        "Object.spec.jobTemplate.spec.template.metadata{annotations: %s}}}}}}" % stamp, is_human)

    # What a project pod may mount: cluster-managed volume types and its owner's home.
    # (Inline NFS/iSCSI/... would reach storage exports with whatever uid the pod picks.)
    allowed = " || ".join("has(v.%s)" % t for t in
                          ("configMap", "secret", "emptyDir", "projected", "downwardAPI",
                           "persistentVolumeClaim", "ephemeral"))
    owner = "(has(%s) && '%s' in %s ? %s['%s'] : '')" % (ann, OWNER_ANNOTATION, ann, ann, OWNER_ANNOTATION)
    objs += [
        {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy",
         "metadata": {"name": "hpc-tenant-pod-volumes"},
         "spec": {"failurePolicy": "Fail", "paramKind": {"apiVersion": "v1", "kind": "ConfigMap"},
                  "matchConstraints": {"namespaceSelector": sel, "resourceRules": [rule("", ["pods"], ["CREATE"])]},
                  "variables": CEL_VARS + [{"name": "owner", "expression": owner}],
                  "validations": [
                      {"expression": "variables.owner == '' || variables.trusted || "
                                     "(variables.human && variables.owner == variables.submitter)",
                       "message": "the %s annotation is set by the platform" % OWNER_ANNOTATION},
                      {"expression": "!(has(object.metadata.labels) && '%s' in object.metadata.labels) || "
                                     "object.metadata.labels['%s'] == variables.owner" % (OWNER_LABEL, OWNER_LABEL),
                       "message": "the %s label is set by the platform" % OWNER_LABEL},
                      {"expression":
                          "!has(object.spec.volumes) || object.spec.volumes.all(v, %s || "
                          "(v.name == 'hpc-home' && has(v.nfs) && variables.owner != '' && v.nfs.server == '%s' "
                          "&& v.nfs.path == '%s/' + variables.owner))" % (allowed, E["HOME_NFS_SERVER"], E["HOME_NFS_PATH"]),
                       "message": "project pods may only use configMap, secret, emptyDir, projected, downwardAPI, "
                                  "ephemeral and persistentVolumeClaim volumes"}]}},
        {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding",
         "metadata": {"name": "hpc-tenant-pod-volumes"},
         "spec": {"policyName": "hpc-tenant-pod-volumes", "validationActions": ["Deny"],
                  "matchResources": {"namespaceSelector": sel},
                  "paramRef": dict(IDENTITY_CM, parameterNotFoundAction="Deny")}},
    ]
    return objs


def identity_configmap(idmap, projects, users, primary_gid, keycloak_ids):
    data = {"primary": str(primary_gid)}
    for u in users:
        data["u." + u] = str(idmap["users"][u])
        data["k." + keycloak_ids[u]] = u
    for p in projects:
        data["g." + p["ns"]] = str(idmap["groups"][p["group"]])
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": dict(IDENTITY_CM), "data": data}


def rancher_project_objects(p):
    proj = "p-" + p["ns"]
    return proj, [{
        "apiVersion": "management.cattle.io/v3", "kind": "Project",
        "metadata": {"name": proj, "namespace": "local", "labels": {"hpc.io/project": p["group"]}},
        "spec": {"clusterName": "local", "displayName": p["group"],
                 "description": "HPC project %s: %s (shared by the group)"
                                % (p["group"], flatfile().describe(p))},
    }]


def cmd_tenants(inp):
    projects = parse_projects(PROJECTS_FILE)
    users = sorted({u for p in projects for u in p["users"]})
    clash = sorted(set(users) & system_names())
    if clash:
        die("these usernames belong to system accounts: " + ", ".join(clash))
    for p in projects:      # never take over a namespace this tool does not own
        ns = kget("namespace", p["ns"])
        if ns and ns["metadata"].get("labels", {}).get("hpc.io/tenant") != "true":
            die("group %s maps to namespace '%s', which already exists and is not a project namespace"
                % (p["group"], p["ns"]))

    default_hours = float(E.get("TENANT_DEFAULT_CPU_HOURS", "1000"))
    save_json(PROJECTS_JSON, [{"group": p["group"], "ns": p["ns"],
                               "budget_cpu_hours": p.get("cpu_hours") or default_hours}
                              for p in projects])

    # ---- stable unix ids -------------------------------------------------------
    idmap = load_idmap()
    for p in projects:                    # file order of first appearance decides the id
        if p["group"] not in idmap["groups"]:
            idmap["groups"][p["group"]] = idmap["next_gid"]
            idmap["next_gid"] += 1
        for u in p["users"]:
            if u not in idmap["users"]:
                idmap["users"][u] = idmap["next_uid"]
                idmap["next_uid"] += 1
    save_json(IDMAP_FILE, idmap)
    primary = {"name": "hpc-users", "gid": int(E["UID_START"]) - 1}

    # ---- home directories (the export lives on this node) --------------------------
    for u in users if E.get("HOME_CREATE_ROOT") else []:
        home = os.path.join(E["HOME_CREATE_ROOT"], u)
        if not os.path.isdir(home):
            shutil.copytree("/etc/skel", home, symlinks=True)
            for root, dirs, files in os.walk(home):
                for name in [root] + [os.path.join(root, f) for f in files]:
                    os.lchown(name, idmap["users"][u], primary["gid"])
            os.chmod(home, 0o700)
            log("created home %s" % home)

    # ---- kubernetes ---------------------------------------------------------------
    kapply(cluster_policies())
    with_rancher = rancher_present()
    for p in projects:
        objs = tenant_objects(p)
        if with_rancher:
            proj, robjs = rancher_project_objects(p)
            kapply(robjs)
            objs[0]["metadata"]["annotations"]["field.cattle.io/projectId"] = "local:" + proj
            objs[0]["metadata"]["labels"]["field.cattle.io/projectId"] = proj
        kapply(objs)
        if with_rancher:
            backing = None
            for _ in range(60):          # Rancher creates the project's backing namespace
                backing = (kget("projects.management.cattle.io", proj, "-n", "local") or {}) \
                    .get("status", {}).get("backingNamespace")
                if backing and kget("namespace", backing):
                    break
                time.sleep(2)
            else:
                die("Rancher did not initialise project %s" % proj)
            kapply([{
                "apiVersion": "management.cattle.io/v3", "kind": "ProjectRoleTemplateBinding",
                "metadata": {"name": "hpc-members", "namespace": backing},
                "projectName": "local:" + proj, "roleTemplateName": "hpc-project-user",
                "groupPrincipalName": rancher_principal(p["group"]),
            }])
        log("project %s -> namespace %s (%s; %d users)"
            % (p["group"], p["ns"], flatfile().describe(p), len(p["users"])))

    wanted = {p["group"] for p in projects}
    for g in sorted(tenant_groups_in_cluster() - wanted):
        log("WARNING: namespace for group %s still exists but the group is no longer in the flat file; "
            "its members lose access, its workloads and data are left untouched (delete the namespace to remove them)" % g)
        kubectl("delete", "rolebinding", "project-members", "-n", g.lower(), "--ignore-not-found")
        if with_rancher:
            kubectl("delete", "projectroletemplatebindings.management.cattle.io", "hpc-members",
                    "-n", "local-p-" + g.lower(), "--ignore-not-found", check=False)

    # ---- keycloak -------------------------------------------------------------------
    kc = Keycloak()
    if kc.call("GET", "/" + REALM, ok=(200, 404))[0] == 404:
        die("Keycloak realm '%s' does not exist (run site.yml --tags identity)" % REALM)
    gids = {p["group"]: kc.ensure_group(REALM, p["group"]) for p in projects}
    managed = set(gids.values())
    for g in kc.get("/%s/groups?max=1000&briefRepresentation=false" % REALM):
        if g.get("attributes", {}).get("hpc-managed") == ["true"] and g["name"] != ADMIN_GROUP:
            managed.add(g["id"])          # also covers groups dropped from the flat file
    membership = {u: {gids[p["group"]] for p in projects if u in p["users"]} for u in users}
    temporary = truthy("INITIAL_PASSWORDS_TEMPORARY")
    keycloak_ids = {}
    for u in users:
        uid = kc.ensure_user(REALM, u, inp["passwords"][u], temporary, {"hpc-managed": ["true"]})
        kc.set_memberships(REALM, uid, membership[u], managed)
        keycloak_ids[u] = uid

    # ---- pod defaults: who runs as which uid, and whose home gets mounted ---------------
    cm = identity_configmap(idmap, projects, users, primary["gid"], keycloak_ids)
    kubectl("replace", "--force", "-f", "-", stdin=json.dumps(cm)) if kget("configmap", IDENTITY_CM["name"], "-n", IDENTITY_CM["namespace"]) \
        else kubectl("create", "-f", "-", stdin=json.dumps(cm))
    kapply(pod_default_policies())
    # Accounts this tool created earlier that are gone from the flat file.
    removed = sorted(set(idmap["users"]) - set(users))
    for name in removed:
        ku = kc.user(REALM, name)
        if ku:
            kc.set_memberships(REALM, ku["id"], set(), managed)
            if ku.get("enabled", True):
                kc.call("PUT", "/%s/users/%s" % (REALM, ku["id"]), dict(ku, enabled=False))
                log("keycloak: disabled user %s (no longer in the flat file)" % name)

    # ---- rancher login allow-list follows the project groups ------------------------------
    if with_rancher:
        cfg = kget("authconfigs.management.cattle.io", RANCHER_PROVIDER) or {}
        want = rancher_allowed_principals(wanted)
        if cfg.get("enabled") and sorted(cfg.get("allowedPrincipalIds") or []) != sorted(want):
            kubectl("patch", "authconfigs.management.cattle.io", RANCHER_PROVIDER, "--type", "merge",
                    "-p", json.dumps({"allowedPrincipalIds": want}))
            log("rancher: login allow-list updated")

    # ---- account list for the login node(s) -----------------------------------------------
    save_json(ACCOUNTS_FILE, {
        "primary_group": primary,
        "groups": [{"name": g, "gid": idmap["groups"][g]} for g in sorted(wanted)],
        "users": [{"name": u, "uid": idmap["users"][u],
                   "groups": sorted(p["group"] for p in projects if u in p["users"])} for u in users],
        "removed_users": removed,
    })


def cmd_upstream(inp):
    configure_upstream(Keycloak(), inp)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("identity", "tenants", "upstream"):
        die("usage: hpc-sync identity|tenants|upstream")
    inp = {
        "passwords": dict(kv.split(":", 1) for kv in E.get("HPC_PASSWORDS", "").split()),
        "rancher_oidc_secret": E.get("RANCHER_OIDC_SECRET", ""),
        "rancher_admin_password": E.get("RANCHER_ADMIN_PASSWORD", ""),
        "upstream_oidc_secret": E.get("UPSTREAM_OIDC_SECRET", ""),
    }
    {"identity": cmd_identity, "tenants": cmd_tenants, "upstream": cmd_upstream}[sys.argv[1]](inp)


if __name__ == "__main__":
    main()
