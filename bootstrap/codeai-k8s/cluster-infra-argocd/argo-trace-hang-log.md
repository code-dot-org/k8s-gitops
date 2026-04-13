# argo-trace hang log

## Attempt 1

Observed:
- `./bin/argo-trace` hangs in `fetch_argocd_lists_in_parallel`
- both wave-1 commands print `COMMAND START`
- neither prints `COMMAND RETURN` within 30s
- direct interactive `argocd --core app list` and `argocd --core appset list` return quickly

Ideas:
1. Wave 1 hangs only when the two Argo CLI calls run in parallel. If so, serialize wave 1.
2. `capture_command` blocks on `stdout_reader.value` / `stderr_reader.value` even after the child exits.
3. The generated `KUBECONFIG` path is involved, and one or both commands hang only under that env.

Chosen:
- idea 1

Result:
- failed
- serializing wave 1 changed the symptom but not the root cause
- with the change, only the first command started:
  - `COMMAND START: argocd --core appset list -o yaml`
  - no `COMMAND RETURN` within 30s

## Attempt 2

Observed:
- parallelism is not the root cause
- the first `argocd --core appset list -o yaml` hangs by itself inside `argo-trace`
- direct interactive `argocd --core appset list -o yaml` returns quickly

Ideas:
1. The generated shared `KUBECONFIG` is the trigger. Test the exact generated kubeconfig outside `argo-trace`.
2. `capture_command` is the trigger. The child exits, but pipe readers never see EOF. Replace pipe capture with tempfile capture.
3. `Open3.popen3(env, *command)` with the modified env is the trigger. Run the same command from a plain Ruby one-off with that env and compare.

Chosen:
- idea 1

Result:
- failed
- exact generated `KUBECONFIG` works outside `argo-trace`
- `KUBECONFIG=/var/folders/.../argo-trace-kubeconfig-codeai-k8s-argocd.yaml argocd --core appset list -o yaml`
  returned in about 6.5s with `[]`

## Attempt 3

Observed:
- the generated kubeconfig is fine
- the same command hangs only when `argo-trace` runs it through `capture_command`

Ideas:
1. `capture_command` hangs on `stdout.read` / `stderr.read`; the child exits but pipe EOF never arrives. Replace pipe capture with tempfile capture.
2. `Open3.popen3` itself is the problem, but `Open3.capture3` is fine. Replace the custom reader-thread code with `capture3`.
3. Logging to stdout around subprocess execution is involved. Move logging around the capture path or direct it elsewhere.

Chosen:
- idea 1

Result:
- failed
- `Open3.popen3` with the same generated kubeconfig works in a plain Ruby one-off
- `ArgoTrace.shell_command_runner.call(...)` hangs under `bundle exec ruby -e ...`
- so the problem is in the bundle-exec environment around subprocess launch, not the kubeconfig builder itself

## Attempt 4

Observed:
- plain Ruby one-off with `Open3.popen3(env, *command)` returns
- `bundle exec ruby -e 'load ./bin/argo-trace; ArgoTrace.shell_command_runner.call(...)'` hangs
- `./bin/argo-trace` also runs under `bundle exec`

Ideas:
1. Bundler environment leaks into child processes and wedges `argocd` or one of its children. Launch subprocesses under `Bundler.with_unbundled_env`.
2. The shebang `bundle exec ruby` is the trigger, and the subprocess launch should explicitly scrub `BUNDLE_*` / `RUBYOPT`.
3. `shell_command_runner` logging to stdout under Bundler is the trigger. Move logging to stderr or after capture.

Chosen:
- idea 1

Result:
- worked
- wrapping subprocess launch in `Bundler.with_unbundled_env` fixed both:
  - `bundle exec ruby -e 'load ./bin/argo-trace; ArgoTrace.shell_command_runner.call(...)'`
  - `./bin/argo-trace`
- full `./bin/argo-trace` now returns in about 3.9s on the empty cluster
- root cause was the bundled Ruby environment leaking into child process execution
