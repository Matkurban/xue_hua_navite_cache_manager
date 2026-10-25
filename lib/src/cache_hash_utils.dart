import 'dart:convert';
import 'dart:typed_data';

/// Pure-Dart MD5 and SHA-256 hash implementations used by the Web platform
/// and testing utilities.
class CacheHashUtils {
  const CacheHashUtils._();

  /// Computes a deterministic 64-character lowercase hex SHA-256 key from [input].
  static String sha256String(String input) {
    return sha256Hex(Uint8List.fromList(utf8.encode(input)));
  }

  /// Computes a lowercase hex SHA-256 digest of [bytes].
  static String sha256Hex(Uint8List bytes) {
    const k = <int>[
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    var h0 = 0x6a09e667;
    var h1 = 0xbb67ae85;
    var h2 = 0x3c6ef372;
    var h3 = 0xa54ff53a;
    var h4 = 0x510e527f;
    var h5 = 0x9b05688c;
    var h6 = 0x1f83d9ab;
    var h7 = 0x5be0cd19;

    final bitLength = bytes.length * 8;
    final padLen = ((56 - (bytes.length + 1) % 64) + 64) % 64;
    final totalLen = bytes.length + 1 + padLen + 8;
    final padded = Uint8List(totalLen);
    padded.setRange(0, bytes.length, bytes);
    padded[bytes.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint32(totalLen - 8, (bitLength ~/ 0x100000000) & 0xffffffff, Endian.big);
    bd.setUint32(totalLen - 4, bitLength & 0xffffffff, Endian.big);

    final w = Uint32List(64);

    for (var chunkOffset = 0; chunkOffset < totalLen; chunkOffset += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(chunkOffset + i * 4, Endian.big);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;
      var f = h5;
      var g = h6;
      var h = h7;

      for (var i = 0; i < 64; i++) {
        final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (h + s1 + ch + k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;

        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + h) & 0xffffffff;
    }

    final out = StringBuffer();
    for (final v in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  /// Computes a lowercase hex MD5 digest of [bytes].
  static String md5Hex(Uint8List bytes) {
    const s = <int>[
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];

    var a0 = 0x67452301;
    var b0 = 0xefcdab89;
    var c0 = 0x98badcfe;
    var d0 = 0x10325476;

    final bitLength = bytes.length * 8;
    final padLen = ((56 - (bytes.length + 1) % 64) + 64) % 64;
    final totalLen = bytes.length + 1 + padLen + 8;
    final padded = Uint8List(totalLen);
    padded.setRange(0, bytes.length, bytes);
    padded[bytes.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint32(totalLen - 8, bitLength & 0xffffffff, Endian.little);
    bd.setUint32(totalLen - 4, (bitLength ~/ 0x100000000) & 0xffffffff, Endian.little);

    final m = Uint32List(16);
    for (var offset = 0; offset < totalLen; offset += 64) {
      for (var i = 0; i < 16; i++) {
        m[i] = bd.getUint32(offset + i * 4, Endian.little);
      }

      var a = a0;
      var b = b0;
      var c = c0;
      var d = d0;

      for (var i = 0; i < 64; i++) {
        int f;
        int g;
        if (i < 16) {
          f = (b & c) | ((~b & 0xffffffff) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d & 0xffffffff) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | (~d & 0xffffffff));
          g = (7 * i) % 16;
        }
        final temp = d;
        d = c;
        c = b;
        final sum = (a + f + k[i] + m[g]) & 0xffffffff;
        b = (b + _rotl32(sum, s[i])) & 0xffffffff;
        a = temp;
      }

      a0 = (a0 + a) & 0xffffffff;
      b0 = (b0 + b) & 0xffffffff;
      c0 = (c0 + c) & 0xffffffff;
      d0 = (d0 + d) & 0xffffffff;
    }

    final digestBytes = Uint8List(16);
    final outBd = ByteData.sublistView(digestBytes);
    outBd.setUint32(0, a0, Endian.little);
    outBd.setUint32(4, b0, Endian.little);
    outBd.setUint32(8, c0, Endian.little);
    outBd.setUint32(12, d0, Endian.little);

    final hex = StringBuffer();
    for (final b in digestBytes) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  static int _rotr32(int x, int n) => ((x >>> n) | ((x << (32 - n)) & 0xffffffff)) & 0xffffffff;
  static int _rotl32(int x, int n) => (((x << n) & 0xffffffff) | (x >>> (32 - n))) & 0xffffffff;
}
