# Security Policy

## Supported versions

Security fixes are applied to the latest source revision. Prebuilt public
releases are not currently provided.

## Reporting a vulnerability

Use the repository host's private vulnerability-reporting feature when
available. Do not publish administrator-authorization bypasses, unsafe driver
deletion paths, or shared-memory access issues in a public issue before a fix is
available.

Useful reports include the affected revision, macOS version, reproduction steps,
and the narrowest observed impact. Never include passwords or other credentials.

## Privileged boundary

The menu app runs as the logged-in user. Administrator authorization is used
only for the guarded driver-management script, which validates the exact bundle
identifier before installing or removing
`/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver`.
