This directory holds CodeAI release metadata consumed by Kargo.

- `builds/` contains the thin build-lock Freight records.
- `legacy-gitflow/` contains merge metadata used only for downstream promotion gates.

Rendered manifests are not stored here. They are written to `stage/*` branches under `apps/codeai/deployments/*/deploy/`.
