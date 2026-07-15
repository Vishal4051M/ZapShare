import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static String _deriveKey(String userId) {
    const salt = 'MySuperSecretKeyForZapShareApp32';
    if (userId.isEmpty) return salt;

    final derived = List<int>.generate(32, (i) {
      final saltChar = salt.codeUnitAt(i);
      final userChar = userId.codeUnitAt(i % userId.length);
      return 32 + ((saltChar ^ userChar) % 95);
    });
    return String.fromCharCodes(derived);
  }

  static String _deriveIv(String userId) {
    const salt = 'ZapShareFixedIV1';
    if (userId.isEmpty) return salt;

    final derived = List<int>.generate(16, (i) {
      final saltChar = salt.codeUnitAt(i);
      final userChar = userId.codeUnitAt(i % userId.length);
      return 32 + ((saltChar ^ userChar) % 95);
    });
    return String.fromCharCodes(derived);
  }

  static Encrypter _getEncrypter(String userId) {
    final keyString = _deriveKey(userId);
    final key = Key.fromUtf8(keyString);
    return Encrypter(AES(key, mode: AESMode.cbc));
  }

  static IV _getIv(String userId) {
    final ivString = _deriveIv(userId);
    return IV.fromUtf8(ivString);
  }

  static String encrypt(String plainText, [String? userId]) {
    if (plainText.isEmpty) return plainText;
    try {
      final encrypter = _getEncrypter(userId ?? '');
      final iv = _getIv(userId ?? '');
      final encrypted = encrypter.encrypt(plainText, iv: iv);
      return encrypted.base64;
    } catch (e) {
      return plainText; // Fallback
    }
  }

  static String decrypt(String encryptedText, [String? userId]) {
    if (encryptedText.isEmpty) return encryptedText;
    try {
      final encrypter = _getEncrypter(userId ?? '');
      final iv = _getIv(userId ?? '');
      final decrypted = encrypter.decrypt64(encryptedText, iv: iv);
      return decrypted;
    } catch (e) {
      // If decryption fails (e.g. old plain text data), return generic text or original
      // Currently return original assuming it was plain text
      return encryptedText;
    }
  }
}
