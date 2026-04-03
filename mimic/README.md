# mimic

This is a non-production imitation of `apps/`.

It exists to test Argo CD behavior against a small tree that preserves the
shapes we care about:

- `ApplicationSet` wrappers for `applicationset.yaml`
- passthrough of `application.yaml`
- recursive `app-of-apps` self-management
- simple HTTP services behind Ingress + `code.ai/dns-name`

Nothing under `mimic/` is meant to be part of the real cluster topology.
Use it only for experiments.
