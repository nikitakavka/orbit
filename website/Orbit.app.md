<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.2

Orbit 1.1.2 restores the installation-location reminder for existing setups.

## Fix

- Shows **Move Orbit to Applications** whenever Orbit starts from Downloads, App Translocation, or another location outside `/Applications` and `~/Applications`.
- Keeps the reminder independent of onboarding completion, while allowing it to be dismissed for the current session.

Existing cluster profiles, settings, and monitoring history are unchanged.
