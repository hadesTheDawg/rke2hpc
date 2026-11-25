# Certificates: using your own `.crt`

Every certificate the deployment uses lives in the site's secrets directory
on the deployer, `inventories/<site>/secrets/pki/`. Out of the box the `pki`
role makes a private CA there and issues every certificate from it. You can
replace any of them with your own certificate, or the CA itself with your
site CA. The `pki` role runs at the start of every `site.yml` run, whatever
`--tags` you give, and applies whatever it finds there.

## The secrets directory

```
inventories/<site>/secrets/
├── pki/
│   ├── ca.crt  ca.key          issuing CA: generated on the first run, or your site CA
│   ├── ca-bundle.crt           made by the pki role: ca.crt + own/ca.crt. Every node and service trusts this
│   ├── admin.crt   admin.key   registries (registry.<domain>:5000, hub.<domain>:5001) and the package repository (:8443)
│   ├── ingress.crt ingress.key Rancher, Keycloak, and the ingress default certificate
│   ├── apps.crt    apps.key    project applications: *.<namespace>.apps.<domain>, one wildcard per project
│   ├── local.crt   local.key   the registries' push endpoints on 127.0.0.1 (always internal)
│   ├── *.sans                  what each certificate was made for (bookkeeping, do not edit)
│   └── own/                    ← YOUR certificates go here
│       ├── ca.crt              the CA chain that signed them (root, plus intermediates)
│       ├── ingress.crt  ingress.key
│       ├── admin.crt    admin.key
│       └── apps.crt     apps.key
├── rancher-admin, keycloak-admin, registry-*, rke2-*  generated passwords and tokens
├── users/<name>                                      initial user passwords
└── state/                                            uid/gid map, account list, rollback record
```

Files in `pki/` outside `own/` are written by the `pki` role. Do not edit them:
put your files in `own/` and let the role install them.

## Option 1: your own certificate for a service

Most sites want their own certificate on the names people type into a
browser: Rancher and Keycloak, i.e. the `ingress` certificate.

1. Get a certificate for the names the service answers on (the table below).
   Ask your CA for a server certificate (extended key usage `serverAuth`)
   whose subject alternative names include every required name.

   | File in `own/` | Must cover (SAN) | Optional |
   |----------------|------------------|----------|
   | `ingress.crt` | `rancher.<domain>`, `keycloak.<domain>` (`hpc_rancher_host`, `hpc_keycloak_host`) | `*.apps.<domain>` |
   | `admin.crt` | `registry.<domain>`, `hub.<domain>`, `<admin node>.<domain>` | admin node short name and IP |
   | `apps.crt` | `*.<namespace>.apps.<domain>` for **every** project in the flat file | |

   With your own `apps.crt`, every project added to the flat file needs a new
   certificate before `tenants.yml` runs. Most sites leave `apps` internal.

2. Copy the files in, as PEM (text starting with `-----BEGIN`):

   ```sh
   cd inventories/<site>/secrets/pki
   mkdir -p own && chmod 700 own
   cp ~/rancher.example.org.crt own/ingress.crt   # leaf first, then intermediates
   cp ~/rancher.example.org.key own/ingress.key   # unencrypted
   cat ~/corp-intermediate.crt ~/corp-root.crt > own/ca.crt
   chmod 600 own/*
   ```

   - **`<name>.crt`**: your certificate first, followed by the intermediate
     CA certificates (the "full chain"). Services send this file as is, so
     clients that only know the root can build the chain.
   - **`<name>.key`**: the private key, unencrypted. Ansible must read it
     without a passphrase. To remove one:
     `openssl pkey -in encrypted.key -out own/ingress.key`.
     From a `.pfx`/`.p12`:
     `openssl pkcs12 -in cert.pfx -nocerts -nodes | openssl pkey -out own/ingress.key` and
     `openssl pkcs12 -in cert.pfx -nokeys -out own/ingress.crt`.
   - **`own/ca.crt`**: the CA certificates that signed yours, root included.
     Nodes, Keycloak, Rancher, the Kubernetes API server and `hpc-sync` only
     trust `ca-bundle.crt`, not the operating system's list. So this file is
     needed even for a certificate from a public CA. Leave it out only when
     your certificate was signed by `pki/ca.crt` itself.

3. Run the deployment:

   ```sh
   ansible-playbook -i inventories/<site>/hosts.yml site.yml
   ```

   Before anything is installed, the `pki` role checks each own certificate.
   It stops with a message naming the file when:
   - the key does not belong to the certificate;
   - the certificate has expired;
   - it does not chain to `ca.crt` or `own/ca.crt`;
   - a required name is missing (the message lists the missing names).

   When all is well it reports `installed` and the services pick the new
   certificate up in that run. Traefik, which serves Rancher and Keycloak,
   gets it through Kubernetes secrets; nginx and the registries are
   restarted. Rancher and Keycloak read the trust bundle only when they
   start, so when `own/ca.crt` changes they are restarted too. Fewer than 30
   days before expiry, every run prints a warning.

### Renewing or replacing

Overwrite the files in `own/` and run `site.yml` again (or `site.yml --tags
base,registry,platform,keycloak,rancher` for only the steps that use them).
Own certificates are never renewed automatically.

### Going back to the internal certificate

Delete `own/<name>.crt` and `own/<name>.key` and run `site.yml`. The role then
issues a new certificate from `ca.crt`, with a new key.

## Option 2: your site CA issues everything

To have the role issue every certificate from your CA, for example an
intermediate CA your PKI team gave you for this cluster, place that CA in
`pki/` **before the first run**:

```sh
mkdir -p inventories/<site>/secrets/pki && chmod 700 inventories/<site>/secrets inventories/<site>/secrets/pki
cp ~/hpc-issuing-ca.crt inventories/<site>/secrets/pki/ca.crt
cp ~/hpc-issuing-ca.key inventories/<site>/secrets/pki/ca.key    # unencrypted
chmod 600 inventories/<site>/secrets/pki/ca.key
```

The role only generates a CA when `ca.key` is missing. Certificates are
re-issued whenever the CA changes, so switching an existing site to a new CA
also works: replace `ca.crt` and `ca.key`, then run `site.yml`. If your CA is an
intermediate, put the intermediate and then the root into `ca.crt`, so that
clients can build the chain.

Option 1 and 2 combine. Certificates in `own/` are used as they are; the role
issues the rest from `ca.crt`.

## What is not covered

- The Kubernetes API (port 6443) and the rest of RKE2 use RKE2's own CAs,
  made on the server's first start. They are part of the etcd snapshots
  (docs/reprovisioning.md). The kubeconfig in `/etc/rancher/rke2/rke2.yaml`
  carries that CA.
- `local.crt` (the push endpoints on 127.0.0.1) is always issued
  internally; no public CA issues certificates for `localhost`. An
  `own/local.*` is refused.
- The service names come from `hpc_domain` and the `hpc_*_host` settings
  ([variables.md](variables.md)). If your certificate is for other names,
  change those settings to match. Changing the names, or the list of
  projects, changes what the certificates need. The issued ones follow by
  themselves; your own ones must cover the new names.

## Checking

```sh
# what a file covers, and until when
openssl x509 -in own/ingress.crt -noout -subject -issuer -enddate -ext subjectAltName
# does it chain (the same check the role makes)
openssl verify -CAfile <(cat ca.crt own/ca.crt) -untrusted own/ingress.crt own/ingress.crt
# what a service presents
openssl s_client -connect rancher.<domain>:443 -servername rancher.<domain> </dev/null | openssl x509 -noout -subject -issuer
openssl s_client -connect registry.<domain>:5000 </dev/null | openssl x509 -noout -subject -issuer
```

Keep `secrets/` safe and backed up. It holds every private key and password
of the site, and a redeploy needs it to keep the same CA, certificates and
passwords.
