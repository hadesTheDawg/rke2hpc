# Upstream identity provider (Keycloak brokering)

Keycloak can hand logins to the site's own identity provider (another
Keycloak, Entra ID, Okta, Shibboleth's OIDC side, ...). The **upstream
provider authenticates** (password, MFA, SSO session); the **flat file still
authorises**: an upstream login is linked to the cluster account with the same
unix name and is refused when there is none. No account is ever created by a
login. Kubernetes, Rancher and kubectl keep talking to this Keycloak only;
nothing else changes.

```
browser / kubectl ──► Keycloak realm hpc ──"Site login"──► upstream provider
                         ▲      │                              │ (authenticates)
                         │      └── first login: link to the ◄─┘ id_token, preferred_username
                         │          existing account of that name, or refuse
                  Rancher, kube-apiserver (OIDC against realm hpc, as before)
```

Role: `upstream_idp` (`site.yml --tags upstream_idp`; also runs with
`--tags identity`). It is on when any of the settings below is set. The
logic is `hpc-sync upstream` (`roles/hpc_common/files/hpc-sync.py`,
`configure_upstream`).

## 1. Register this Keycloak at the provider

Ask the provider's administrators for a **confidential OIDC client** with:

| | |
|-|-|
| Redirect URI | `https://<hpc_keycloak_host>/realms/<hpc_keycloak_realm>/broker/<hpc_upstream_oidc_alias>/endpoint`, e.g. `https://keycloak.hpc.example.org/realms/hpc/broker/upstream/endpoint` |
| Grant | authorization code |
| Scopes | `openid profile email` (`hpc_upstream_oidc_scopes`) |
| Username claim | a claim holding the **unix name** used in the flat file, normally `preferred_username` (`hpc_upstream_oidc_username_claim`) |

You get back a client id and a client secret.

```sh
# the secret: one line, no newline needed
printf '%s' 'THE-SECRET' > inventories/<site>/secrets/upstream-oidc-client
chmod 600 inventories/<site>/secrets/upstream-oidc-client
```

## 2. Tell the deployment where the provider's settings are

Pick **one** of three sources in `group_vars/all.yml`. All of them describe the
same thing: the provider's OpenID metadata (issuer, authorization, token,
keys, userinfo and logout endpoints).

### a) From a `.well-known` address (a variable)

```yaml
hpc_upstream_oidc_client_id: hpc-cluster
hpc_upstream_oidc_discovery_url: https://login.example.org/realms/staff/.well-known/openid-configuration
# optional, as a cross-check: the run stops if the document names another issuer
hpc_upstream_oidc_issuer: https://login.example.org/realms/staff
```

Keycloak downloads the document when the role runs. Use this when the
admin node's network reaches the provider. The address does not have to be
`<issuer>/.well-known/openid-configuration`; any URL that serves the document
works (some providers put it under a tenant path, or behind a proxy).

Shortcut: only `hpc_upstream_oidc_issuer` set means
`<issuer>/.well-known/openid-configuration`, which is how the setting worked
before `hpc_upstream_oidc_discovery_url` existed.

### b) From a saved `openid_configuration` flat file

```yaml
hpc_upstream_oidc_client_id: hpc-cluster
hpc_upstream_oidc_config_file: "{{ hpc_site_dir }}/upstream-openid-configuration"
```

The file lives next to the inventory, so it is versioned with the site. Use
this when the discovery address cannot be reached at deploy time, is served
only inside another network, or when the site wants the endpoints pinned and
reviewed rather than fetched. The deployer reads and checks it
(`roles/upstream_idp/files/oidc_config.py`), and the endpoints are configured
in Keycloak from it directly. Keycloak fetches nothing at configuration
time.

Two formats are accepted:

1. **The document itself** (JSON), as saved from the provider:

   ```sh
   curl -fsS https://login.example.org/realms/staff/.well-known/openid-configuration \
     > inventories/<site>/upstream-openid-configuration
   ```

2. **A flat file**, one `key: value` (or `key = value`) per line, the same key
   names as the document; `#` starts a comment. Keys ending in `_supported`
   take a comma- or space-separated list. Only the first four are required:

   ```
   # staff IdP (identity team, ticket 4711)
   issuer:                 https://login.example.org/realms/staff
   authorization_endpoint: https://login.example.org/realms/staff/protocol/openid-connect/auth
   token_endpoint:         https://login.example.org/realms/staff/protocol/openid-connect/token
   jwks_uri:               https://login.example.org/realms/staff/protocol/openid-connect/certs
   userinfo_endpoint:      https://login.example.org/realms/staff/protocol/openid-connect/userinfo
   end_session_endpoint:   https://login.example.org/realms/staff/protocol/openid-connect/logout
   code_challenge_methods_supported: S256
   token_endpoint_auth_methods_supported: client_secret_post, client_secret_basic
   ```

Check a file without deploying:

```sh
python3 roles/upstream_idp/files/oidc_config.py file inventories/<site>/upstream-openid-configuration
./check.sh inventories/<site>/hosts.yml     # also checks it when group_vars/all.yml names it
```

Every URL must be `https`. If `hpc_upstream_oidc_issuer` is also set, it must
equal the file's `issuer`.

> A saved file only saves the *discovery* step. At every login Keycloak still
> calls the provider's token endpoint and reads its signing keys
> (`jwks_uri`), and the user's browser goes to its authorization endpoint. So
> Keycloak's pod network must reach the token and keys endpoints. When the
> provider rotates its keys, Keycloak re-reads `jwks_uri` by itself.

### c) Simulated provider (lab)

`hpc_upstream_oidc_spoof: true` creates a second realm, `<realm>-upstream-sim`,
in this Keycloak and brokers it. The lab uses this. verify.yml then logs in
through it the way a browser would: as a flat-file user (linked to the
account), and as a user who is not in the flat file (refused).

Which source wins, when several are set: `hpc_upstream_oidc_config_file`, then
`hpc_upstream_oidc_discovery_url`, then `hpc_upstream_oidc_issuer`. With
`hpc_upstream_oidc_spoof` and no file or URL, the simulated realm is used.

## 3. Deploy

```sh
ansible-playbook -i inventories/<site>/hosts.yml site.yml --tags upstream_idp
```

The login page then shows **Site login** (`hpc_upstream_oidc_display_name`)
next to the username/password form. Re-running changes nothing unless the
settings or the document changed; the role prints `updated identity provider`
when they did.

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_upstream_oidc_config_file` | `''` | saved openid-configuration (JSON or `key: value`) on the deployer |
| `hpc_upstream_oidc_discovery_url` | `''` | URL of the provider's openid-configuration |
| `hpc_upstream_oidc_issuer` | `''` | issuer; alone: discovery at `<issuer>/.well-known/openid-configuration`; with one of the above: must match |
| `hpc_upstream_oidc_client_id` | `''` | this Keycloak's client id at the provider (secret: `secrets/upstream-oidc-client`) |
| `hpc_upstream_oidc_alias` | `upstream` | identity-provider alias; part of the redirect URI |
| `hpc_upstream_oidc_display_name` | `Site login` | button text on the login page |
| `hpc_upstream_oidc_scopes` | `openid profile email` | scopes requested from the provider |
| `hpc_upstream_oidc_username_claim` | `preferred_username` | claim that must equal the flat-file unix name |
| `hpc_upstream_oidc_client_auth` | `''` | `client_secret_post` or `client_secret_basic`; `''` = `post` if the provider lists it, else `basic` |
| `hpc_upstream_oidc_spoof` | `false` | lab: simulated provider in a second realm |
| `hpc_enable_upstream_idp` | on when any source is set | switch the role off explicitly |

PKCE (S256) is switched on when the document lists `S256` in
`code_challenge_methods_supported`.

## How a login is matched

1. The provider returns an ID token. Keycloak takes the username from
   `hpc_upstream_oidc_username_claim`.
2. The first-login flow (`hpc first broker login`) runs *detect existing
   broker user* and then *automatically link*. If an account with that
   username exists (created from the flat file), the upstream identity is
   linked to it. If not, the login fails with an error page. **No account is
   created.**
3. Later logins go straight through the link. Groups, uid/gid and project
   membership all come from the flat file, as for password logins.

Removing a user from the flat file disables the Keycloak account
(`tenants.yml`), and upstream logins for it stop working with it.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| role stops: `hpc_upstream_oidc_client_id is empty` | set it (not needed with `spoof`) |
| `upstream OpenID configuration: missing jwks_uri` | the flat file lacks a required key |
| `upstream issuer is X, but hpc_upstream_oidc_issuer says Y` | the document belongs to another provider/realm; fix one of them |
| warning `... does not answer from the admin node` | discovery URL unreachable from the management network; use a saved file (b) |
| Keycloak error page "Invalid username or password" after the provider's login | the username claim has no matching account in the flat file (intended), or the wrong claim (`hpc_upstream_oidc_username_claim`) |
| Keycloak log: `invalid_client` | wrong client secret in `secrets/upstream-oidc-client`, or wrong `hpc_upstream_oidc_client_auth` |
| Keycloak log: PKIX path building failed | the provider's CA is not trusted: add it to `secrets/pki/own/ca.crt` ([certificates.md](certificates.md)) |
