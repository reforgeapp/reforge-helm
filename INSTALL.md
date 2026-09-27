Reforge Helm chart bundles PostgreSQL, Authentik, docs, and the built-in runner. Disable bundled services and reference existing Secrets to use your own infrastructure.

The built-in runner launches restricted Kubernetes workspace pods. Kubernetes 1.31 or newer and a CNI enforcing NetworkPolicy are required. Runner unit/race tests and restricted-container startup pass; live Kubernetes repair execution remains unverified.

Deployment

1. Copy `examples/reforgeapp.yaml` into your GitOps configuration. Set the Reforge and Authentik HTTPS origins, ingress class, TLS Secrets or certificate-manager annotations, and storage class. Both origins must resolve and have trusted TLS; Reforge waits for Authentik discovery during startup. The supplied example uses `app.reforgeapp.dev` and `auth.reforgeapp.dev`; Cloudflare credentials must cover that zone.
2. Select matching application, docs, and runner image versions. By default they inherit `Chart.yaml`'s `appVersion`; override `image.tag`, `docs.image.tag`, and `runner.image.tag` together. Workspace images are separately pinned by OCI digest in `runner.kubernetes.images`; update those pins together with the compatible runner release. Published public Reforge images allow anonymous pulls. For private registries, supply `imagePullSecrets`; public images need none.
3. Use `examples/argocd.yaml` as the Argo CD Application, or your existing Helm GitOps controller. Pin `targetRevision` to a chart version. Create the namespace before pre-install hooks run; Argo's `CreateNamespace=true` handles this. Use a full sync, since selective sync skips provisioning hooks. Do not deploy both this chart and earlier raw Reforge manifests into the same namespace.
4. Wait for PostgreSQL role setup, Reforge schema migrations/grants, and Authentik provider provisioning. The control pod runs these init steps before serving requests. Sign into Authentik as `akadmin` with the generated bootstrap password, then sign into Reforge. Use Reforge's bootstrap token to create the first organisation and its owner. Configure repository/model connections and budgets.
5. Set `secrets.bootstrap.enabled=false` after creating the organisation. Change the initial Authentik administrator password. Store recoverable Secret copies with database and artifact backups.

Local validation only:

```sh
helm lint charts/reforge --strict --kube-version 1.36.3
helm template reforge charts/reforge --namespace reforge --kube-version 1.36.3 -f examples/reforgeapp.yaml
helm package charts/reforge --destination dist
```

Published releases are available from GitHub Pages:

```sh
helm repo add reforge https://reforgeapp.github.io/reforge-helm
helm repo update reforge
helm upgrade --install reforge reforge/reforge --namespace reforge --create-namespace --version 0.1.1 -f values.yaml
```

Generated secrets

An install/upgrade hook creates missing Secrets using cryptographic randomness. Helm rendering is deterministic; upgrades and GitOps refreshes do not regenerate credentials. Existing generated Secrets are validated and reused, including expired bootstrap tokens. The provisioner has namespace-scoped Secret creation and read access restricted to its generated names; only the provisioner and runner containers receive Kubernetes API credentials. The runner credential is mounted only into its container and is authorized solely for workspace pod operations in a separate namespace.

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
- Built-in runner: `runner.enabled=false` allows separately enrolled runners. Otherwise the runner shares its generated token/catalog with control through private files and starts restricted workspace pods using namespace-scoped create/get/list/delete/exec permissions. There are no privileged containers or host filesystem mounts. `runner.kubernetes.runtimeClassName` applies to workspace pods; it does not change the control pod runtime.

Gateway API

Set `gatewayAPI.enabled=true` and `gatewayAPI.parentRefs` to an existing Gateway's HTTPS listener. Set `ingress.enabled=false` and `authentik.ingress.enabled=false` for Gateway-only routing. `examples/gateway-api.yaml` targets `kgateway-system/private`, listener `https`, with optional HTTP-to-HTTPS redirects on listener `http`.

The chart creates HTTPRoutes for Reforge (`/`), docs (`/docs`), and bundled Authentik. Set `gatewayAPI.httpRedirectParentRefs=[]` to omit redirect routes. When using external OIDC, no Authentik route is created. Application and identity hostnames come from their existing `publicURL` values; custom HTTPS ports are retained in redirects.

Install Gateway API v1 CRDs/controller separately. The Gateway must terminate trusted TLS for both `app.reforgeapp.dev` and `auth.reforgeapp.dev` (or your selected hostnames), and its listener `allowedRoutes` must permit the release namespace. The chart does not create or modify Gateways, certificates, or DNS. Ingress and Gateway routing can coexist when both are deliberately enabled.

Workspace isolation

The chart creates a dedicated `<application-namespace>-<release>-workspaces` namespace with restricted Pod Security Admission. Set `runner.kubernetes.namespace` to override it; with `createNamespace=false`, provision that dedicated namespace and restricted admission policy through GitOps first. Never use the application namespace or a namespace containing other workloads/secrets. Workspace NetworkPolicies always deny ingress and egress except TCP8086 to the runner's registry proxy, even when application `networkPolicy.enabled=false`.

Only the runner mounts its projected API token. Workspaces mount no service-account credentials and use UID65532, a read-only root filesystem, dropped capabilities, and RuntimeDefault seccomp. Artifacts and snapshots stream through the Kubernetes exec API; workspaces need no application PVC or Secret access.

Default workspace limits are two CPUs, 6 GiB RAM, and 3 GiB scratch space. `runner.kubernetes.cpus`, `memoryBytes`, and `diskBytes` configure per-workspace limits; `runner.resources` configures the coordinator itself. `runner.slots` controls concurrent jobs. Configure kubelet `podPidsLimit` on eligible nodes through node GitOps: Kubernetes has no per-Pod PID limit field and the backend cannot enforce its old local process limit. The reviewed cluster currently reports `podPidsLimit=-1` on all three nodes; fix that before unattended repairs. [Kubernetes PID limits](https://kubernetes.io/docs/concepts/policy/pid-limiting/)

Standard runtimes share the host kernel. Set a supported gVisor/Kata RuntimeClass if stronger isolation is required. Current workspace images are amd64; the backend does not inherit chart `nodeSelector` or tolerations. Mixed-architecture/tainted clusters need appropriate RuntimeClass scheduling or an application backend extension. Existing cluster nodes are all amd64; no gVisor/Kata RuntimeClass is currently installed.

Private workspace image pull Secrets must exist in the workspace namespace and be named in `runner.kubernetes.imagePullSecrets`. Application `imagePullSecrets` remain separate. Workspace images must contain Reforge's workspace helper; plain language-toolchain images are insufficient.

Database TLS

Bundled PostgreSQL defaults to namespace-restricted network access without transport TLS. Set `postgresql.tls.existingSecret` to enable verified TLS; the Secret must contain `tls.crt`, `tls.key`, and `ca.crt`, with a server certificate covering `<release>-postgresql` (or the name from `fullnameOverride`). External database connections default to `verify-full`; supply `externalDatabase.caSecret` containing `ca.crt` for a private CA. Authentik's external database has separate TLS settings. DNS and outbound provider access remain unrestricted by NetworkPolicy.

Operations

Back up PostgreSQL, artifacts, and all generated/supplied Secrets. Authentik account/provider data and signing keys live in PostgreSQL; uploaded media is ephemeral in this initial chart. Database and control updates are single-replica restarts. Back up before upgrades; Reforge migrations run on control startup, so rollback may require database recovery. Helm/Argo secret provisioning hooks must remain enabled.

Secret changes alone do not restart pods: roll affected workloads through GitOps, or use your existing restart controller. PostgreSQL admin password changes also require an explicit database role change. Roll PostgreSQL after TLS server-certificate renewal. Generated Authentik bootstrap credentials apply only to initial setup; subsequent password changes belong in Authentik.

Checks: `python scripts/test_provisioning.py` and `python scripts/check_chart.py` (PyYAML 6.0.3). CI also runs Helm lint, Kubernetes schema validation, and packaging.
