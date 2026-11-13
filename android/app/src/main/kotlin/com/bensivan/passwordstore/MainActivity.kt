package com.bensivan.passwordstore

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.ProviderException
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.bensivan.passwordstore/security"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "com.bensivan.passwordstore.biometric_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var clearClipboardRunnable: Runnable? = null
    private var clipboardClearDeadlineMs: Long = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        if (clipboardClearDeadlineMs > 0L && SystemClock.elapsedRealtime() >= clipboardClearDeadlineMs) {
            clearClipboardNow()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isStrongBiometricAvailable" -> {
                val status = BiometricManager.from(this)
                    .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                result.success(status == BiometricManager.BIOMETRIC_SUCCESS)
            }
            "getBiometricStatus" -> {
                val status = BiometricManager.from(this)
                    .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                val mapped = when (status) {
                    BiometricManager.BIOMETRIC_SUCCESS -> "available"
                    BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
                    BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
                    BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "no_hardware"
                    else -> "unavailable"
                }
                result.success(mapped)
            }
            "encryptWithBiometrics" -> {
                val plaintext = call.argument<String>("plaintext")
                if (plaintext.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "Plaintext passphrase is required", null)
                    return
                }
                encryptWithBiometrics(plaintext, result)
            }
            "decryptWithBiometrics" -> {
                val ciphertext = call.argument<String>("ciphertext")
                val iv = call.argument<String>("iv")
                if (ciphertext.isNullOrEmpty() || iv.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "Ciphertext and IV are required", null)
                    return
                }
                decryptWithBiometrics(ciphertext, iv, result)
            }
            "clearBiometricKey" -> {
                deleteKeystoreKey()
                result.success(null)
            }
            "copySensitive" -> {
                val text = call.argument<String>("text") ?: ""
                val clearAfterMs = (call.argument<Number>("clearAfterMs")?.toLong() ?: 45_000L)
                    .coerceAtLeast(1_000L)
                copySensitiveToClipboard(text, clearAfterMs)
                result.success(null)
            }
            "clearClipboard" -> {
                clearClipboardNow()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun generateBiometricSecretKey(): SecretKey {
        deleteKeystoreKey()
        val hasStrongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)

        if (hasStrongBox) {
            try {
                return createSecretKey(useStrongBox = true)
            } catch (_: ProviderException) {
                // Fall back to hardware TEE keystore when StrongBox rejects parameters
            } catch (_: Exception) {
                // Fall back to standard AndroidKeyStore
            }
        }
        return createSecretKey(useStrongBox = false)
    }

    private fun createSecretKey(useStrongBox: Boolean): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && useStrongBox) {
            builder.setIsStrongBoxBacked(true)
        }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(builder.build())
        return keyGenerator.generateKey()
    }

    private fun getExistingSecretKey(): SecretKey? {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
    }

    private fun deleteKeystoreKey() {
        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(KEY_ALIAS)) {
                keyStore.deleteEntry(KEY_ALIAS)
            }
        } catch (_: Exception) {
        }
    }

    private fun encryptWithBiometrics(plaintext: String, result: MethodChannel.Result) {
        val completed = AtomicBoolean(false)
        try {
            val secretKey = generateBiometricSecretKey()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, secretKey)

            val promptInfo = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Enable Biometric Unlock")
                .setSubtitle("Authenticate with strong biometrics to protect your GPG passphrase")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButtonText("Cancel")
                .setConfirmationRequired(false)
                .build()

            val prompt = BiometricPrompt(
                this,
                ContextCompat.getMainExecutor(this),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                        if (!completed.compareAndSet(false, true)) return
                        val unlockedCipher = authResult.cryptoObject?.cipher
                        if (unlockedCipher == null) {
                            deleteKeystoreKey()
                            result.error("CRYPTO_ERROR", "Missing authenticated cipher", null)
                            return
                        }
                        val bytes = plaintext.toByteArray(Charsets.UTF_8)
                        try {
                            val encrypted = unlockedCipher.doFinal(bytes)
                            val payload = mapOf(
                                "ciphertext" to Base64.encodeToString(encrypted, Base64.NO_WRAP),
                                "iv" to Base64.encodeToString(unlockedCipher.iv, Base64.NO_WRAP)
                            )
                            result.success(payload)
                        } catch (e: Exception) {
                            deleteKeystoreKey()
                            result.error("CRYPTO_ERROR", e.message ?: "Biometric encryption failed", null)
                        } finally {
                            bytes.fill(0)
                        }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (!completed.compareAndSet(false, true)) return
                        deleteKeystoreKey()
                        val code = if (
                            errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.ERROR_CANCELED
                        ) {
                            "BIOMETRIC_CANCELED"
                        } else {
                            "BIOMETRIC_ERROR"
                        }
                        result.error(code, errString.toString(), errorCode)
                    }
                }
            )
            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            if (completed.compareAndSet(false, true)) {
                deleteKeystoreKey()
                result.error("KEYSTORE_ERROR", e.message ?: "Failed to initialize biometric encryption", null)
            }
        }
    }

    private fun decryptWithBiometrics(ciphertextB64: String, ivB64: String, result: MethodChannel.Result) {
        val completed = AtomicBoolean(false)
        try {
            val secretKey = getExistingSecretKey()
            if (secretKey == null) {
                result.error("KEY_MISSING", "Biometric key not found. Unlock with your GPG passphrase.", null)
                return
            }

            val iv = Base64.decode(ivB64, Base64.NO_WRAP)
            val ciphertext = Base64.decode(ciphertextB64, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            try {
                cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            } catch (_: KeyPermanentlyInvalidatedException) {
                deleteKeystoreKey()
                result.error(
                    "BIOMETRIC_INVALIDATED",
                    "Biometric enrollment changed. Please unlock with your GPG passphrase and re-enable biometrics.",
                    null
                )
                return
            }

            val promptInfo = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Unlock Vault")
                .setSubtitle("Authenticate to unlock your password store")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButtonText("Use Passphrase")
                .setConfirmationRequired(false)
                .build()

            val prompt = BiometricPrompt(
                this,
                ContextCompat.getMainExecutor(this),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                        if (!completed.compareAndSet(false, true)) return
                        val unlockedCipher = authResult.cryptoObject?.cipher
                        if (unlockedCipher == null) {
                            result.error("CRYPTO_ERROR", "Missing authenticated cipher", null)
                            return
                        }
                        var decrypted: ByteArray? = null
                        try {
                            decrypted = unlockedCipher.doFinal(ciphertext)
                            val passphrase = String(decrypted, Charsets.UTF_8)
                            result.success(passphrase)
                        } catch (e: Exception) {
                            result.error("CRYPTO_ERROR", e.message ?: "Biometric decryption failed", null)
                        } finally {
                            decrypted?.fill(0)
                        }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (!completed.compareAndSet(false, true)) return
                        val code = if (
                            errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.ERROR_CANCELED
                        ) {
                            "BIOMETRIC_CANCELED"
                        } else {
                            "BIOMETRIC_ERROR"
                        }
                        result.error(code, errString.toString(), errorCode)
                    }
                }
            )
            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            if (completed.compareAndSet(false, true)) {
                result.error("KEYSTORE_ERROR", e.message ?: "Failed to initialize biometric unlock", null)
            }
        }
    }

    private fun copySensitiveToClipboard(text: String, clearAfterMs: Long) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        clipboard.setPrimaryClip(clip)

        clearClipboardRunnable?.let { mainHandler.removeCallbacks(it) }
        clipboardClearDeadlineMs = SystemClock.elapsedRealtime() + clearAfterMs
        val runnable = Runnable {
            clearClipboardNow()
        }
        clearClipboardRunnable = runnable
        mainHandler.postDelayed(runnable, clearAfterMs)
    }

    private fun clearClipboardNow() {
        clearClipboardRunnable?.let { mainHandler.removeCallbacks(it) }
        clearClipboardRunnable = null
        clipboardClearDeadlineMs = 0L

        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }
}
