void main() {
  String ip = "192.168.1.5";
  print("Original IP: $ip");

  String code = _ipToCode(ip);
  print("Code: $code");

  String decodedIp = _codeToIp(code);
  print("Decoded IP: $decodedIp");

  if (ip == decodedIp) {
    print("SUCCESS: IP matches!");
  } else {
    print("FAILURE: IP mismatch!");
  }

  // Test generic IP
  testIp("10.0.0.2");
  testIp("172.16.254.1");
}

void testIp(String ip) {
  String code = _ipToCode(ip);
  String decoded = _codeToIp(code);
  print("Testing $ip -> $code -> $decoded : ${ip == decoded ? 'OK' : 'FAIL'}");
}

String _ipToCode(String ip) {
  if (ip.isEmpty) return '';
  try {
    final parts = ip.split('.').map(int.parse).toList();
    if (parts.length != 4) return '';
    int n = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    String code = n.toRadixString(36).toUpperCase();
    return code.padLeft(8, '0');
  } catch (e) {
    return '';
  }
}

String _codeToIp(String code) {
  try {
      final codeClean = code.trim().toUpperCase();
      final n = int.parse(codeClean, radix: 36);
      String ip = '${(n >> 24) & 0xFF}.${(n >> 16) & 0xFF}.${(n >> 8) & 0xFF}.${n & 0xFF}';
      return ip;
  } catch (e) {
    return 'Error: $e';
  }
}
