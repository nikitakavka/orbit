<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.4

Orbit 1.1.4 contains an urgent safety fix for Slurm accounting polling.

## Critical `sacct` resource-safety fix

- Replaces broad `sacct --json` history requests with allocation-only, restricted `--parsable2` output over a two-hour window.
- Prevents overlapping Slurm queries across Orbit, OrbitPreview, and CLI processes with a shared per-user lock on the remote host.
- Enforces a remote 15-second timeout with a 2-second forced-termination grace period, so accounting processes are cleaned up even if the local SSH process exits.
- Limits accounting output to 16 MiB and other Slurm output to 64 MiB.
- Reduces job-ID accounting batches and adds exponential backoff after failed accounting polls.
- Gives each Orbit process its own SSH control socket and shortens stale control-master persistence.

These safeguards prevent a pathological Slurm accounting response from exhausting a remote user's cgroup and stalling SSH sessions.

## Updating

Orbit checks the signed update feed automatically and will show an update prompt. You can also install immediately with **Settings → General → Check for Updates…**.
