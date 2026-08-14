<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.0

Orbit 1.1.0 introduces signed in-app updates and expands Slurm array monitoring.

## Updates

- Adds Sparkle 2 with signed feeds, release notes, and archives.
- Requires explicit approval before downloading an update archive.
- Links each update prompt to its corresponding GitHub release.
- Adds optional Launch at Login support.

## Slurm arrays

- Uses `sacct` as the primary source for array totals and finished-task counts.
- Falls back to the `sbatch --array` option or the batch script's `#SBATCH --array` directive when accounting is unavailable.
- Supports grouped accounting records, hexadecimal task bitmaps, and nested state values returned by Slurm's JSON API.
- Preserves monotonic progress while recording the source of total and finished-task counts independently.

## Installation

Orbit 1.0.1 does not include the new update framework, so this version must be installed manually. Existing cluster profiles, SSH-key paths, settings, history, and metrics are retained. Subsequent releases can be installed from within Orbit.
