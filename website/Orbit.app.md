<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Orbit 1.1.3

Orbit 1.1.3 corrects the **Open folders & quit** action in the installation reminder.

## Fix

- Opens the source and Applications folders, saves the onboarding resume point, and exits promptly.
- Avoids a shutdown deadlock that could leave Orbit running with monitoring stopped.

Existing cluster profiles, settings, and monitoring history are unchanged.
