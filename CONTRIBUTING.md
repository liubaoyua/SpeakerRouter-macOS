# Contributing

Thanks for helping improve SpeakerRouter.

## Development workflow

1. Build and test from the repository root:

   ```sh
   swift test
   ./Scripts/build-driver.sh
   ./Scripts/build-app.sh
   ```

2. Keep changes focused. Do not mix driver protocol changes, routing-policy
   changes, and UI redesigns in one commit unless they are inseparable.
3. Add deterministic tests for routing and shared-memory behavior. Keep real
   hardware verification separate from automated test claims.
4. Run `git diff --check` before submitting a change.

## Audio safety rules

- Do not allocate, lock, log, perform file IO, or call UI code from a real-time
  audio callback.
- Do not add high-frequency route retries. A failed route must wait for an
  explicit user action or a meaningful device change.
- Restore a known physical output before stopping or replacing the virtual
  driver whenever possible.
- Never open the virtual input stream from SpeakerRouterApp. Shared memory is the
  supported transport for the system mix.
- Changes to the shared-memory header require a protocol-version bump and a
  matching App and driver update.

## Driver changes

The supported driver build entry point is `Scripts/build-driver.sh`. The driver
is based on Apple's NullAudio sample, whose license is retained under
`Driver/SpeakerRouterHAL/LICENSE.txt`.

Installation changes must preserve bundle-identifier validation and require
explicit administrator authorization. Never broaden deletion targets beyond the
exact SpeakerRouterHAL bundle.

## Pull requests

Describe the user-visible behavior, automated checks, and any manual hardware
coverage. If a change affects audio recovery, include the failure scenario and
the physical-output rollback behavior.
