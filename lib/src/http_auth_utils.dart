// Copyright (c) 2018, Marco Esposito (marcoesposito1988@gmail.com).
// Please see the AUTHORS file for details. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:math' as math;

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

class HttpConstants {
  static const headerWwwAuthenticate = 'www-authenticate';
  static const headerAuthorization = 'Authorization';

  static const authSchemeDigest = 'digest';
  static const authSchemeBasic = 'basic';
}

enum AuthenticationScheme {
  basic,
  digest,
}

Map<String, String>? splitAuthenticateHeader(String header) {
  if (!header.startsWith('Digest ')) {
    return null; // TODO exception?
  }
  header = header.substring(7); // remove 'Digest '

  var ret = <String, String>{};

  final components = header.split(',').map((token) => token.trim());
  for (var component in components) {
    final kv = component.split('=');
    ret[kv[0]] = kv.getRange(1, kv.length).join('=').replaceAll('"', '');
  }
  return ret;
}

String sha256Hash(String data) {
  var content = const Utf8Encoder().convert(data);
  var sha256 = crypto.sha256;
  var digest = sha256.convert(content).toString();
  return digest;
}

String md5Hash(String data) {
  var content = Utf8Encoder().convert(data);
  var md5 = crypto.md5;
  var digest = md5.convert(content).toString();
  return digest;
}

// from http_retry
/// Returns a copy of [original].
http.Request _copyNormalRequest(http.Request original) {
  var request = http.Request(original.method, original.url);
  request.followRedirects = original.followRedirects;
  request.headers.addAll(original.headers);
  request.maxRedirects = original.maxRedirects;
  request.persistentConnection = original.persistentConnection;
  request.body = original.body;

  return request;
}

http.BaseRequest copyRequest(http.BaseRequest original) {
  if (original is http.Request) {
    return _copyNormalRequest(original);
  } else {
    throw UnimplementedError(
        'cannot handle yet requests of type ${original.runtimeType}');
  }
}

// Digest auth

String _formatNonceCount(int nc) {
  return nc.toRadixString(16).padLeft(8, '0');
}

String _computeHA1(String realm, String? algorithm, String username,
    String password, String? nonce, String? cnonce) {
  if (algorithm == 'MD5') {
    final token1 = '$username:$realm:$password';
    return md5Hash(token1);
  } else if (algorithm == 'MD5-sess') {
    final token1 = '$username:$realm:$password';
    final md51 = md5Hash(token1);
    final token2 = '$md51:$nonce:$cnonce';
    return md5Hash(token2);
  } else if (algorithm == 'SHA-256') {
    final token1 = '$username:$realm:$password';
    return sha256Hash(token1);
  } else if (algorithm == 'SHA-256-sess') {
    final token1 = '$username:$realm:$password';
    final sha256_1 = sha256Hash(token1);
    final token2 = '$sha256_1:$nonce:$cnonce';
    return sha256Hash(token2);
  } else {
    throw ArgumentError.value(algorithm, 'algorithm', 'Unsupported algorithm');
  }
}

Map<String, String?> computeResponse(
    String method,
    String path,
    String body,
    String? algorithm,
    String? qop,
    String? opaque,
    String realm,
    String? cnonce,
    String? nonce,
    int nc,
    String username,
    String password) {
  var ret = <String, String?>{};

  algorithm ??= 'MD5';
  final ha1 = _computeHA1(realm, algorithm, username, password, nonce, cnonce);

  String ha2;

  if (algorithm.startsWith('MD5')) {
    if (qop == 'auth-int') {
      final bodyHash = md5Hash(body);
      final token2 = '$method:$path:$bodyHash';
      ha2 = md5Hash(token2);
    } else {
      // qop in [null, auth]
      final token2 = '$method:$path';
      ha2 = md5Hash(token2);
    }
  } else {
    if (qop == 'auth-int') {
      final bodyHash = sha256Hash(body);
      final token2 = '$method:$path:$bodyHash';
      ha2 = sha256Hash(token2);
    } else {
      // qop in [null, auth]
      final token2 = '$method:$path';
      ha2 = sha256Hash(token2);
    }
  }

  final nonceCount = _formatNonceCount(nc);
  ret['username'] = username;
  ret['realm'] = realm;
  ret['nonce'] = nonce;
  ret['uri'] = path;
  if (qop != null) {
    ret['qop'] = qop;
  }
  ret['nc'] = nonceCount;
  ret['cnonce'] = cnonce;
  if (opaque != null) {
    ret['opaque'] = opaque;
  }
  ret['algorithm'] = algorithm;

  if (algorithm.startsWith('MD5')) {
    if (qop == null) {
      final token3 = '$ha1:$nonce:$ha2';
      ret['response'] = md5Hash(token3);
    } else if (qop == 'auth' || qop == 'auth-int') {
      final token3 = '$ha1:$nonce:$nonceCount:$cnonce:$qop:$ha2';
      ret['response'] = md5Hash(token3);
    }
  } else {
    if (qop == null) {
      final token3 = '$ha1:$nonce:$ha2';
      ret['response'] = sha256Hash(token3);
    } else if (qop == 'auth' || qop == 'auth-int') {
      final token3 = '$ha1:$nonce:$nonceCount:$cnonce:$qop:$ha2';
      ret['response'] = sha256Hash(token3);
    }
  }

  return ret;
}

class DigestAuth {
  String username;
  String password;

  // must get from first response
  String? _algorithm;
  String? _qop;
  String? _realm;
  String? _nonce;
  String? _opaque;

  int _nc = 0; // request counter

  DigestAuth(this.username, this.password);

  String _computeNonce() {
    final rnd = math.Random.secure();

    final values = List<int>.generate(16, (i) => rnd.nextInt(256));

    return hex.encode(values);
  }

  String getAuthString(String method, Uri url) {
    final cnonce = _computeNonce();
    _nc += 1;
    // if url has query parameters, append query to path
    final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;

    // after the first request we have the nonce, so we can provide credentials
    final authValues = computeResponse(method, path, '', _algorithm, _qop,
        _opaque, _realm!, cnonce, _nonce, _nc, username, password);
    final authValuesString = authValues.entries
        .where((e) => e.value != null)
        .map((e) => [
          e.key, 
          '=', 
          ['algorithm', 'qop', 'nc'].contains(e.key) ? '' : '"', 
          e.value, 
          ['algorithm', 'qop', 'nc'].contains(e.key) ? '' : '"'
        ].join(''))
        .toList()
        .join(', ');
    final authString = 'Digest $authValuesString';
    return authString;
  }

  void initFromAuthenticateHeader(String /*!*/ authInfo) {
    final values = splitAuthenticateHeader(authInfo);
    if (values != null) {
      _algorithm = values['algorithm'] ?? _algorithm;
      _qop = values['qop'] ?? _qop;
      _realm = values['realm'] ?? _realm;
      _nonce = values['nonce'] ?? _nonce;
      _opaque = values['opaque'] ?? _opaque;
      _nc = 0;
    }
  }

  bool isReady() {
    return _nonce != null && (_nc == 0 || _qop != null);
  }
}

AuthenticationScheme? pickSchemeFromAuthenticateHeader(String wwwAuthHeader) {
  final components = wwwAuthHeader
      .split(RegExp(r'[, ]'))
      .where((s) => s.isNotEmpty)
      .map((e) => e.toLowerCase())
      .toList();
  if (components.any((element) => element == HttpConstants.authSchemeDigest)) {
    return AuthenticationScheme.digest;
  }
  if (components.any((element) => element == HttpConstants.authSchemeBasic)) {
    return AuthenticationScheme.basic;
  }
  return null;
}
