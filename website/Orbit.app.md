<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.1

Orbit 1.1.1 corrects shutdown behavior during first-run installation.

## Fixes

- Ensures **Open folders & quit** terminates Orbit promptly, even when SSH cleanup is waiting behind an active command.
- Uses an accurate status message when no newer compatible update is available.

Existing cluster profiles, settings, and monitoring history are unchanged.
