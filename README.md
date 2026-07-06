# faceformacOS

**Face ID–style authentication for macOS** — unlock `sudo` / the lock screen with your face, and use a face-gated credential vault as a password-autofill / passkey alternative. On-device, offline, no telemetry.

> ⚠️ **Status: source complete, hardware validation in progress.** The SwiftPM package (`FaceUnlockCore` + three CLIs), the PAM module, and the install scripts are implemented. Read the security model below before wiring it into `/etc/pam.d`.

---

## What this is

macOS has Touch ID but no built-in facial unlock. This project adds one, reusing the proven on-device face-recognition pipeline from [**FaceGate-Mac**](https://github.com/dweep-desai/FaceGate-Mac) (MIT) and extending it from *app-locking* to **OS-level authentication**:

| Capability | FaceGate-Mac | faceformacOS |
| --- | --- | --- |
| Lock individual apps behind a face | ✅ | (out of scope) |
| Unlock **`sudo` / terminal auth** with a face | — | ✅ (PAM module) |
| Unlock the **screensaver / lock screen** | — | ⚠️ Howdy-style, with caveats |
| **Password autofill** after face match | — | ✅ (face-gated Keychain) |
| **Passkey / credential-provider** extension | — | ✅ design (needs Xcode to ship) |
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
   └────────────────┘   └────────┬───────┘  └──────────────────┘
                                 │ exit 0 = match
                        ┌────────▼────────┐
                        │ pam_faceunlock  │  →  /etc/pam.d/{sudo,screensaver}
                        │   (C, PAM)      │
                        └─────────────────┘
```

- **`FaceUnlockCore`** — a SwiftPM library: headless camera capture, Vision face detection, a Core ML embedder (512-d MobileFaceNet), cosine matcher, a 2D liveness detector, AES-256-GCM encrypted enrollment store, and a Keychain-backed credential vault. Ported/adapted from FaceGate.
- **CLIs** — `faceunlock-enroll` (register a face → encrypted template), `faceunlock-verify` (match within a timeout → exit code), `faceunlock-autofill` (face-gated release of a stored secret).
- **`pam_faceunlock`** — a PAM module that runs `faceunlock-verify` and returns success/failure, wired into `/etc/pam.d`.

## Requirements

- Apple Silicon Mac, macOS 14+ (developed on macOS 27 / M4).
- **Swift toolchain** (Command Line Tools is enough for the CLIs + PAM module; full **Xcode** is only needed for the optional menu-bar GUI and the credential-provider extension).
- A built-in or external camera.
- A **Core ML face-embedding model** for real recognition (see Limitations).

## Build & install

```bash
swift build -c release              # FaceUnlockCore + the three CLIs (CLT only, no Xcode)
make -C pam                         # PAM module (clang, universal binary)
sudo ./scripts/install.sh           # installs binaries + model; prints the pam.d line
sudo ./scripts/install.sh --enable-sudo          # …and wires /etc/pam.d/sudo_local
sudo ./scripts/install.sh --enable-screensaver   # …and the lock screen (experimental)
```

Then, as your normal user:

```bash
faceunlock-enroll --user "$USER" --frames 9      # look straight, then slightly to each side
faceunlock-verify --user "$USER" --timeout 10    # exit 0 = match; add --require-liveness
sudo -k; sudo true                               # face-unlocked sudo (test in a NEW terminal)
```

Face-gated credential vault:

```bash
faceunlock-autofill set  --label github          # secret read from stdin, never argv
faceunlock-autofill get  --label github | pbcopy # face scan (with liveness), then release
faceunlock-autofill type --label github          # face scan, then types it for you
```

### CLI ↔ PAM contract

`faceunlock-verify --user NAME --timeout SEC [--require-liveness]` exits
`0` = match, `1` = no match, `2` = error, and its last stdout line is always
`RESULT match|nomatch|error score=NN`. `pam_faceunlock.so` execs exactly
`/usr/local/bin/faceunlock-verify --user <user> --timeout 10` (root-ownership
checked, privileges dropped to the user, minimal env, hard kill past the
deadline) and maps exit 0 → `PAM_SUCCESS`, anything else → `PAM_AUTH_ERR`.
Module options: `timeout=N`, `require_liveness`, `debug`, `quiet`.

### Repo layout

```
Sources/FaceUnlockCore/    # library: camera, detector, liveness, embedder, matcher, stores
Sources/faceunlock-*/      # the three CLIs
pam/                       # pam_faceunlock.c + Makefile
scripts/                   # install.sh / uninstall.sh (pam.d wiring with backups)
extension/                 # AutoFill credential-provider reference (needs Xcode to build)
FaceGate/                  # upstream FaceGate-Mac app (pipeline source + bundled ML model)
```

## Honest limitations & security model

This is a **convenience layer against casual physical access**, not a defense against a determined, targeted attacker. Read before installing:

- **No depth hardware.** Macs have a 2D FaceTime camera, not a TrueDepth sensor. "Liveness" here is software (blink detection + a head-pose challenge + basic anti-spoof), which raises the bar against a photo but does **not** match iPhone Face ID's security.
- **Recognition model is bundled.** A 512-d MobileFaceNet Core ML model ships at `FaceGate/ML/FaceEmbedding.mlmodelc`, so real face recognition works out of the box. (If the model is ever absent, the embedder falls back to a weak pixel-average that is **not** trustworthy — the headless CLIs load the model from a file path so they use the real one.)
- **Which unlock surfaces actually work:** `sudo` and terminal auth — **yes**. Screensaver / lock screen — **often** (Howdy-style PAM), with caveats around camera access in a locked session. The pre-login / FileVault window — **no**; a background face daemon cannot drive it.
- **Autofill/auto-type** works for app login forms and prompts via synthesized keystrokes (needs Accessibility permission); it does **not** work against secure input fields (the lock screen password box blocks synthetic events).
- **Editing `/etc/pam.d` can lock you out** if done wrong. The installer backs up every file it touches, uses `sufficient` (not `required`) so password auth still works, and warns you to keep a root shell open and test in a new terminal before relying on it.
- **Face-gated Keychain** is only as strong as the process enforcing the gate. Secrets are AES-256-GCM encrypted at rest with the key in the Keychain.

## Credits & license

Face-recognition pipeline adapted from [FaceGate-Mac](https://github.com/dweep-desai/FaceGate-Mac) by Dweep Desai (MIT). This project is MIT-licensed — see [LICENSE](LICENSE).
