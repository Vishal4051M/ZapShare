import 'package:encrypt/encrypt.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class EncryptionService {
  // Use a fixed Key and IV for deterministic encryption (needed for DB deduplication)
  // Use a fixed Key and IV for deterministic encryption (needed for DB deduplication)
  static Encrypter get _encrypter {
    final keyString =
        dotenv.env['ENCRYPTION_KEY'] ?? 'MySuperSecretKeyForZapShareApp32';
    final ivString = dotenv.env['ENCRYPTION_IV'] ?? 'ZapShareFixedIV1';

    final key = Key.fromUtf8(keyString);
    return Encrypter(AES(key, mode: AESMode.cbc));
  }

  static IV get _iv {
    final ivString = dotenv.env['ENCRYPTION_IV'] ?? 'ZapShareFixedIV1';
    return IV.fromUtf8(ivString);
  }

  static String encrypt(String plainText) {
    if (plainText.isEmpty) return plainText;
    try {
      final encrypted = _encrypter.encrypt(plainText, iv: _iv);
      return encrypted.base64;
    } catch (e) {
      return plainText; // Fallback
    }
  }

  static String decrypt(String encryptedText) {
    if (encryptedText.isEmpty) return encryptedText;
    try {
      // Check if it looks like base64 (very basic check)
      // Or just try to decrypt
      final decrypted = _encrypter.decrypt64(encryptedText, iv: _iv);
      return decrypted;
    } catch (e) {
      // If decryption fails (e.g. old plain text data), return generic text or original
      // Currently return original assuming it was plain text
      return encryptedText;
    }
  }
}
