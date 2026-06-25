import 'dart:convert';

import 'package:crypto/crypto.dart';

/// OpenSSH-style SHA-256 host-key fingerprint (base64, no padding), used to
/// pin a host on first use and compare on later connects.
String fingerprintSha256(List<int> hostKeyBytes) =>
    base64.encode(sha256.convert(hostKeyBytes).bytes).replaceAll('=', '');

enum HostKeyVerdict { firstUse, match, mismatch }

/// TOFU decision: no stored pin -> firstUse; equal -> match; else -> mismatch.
HostKeyVerdict verifyHostKey(String? storedFingerprint, String presentedFingerprint) {
  if (storedFingerprint == null) return HostKeyVerdict.firstUse;
  return storedFingerprint == presentedFingerprint ? HostKeyVerdict.match : HostKeyVerdict.mismatch;
}
