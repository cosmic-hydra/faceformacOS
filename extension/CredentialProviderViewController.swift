// CredentialProviderViewController.swift — REFERENCE IMPLEMENTATION ONLY.
//
// ⚠️ This file is NOT part of the SwiftPM build. An AutoFill Credential
// Provider is an *app extension*: it needs a host app bundle, the
// `com.apple.developer.authentication-services.autofill-credential-provider`
// entitlement, provisioning, and an Xcode (xcodebuild) build — none of which
// exist under Command Line Tools alone. It lives here so that when the
// project is opened with full Xcode, the extension target can be added and
// this file dropped in as-is.
//
// What it does once built: registers the FaceUnlock vault as a system
// AutoFill provider (System Settings → Passwords → AutoFill), so Safari and
// apps can request a credential; the extension face-verifies the user with
// FaceUnlockCore (camera + liveness) and only then returns the secret —
// passkey-style UX with a face instead of Touch ID.

#if canImport(AuthenticationServices) && REFERENCE_ONLY_NOT_BUILT

import AuthenticationServices
import FaceUnlockCore

final class CredentialProviderViewController: ASCredentialProviderViewController {

    // MARK: - Credential list UI

    /// Called when the user picks "FaceUnlock" in the AutoFill quick-type
    /// bar / password picker. Show the labels, verify, return the secret.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let vault = CredentialVault(user: nil)
        let labels = (try? vault.labels()) ?? []

        // Pick the label matching the requesting site when possible.
        let host = serviceIdentifiers.first?.identifier ?? ""
        let label = labels.first(where: { host.contains($0) }) ?? labels.first

        guard let label else {
            extensionContext.cancelRequest(withError: NSError(
                domain: ASExtensionErrorDomain,
                code: ASExtensionError.credentialIdentityNotFound.rawValue))
            return
        }
        verifyAndReturn(label: label)
    }

    /// Called for zero-tap autofill of a specific saved identity.
    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        // A face scan IS user interaction — hand off to the interactive path.
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        verifyAndReturn(label: credentialIdentity.recordIdentifier ?? CredentialVault.defaultLabel)
    }

    // MARK: - Face gate

    private func verifyAndReturn(label: String) {
        // Off the main thread: FaceVerifier.run() blocks while it drives the
        // camera → detect → liveness → embed → match pipeline.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var options = VerifyOptions()
            options.requireLiveness = true
            options.timeout = 15

            let outcome = FaceVerifier(options: options).run()

            DispatchQueue.main.async {
                switch outcome {
                case .match:
                    do {
                        let secret = try CredentialVault(user: nil).secret(for: label)
                        let credential = ASPasswordCredential(user: label, password: secret)
                        self.extensionContext.completeRequest(
                            withSelectedCredential: credential, completionHandler: nil)
                    } catch {
                        self.extensionContext.cancelRequest(withError: NSError(
                            domain: ASExtensionErrorDomain,
                            code: ASExtensionError.credentialIdentityNotFound.rawValue))
                    }
                case .noMatch, .error:
                    self.extensionContext.cancelRequest(withError: NSError(
                        domain: ASExtensionErrorDomain,
                        code: ASExtensionError.userCanceled.rawValue))
                }
            }
        }
    }
}

#endif
