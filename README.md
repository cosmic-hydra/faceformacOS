# faceformacOS

**Face ID–style authentication for macOS** — verify your face from the command line and use a face-gated credential vault as a password-autofill alternative. On-device, offline, no telemetry.

---

## What this is

macOS has Touch ID but no built-in facial unlock. This project adds one, reusing the proven on-device face-recognition pipeline from [**FaceGate-Mac**](https://github.com/dweep-desai/FaceGate-Mac) (MIT) and extending it from *app-locking* to **scriptable, OS-level authentication**:

| Capability | FaceGate-Mac | faceformacOS |
| --- | --- | --- |
| Lock individual apps behind a face | ✅ | ✅ (bundled FaceGate app) |
| Scriptable **face verification CLI** (exit code = match) | — | ✅ (`faceunlock-verify`) |
| **Password autofill** after face match | — | ✅ (face-gated Keychain + auto-type) |
| Software 2D **liveness / anti-spoof** | ✅ | ✅ (blink + head-pose challenge) |

## Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │              FaceUnlockCore (Swift)           │
                 │  HeadlessCamera → FaceDetector → Liveness →   │
                 │  FaceEmbedder(CoreML) → FaceMatcher(cosine)   │
                 │  CryptoHelper(AES-256-GCM) · Keychain vault   │
                 └───────────────┬───────────────┬──────────────┘
        enroll face              │               │           store/read secret
   ┌────────────────┐   ┌────────▼───────┐  ┌────▼─────────────┐
   │ faceunlock-    │   │ faceunlock-    │  │ faceunlock-      │
   │ enroll (CLI)   │   │ verify (CLI)   │  │ autofill (CLI)   │
   └────────────────┘   └────────────────┘  └──────────────────┘
                          exit 0 = match
```

- **`FaceUnlockCore`** — a SwiftPM library: headless camera capture, Vision face detection, a Core ML embedder (512-d MobileFaceNet), cosine matcher, a 2D liveness detector, AES-256-GCM encrypted enrollment store, and a Keychain-backed credential vault. Ported/adapted from FaceGate.
- **CLIs** — `faceunlock-enroll` (register a face → encrypted template), `faceunlock-verify` (match within a timeout → exit code, suitable for scripting), `faceunlock-autofill` (face-gated release of a stored secret, with optional auto-type).
- **`FaceGate/`** — the vendored FaceGate menu-bar app (app-locking GUI), buildable with XcodeGen via the top-level `Makefile` and `project.yml`. See [docs/FaceGate-README.md](docs/FaceGate-README.md).

## Requirements

- Apple Silicon Mac, macOS 14+ (developed on macOS 27 / M4).
- **Swift toolchain** (Command Line Tools is enough for the CLIs; full **Xcode** + [XcodeGen](https://github.com/yonaskolb/XcodeGen) are only needed for the FaceGate menu-bar GUI).
- A built-in or external camera.
- A **Core ML face-embedding model** for real recognition (bundled — see Limitations).

## Build

```bash
swift build -c release        # builds FaceUnlockCore + the three CLIs
swift test                     # runs the FaceUnlockCore test suite

# Optional: build the FaceGate menu-bar app (requires Xcode + xcodegen)
make build
```

The built CLIs land in `.build/release/`. Point them at the bundled model with
`--model FaceGate/ML/FaceEmbedding.mlmodelc` (or install the model to
`~/Library/Application Support/faceunlock/`, `/usr/local/share/faceunlock/`, or set
`FACEUNLOCK_MODEL`).

## Honest limitations & security model

This is a **convenience layer against casual physical access**, not a defense against a determined, targeted attacker. Read before installing:

- **No depth hardware.** Macs have a 2D FaceTime camera, not a TrueDepth sensor. "Liveness" here is software (blink detection + a head-pose challenge + basic anti-spoof), which raises the bar against a photo but does **not** match iPhone Face ID's security.
- **Recognition model is bundled.** A 512-d MobileFaceNet Core ML model ships at `FaceGate/ML/FaceEmbedding.mlmodelc`, so real face recognition works out of the box. (If the model is ever absent, the embedder falls back to a weak pixel-average that is **not** trustworthy — the headless CLIs load the model from a file path so they use the real one.)
- **No system-login integration.** `faceunlock-verify` is a scriptable gate (exit 0 = match); it does not hook into `sudo`, the screensaver, or the pre-login / FileVault window.
- **Autofill/auto-type** works for app login forms and prompts via synthesized keystrokes (needs Accessibility permission); it does **not** work against secure input fields (the lock screen password box blocks synthetic events).
- **Face-gated Keychain** is only as strong as the process enforcing the gate. Secrets are AES-256-GCM encrypted at rest with the key in the Keychain.

## Credits & license

Face-recognition pipeline adapted from [FaceGate-Mac](https://github.com/dweep-desai/FaceGate-Mac) by Dweep Desai (MIT). This project is MIT-licensed — see [LICENSE](LICENSE).
