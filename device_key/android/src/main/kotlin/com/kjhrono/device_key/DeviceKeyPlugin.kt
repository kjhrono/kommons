package com.kjhrono.device_key

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec

/**
 * An EC P-256 key generated INSIDE the Android Keystore (StrongBox when the
 * device has one, else the TEE). The private key can never be read out, not
 * even with root; only its public key (X.509 SubjectPublicKeyInfo) leaves.
 */
class DeviceKeyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "kommons/device_key")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.argument<String>("alias")
        if (alias.isNullOrEmpty()) {
            result.error("bad_args", "alias is required", null)
            return
        }
        try {
            when (call.method) {
                "publicKey" -> result.success(publicKey(alias))
                "isHardwareBacked" -> result.success(isHardwareBacked(alias))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("keystore", e.message, null)
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun publicKey(alias: String): String {
        val ks = keyStore()
        if (!ks.containsAlias(alias)) generate(alias)
        val cert = ks.getCertificate(alias)
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    private fun generate(alias: String) {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                builder.setIsStrongBoxBacked(true)
            }
            return builder.build()
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.initialize(spec(strongBox = true))
                generator.generateKeyPair()
                return
            } catch (_: StrongBoxUnavailableException) {
                // No StrongBox chip: the TEE below.
            }
        }
        generator.initialize(spec(strongBox = false))
        generator.generateKeyPair()
    }

    private fun isHardwareBacked(alias: String): Boolean {
        val ks = keyStore()
        if (!ks.containsAlias(alias)) generate(alias)
        val key = ks.getKey(alias, null) as PrivateKey
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info.securityLevel != KeyProperties.SECURITY_LEVEL_SOFTWARE &&
                info.securityLevel != KeyProperties.SECURITY_LEVEL_UNKNOWN
        } else {
            @Suppress("DEPRECATION")
            info.isInsideSecureHardware
        }
    }
}
