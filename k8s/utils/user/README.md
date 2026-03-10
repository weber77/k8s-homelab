# User management utils

Scripts to **create** and **update** Kubernetes users (client certs + RBAC). Run from your workstation with `kubectl` and appropriate cluster access.

---

## Overview

| Script | Purpose |
|--------|---------|
| **new-user.sh** | Create a user: client cert (CSR API) + Role + RoleBinding. Outputs go into `<username>/`. |
| **update-user-rbac.sh** | Add or remove RBAC for an existing user. Checks current context permissions before apply/delete. |

Make scripts executable once:

```bash
chmod +x new-user.sh update-user-rbac.sh
```

---

## new-user.sh (create user)

Creates a client certificate for a user via the Kubernetes CSR API and applies a Role + RoleBinding with configurable verbs and resources. By default: read-only pods (`get`, `watch`, `list`) in the `default` namespace.

**Outputs** (all under `<username>/`): `<username>.key`, `<username>.csr`, `<username>.crt`, `csr.yaml`, `rbac.yaml`.

**Usage:**

```bash
./new-user.sh [options] <username>
```

| Option | Description |
|--------|-------------|
| `-n`, `--namespace <ns>` | Namespace for Role/RoleBinding (default: `default`) |
| `-r`, `--roles <verbs>` | Comma-separated RBAC verbs (default: `get,watch,list`) |
| `-R`, `--resource <res>` | Comma-separated resources (default: `pods`) |
| `-h`, `--help` | Show help |

**Examples:**

```bash
./new-user.sh alice
./new-user.sh -n kube-system -R pods,services alice
./new-user.sh -r get,list -R pods,configmaps bob
```

---

## update-user-rbac.sh (add or remove RBAC)

Add or remove the Role + RoleBinding for a user. Before applying or deleting, the script checks that the **current context user** can create/delete Role and RoleBinding in the target namespace (`kubectl auth can-i`). If not, it exits with an error.

**Usage:**

```bash
./update-user-rbac.sh (--add | --remove) [options] <username>
```

| Option | Description |
|--------|-------------|
| `--add` | Create/update RBAC. Applies from `<username>/rbac.yaml` (or regenerates with `-n` and optional `-r`, `-R`). |
| `--remove` | Remove Role and RoleBinding for the user in the given namespace. **Requires `-n`.** |
| `-n`, `--namespace <ns>` | Namespace (required for `--remove`; for `--add` used when regenerating with `-r`/`-R`) |
| `-r`, `--roles <verbs>` | Comma-separated verbs (only with `--add` and `-n`; default: `get,watch,list`) |
| `-R`, `--resource <res>` | Comma-separated resources (only with `--add` and `-n`; default: `pods`) |
| `-h`, `--help` | Show help |

**Examples:**

```bash
# Apply existing <username>/rbac.yaml (namespace read from file)
./update-user-rbac.sh --add alice

# Regenerate and apply RBAC in a namespace
./update-user-rbac.sh --add -n default -r get,list -R pods,configmaps alice

# Remove RBAC in a namespace
./update-user-rbac.sh --remove -n default alice
```

**Permission checks:** The script runs `kubectl auth can-i create role`, `can-i create rolebinding` (for `--add`) or `can-i delete role`, `can-i delete rolebinding` (for `--remove`) in the target namespace. Use a context that has permission to manage RBAC in that namespace.
