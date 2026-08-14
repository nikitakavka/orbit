<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.3

Orbit 1.1.3 adds signed in-app updates, Launch at Login, and accounting-backed Slurm array progress.

## Updates and macOS integration

- Adds Sparkle 2 with signed feeds, release notes, and update archives.
- Requires explicit approval before downloading an update.
- Links update prompts to the corresponding GitHub release.
- Checks for updates every 12 hours by default; automatic checks can be disabled in Settings.
- Adds optional Launch at Login support.
- Warns when Orbit is running outside `/Applications` or `~/Applications`, with a working **Open folders & quit** action.

## Slurm array monitoring

- Uses `sacct` as the primary source for array totals and finished-task counts.
- Falls back to `sbatch --array` or the batch script's `#SBATCH --array` directive when accounting is unavailable.
- Supports grouped accounting records, hexadecimal task bitmaps, and nested state values returned by Slurm's JSON API.
- Tracks total and finished-task provenance independently while keeping progress monotonic.

## Interface

- Updates the menu bar presentation, onboarding flow, settings, status icon, and project website.

## Installation

Orbit 1.0.1 does not include the new update framework, so this release must be installed manually. Existing cluster profiles, SSH-key paths, settings, history, and metrics are retained. Future releases can be installed from within Orbit.
