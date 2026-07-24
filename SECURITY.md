# Security policy

## Scope

DUKA is an academic prototype. It must be deployed only in an isolated, disposable environment. The repository must never contain cloud credentials, OpenNebula host keys, Kubernetes `admin.conf` files, bootstrap join commands, API tokens, or production data.

## Handling secrets

- Keep credentials in a local `.env` file or in the deployment platform's secret store; do not commit them.
- Treat Kubernetes join commands and `admin.conf` as credentials. Generate them when needed, restrict them to the administrator, and rotate or revoke them after a demo.
- Kubernetes Secrets provide access control, not encryption at rest by themselves. For a production deployment, enable etcd encryption at rest with a KMS provider and use a dedicated secret manager such as Vault for key lifecycle management.
- Before every push, review `git status`, scan the staged diff for credentials, and confirm no local cluster configuration is included.

## Reporting a concern

Please report a suspected exposure privately to the maintainers listed in the project README. Do not open a public issue containing credentials, host addresses, or exploit steps.
