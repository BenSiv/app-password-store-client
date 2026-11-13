import Flutter
import LocalAuthentication
import Security
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "com.bensivan.passwordstore/security"
  private let keychainService = "com.bensivan.passwordstore.biometric"
  private let keychainAccount = "gpg-passphrase"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call: call, result: result)
    }
  }

  private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isStrongBiometricAvailable":
      let context = LAContext()
      var error: NSError?
      let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
      result(ok)

    case "getBiometricStatus":
      let context = LAContext()
      var error: NSError?
      if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
        result("available")
      } else if let laError = error as? LAError, laError.code == .biometryNotEnrolled {
        result("none_enrolled")
      } else if let laError = error as? LAError, laError.code == .biometryNotAvailable {
        result("no_hardware")
      } else {
        result("unavailable")
      }

    case "encryptWithBiometrics":
      guard let args = call.arguments as? [String: Any],
            let plaintext = args["plaintext"] as? String,
            !plaintext.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "Plaintext passphrase is required", details: nil))
        return
      }
      storeBiometricProtectedPassphrase(plaintext: plaintext, result: result)

    case "decryptWithBiometrics":
      readBiometricProtectedPassphrase(result: result)

    case "clearBiometricKey":
      deleteKeychainEntry()
      result(nil)

    case "copySensitive":
      let args = call.arguments as? [String: Any]
      let text = args?["text"] as? String ?? ""
      let clearAfterMs = args?["clearAfterMs"] as? Double ?? 45000.0
      let expiration = Date().addingTimeInterval(max(1.0, clearAfterMs / 1000.0))
      UIPasteboard.general.setItems(
        [[UTType.plainText.identifier: text]],
        options: [.expirationDate: expiration]
      )
      result(nil)

    case "clearClipboard":
      UIPasteboard.general.items = []
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func storeBiometricProtectedPassphrase(plaintext: String, result: @escaping FlutterResult) {
    let authContext = LAContext()
    authContext.localizedFallbackTitle = ""
    authContext.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: "Confirm biometrics to enable biometric unlock"
    ) { [weak self] success, authError in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if !success {
          let laCode = (authError as? LAError)?.code
          let code = (laCode == .userCancel || laCode == .systemCancel || laCode == .userFallback)
            ? "BIOMETRIC_CANCELED"
            : "BIOMETRIC_ERROR"
          result(FlutterError(code: code, message: authError?.localizedDescription ?? "Biometric authentication failed", details: nil))
          return
        }

        self.deleteKeychainEntry()
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
          nil,
          kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
          .biometryCurrentSet,
          &cfError
        ) else {
          result(FlutterError(code: "KEYSTORE_ERROR", message: "Could not create biometric access control", details: nil))
          return
        }

        let data = Data(plaintext.utf8)
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: self.keychainService,
          kSecAttrAccount as String: self.keychainAccount,
          kSecAttrAccessControl as String: access,
          kSecUseAuthenticationContext as String: authContext,
          kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
          result(["ciphertext": "keychain", "iv": "biometryCurrentSet"])
        } else {
          result(FlutterError(code: "KEYSTORE_ERROR", message: "Keychain store failed (\(status))", details: nil))
        }
      }
    }
  }

  private func readBiometricProtectedPassphrase(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      let context = LAContext()
      context.localizedFallbackTitle = "Use Passphrase"
      context.localizedReason = "Authenticate to unlock your password store"

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: self.keychainService,
        kSecAttrAccount as String: self.keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context
      ]

      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      DispatchQueue.main.async {
        if status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) {
          result(str)
        } else if status == errSecUserCanceled {
          result(FlutterError(code: "BIOMETRIC_CANCELED", message: "Canceled", details: nil))
        } else if status == errSecItemNotFound {
          result(FlutterError(code: "BIOMETRIC_INVALIDATED", message: "Biometric enrollment changed or key missing. Unlock with your GPG passphrase.", details: nil))
        } else {
          result(FlutterError(code: "BIOMETRIC_ERROR", message: "Biometric unlock failed (\(status))", details: nil))
        }
      }
    }
  }

  private func deleteKeychainEntry() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]
    SecItemDelete(query as CFDictionary)
  }
}
