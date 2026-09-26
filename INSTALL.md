Reforge Helm chart bundles PostgreSQL, Authentik, docs, and the built-in runner. Disable bundled services and reference existing Secrets to use your own infrastructure.

This is a prerelease chart. Reforge `0.1.26` still requires privileged runner execution. The chart deliberately runs its runner unprivileged; select a compatible Reforge release when the parallel runner work is published. Until then, set `runner.enabled=false` for the control/UI stack. Repair execution will be unavailable. No live Kubernetes deployment has been verified.

Deployment

1. Copy `examples/reforgeapp.yaml` into your GitOps configuration. Set the Reforge and Authentik HTTPS origins, ingress class, TLS Secrets or certificate-manager annotations, and storage class. Both origins must resolve and have trusted TLS; Reforge waits for Authentik discovery during startup. The supplied example uses `app.reforgeapp.dev` and `auth.reforgeapp.dev`; Cloudflare credentials must cover that zone.
2. Select matching application, docs, and runner image versions. By default they inherit `Chart.yaml`'s `appVersion`; override `image.tag`, `docs.image.tag`, and `runner.image.tag` together. Keep `runner.enabled=false` until an unprivileged-compatible version is available. For private registries, supply `imagePullSecrets`; public images need none.
3. Use `examples/argocd.yaml` as the Argo CD Application, or your existing Helm GitOps controller. Pin `targetRevision` to a reviewed commit. Create the namespace before pre-install hooks run; Argo's `CreateNamespace=true` handles this. Use a full sync, since selective sync skips provisioning hooks. Do not deploy both this chart and the earlier raw Reforge manifests into the same namespace.
4. Wait for PostgreSQL role setup, Reforge schema migrations/grants, and Authentik provider provisioning. The control pod runs these init steps before serving requests. Sign into Authentik as `akadmin` with the generated bootstrap password, then sign into Reforge. Use Reforge's bootstrap token to create the first organisation and its owner. Configure repository/model connections and budgets.
5. Set `secrets.bootstrap.enabled=false` after creating the organisation. Change the initial Authentik administrator password. Store recoverable Secret copies with database and artifact backups.

Local validation only:

```sh
helm lint charts/reforge --strict
helm template reforge charts/reforge --namespace reforge -f examples/reforgeapp.yaml
helm package charts/reforge --destination dist
```

Generated secrets

An install/upgrade hook creates missing Secrets using cryptographic randomness. Helm rendering is deterministic; upgrades and GitOps refreshes do not regenerate credentials. Existing generated Secrets are validated and reused, including expired bootstrap tokens. The provisioner has namespace-scoped Secret creation and read access restricted to its generated names; application pods do not receive Kubernetes API credentials.

For release `reforge`, generated Secrets contain:

| Secret | Keys |
| --- | --- |
| `reforge-app` | `encryption-key`, `bootstrap-token`, `bootstrap-expires-at` |
| `reforge-database` | `admin-password`, `migrator-password`, `runtime-password` |
| `reforge-authentik` | `secret-key`, `bootstrap-password`, `database-password`, `client-secret` |

The encryption key contains base64-encoded 32 random bytes. Database passwords and bootstrap tokens contain 32 random bytes encoded as hex. Reforge bootstrap expires after `secrets.bootstrap.ttlHours` (default 24 hours); it can be consumed only once. If an unused token expires, application bootstrap state needs an explicit administrative recovery; changing Helm values does not reset its database record.

Read initial credentials locally without placing them in Git:

```sh
kubectl -n reforge get secret reforge-authentik -o jsonpath='{.data.bootstrap-password}' | base64 --decode
kubectl -n reforge get secret reforge-app -o jsonpath='{.data.bootstrap-token}' | base64 --decode
```

Generated Secrets and PVCs remain after release deletion. Restore them together: replacing the encryption key makes stored repository/model credentials unreadable; replacing database initialization passwords does not update existing database roles. Secrets are not automatically encrypted at rest by this chart; use your cluster's encryption and access controls. No credentials appear in Helm values, rendered templates, or provisioner logs.

Bring your own

- Application secrets: set `secrets.existingSecret`. Provide `encryption-key`, and both bootstrap keys while bootstrap is enabled. The chart never modifies supplied Secrets.
- Database credentials: set `postgresql.existingSecret`. Bundled PostgreSQL needs all three database keys. For external PostgreSQL, also set `postgresql.enabled=false` and `externalDatabase` host/name/users/port/TLS; only `migrator-password` and `runtime-password` are required. Provision those roles yourself. The migrator must own the Reforge database/schema; runtime must have no ownership, schema CREATE, superuser, or bypass-RLS privilege. Chart startup runs migrations and grants runtime access using the configured names. `examples/external.yaml` shows this configuration.
- Existing OIDC: set `authentik.enabled=false`, `oidc.issuer`, `oidc.clientID`, and `oidc.existingSecret` containing `client-secret`. Register exact callback `<publicURL>/auth/callback` and scopes `openid profile email`.
- Authentik credentials: set `authentik.existingSecret` with its four keys. With external PostgreSQL, additionally configure `authentik.database` and create that database/user yourself. With bundled PostgreSQL, Authentik uses its own database and restricted role.
- Built-in runner: `runner.enabled=false` allows separately enrolled runners. Otherwise the runner shares its generated token/catalog with control through private files, uses one slot by default (currently 6 GiB memory and two CPUs per job; increase container resources when adding slots), and has no privileged mode or host filesystem mounts. `runtimeClassName` and `extraArgs` accommodate the final unprivileged runtime contract; merely setting a RuntimeClass does not prove sandbox compatibility.

Database TLS

Bundled PostgreSQL defaults to namespace-restricted network access without transport TLS. Set `postgresql.tls.existingSecret` to enable verified TLS; the Secret must contain `tls.crt`, `tls.key`, and `ca.crt`, with a server certificate covering `<release>-postgresql` (or the name from `fullnameOverride`). External database connections default to `verify-full`; supply `externalDatabase.caSecret` containing `ca.crt` for a private CA. Authentik's external database has separate TLS settings. DNS and outbound provider access remain unrestricted by NetworkPolicy.

Operations

Back up PostgreSQL, artifacts, and all generated/supplied Secrets. Authentik account/provider data and signing keys live in PostgreSQL; uploaded media is ephemeral in this initial chart. Database and control updates are single-replica restarts. Back up before upgrades; Reforge migrations run on control startup, so rollback may require database recovery. Helm/Argo secret provisioning hooks must remain enabled.

Secret changes alone do not restart pods: roll affected workloads through GitOps, or use your existing restart controller. PostgreSQL admin password changes also require an explicit database role change. Roll PostgreSQL after TLS server-certificate renewal. Generated Authentik bootstrap credentials apply only to initial setup; subsequent password changes belong in Authentik.

Checks: `python scripts/test_provisioning.py` and `python scripts/check_chart.py` (PyYAML 6.0.3). CI also runs Helm lint, Kubernetes schema validation, and packaging.
