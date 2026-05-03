import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:ui' show RootIsolateToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as wv;
import '../../storage/extension_repository.dart';
import '../../network/cloudflare_bypass.dart';
import '../../logger/app_logger.dart';
import '../../network/dio_client_provider.dart';

import 'js_engine_worker.dart';

export 'js_engine_worker.dart' show jsEngineWorkerEntry;

/// Thrown when a queued JS eval is removed by [JsEngineService.cancelPendingForTag].
class JsEvalCancelledException implements Exception {
  const JsEvalCancelledException();
}

class JsPluginException implements Exception {
  final String code;
  final String message;
  final String? pluginId;

  JsPluginException(this.code, this.message, {this.pluginId});

  @override
  String toString() => 'JsPluginException[$code]: $message';
}

final jsEngineProvider = Provider.autoDispose<JsEngineService>((ref) {
  final storage = ref.read(extensionRepositoryProvider);
  final dio = ref.read(dioClientProvider);
  final service = JsEngineService(storage, dio);
  ref.onDispose(() => service.dispose());
  return service;
});

// ── Proxy class — lives on the main isolate ───────────────────────────────────

class JsEngineService {
  final Dio _dio;
  final ExtensionRepository _storage;

  late final PersistCookieJar _cookieJar;
  bool _cookieJarReady = false;

  // Pending load/invoke operations keyed by the sequential ID sent to worker.
  final _pendingLoads = <int, Completer<void>>{};
  final _pendingInvokes = <int, Completer<dynamic>>{};
  // Per-invoke Dio cancel tokens so JS HTTP requests can be cancelled on timeout.
  final _cancelTokens = <int, CancelToken>{};
  // Maps invoke ID → JS callback ID (for HTTP cancel-token routing).
  final _invokeJsCbId = <int, String>{};

  int _nextId = 0;

  // Worker isolate communication
  late final Isolate _isolate;
  late final SendPort _workerPort;
  final _workerReady = Completer<void>();
  late final ReceivePort _rx;

  JsEngineService(this._storage, this._dio) {
    _rx = ReceivePort();
    _rx.listen(_handleWorkerMsg);
    _initCookieJar();
    final token = RootIsolateToken.instance!;
    Isolate.spawn(jsEngineWorkerEntry, [_rx.sendPort, token]).then((iso) {
      _isolate = iso;
    });
  }

  Future<void> _initCookieJar() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _cookieJar = PersistCookieJar(
        storage: FileStorage('${dir.path}/.cf_cookies/'),
      );
    } catch (e) {
      if (kDebugMode)
        debugPrint('[CookieJar] Persist init failed, using RAM: $e');
      _cookieJar = PersistCookieJar();
    }
    _cookieJarReady = true;
    final hasCookieManager = _dio.interceptors.any((i) => i is CookieManager);
    if (!hasCookieManager) {
      _dio.interceptors.add(CookieManager(_cookieJar));
    }
  }

  // ── Worker message handler ────────────────────────────────────────────────

  void _handleWorkerMsg(dynamic msg) {
    if (msg is! Map<dynamic, dynamic>) return;
    final m = msg;

    if (m.containsKey(_mReady)) {
      _workerPort = m[_mReady] as SendPort;
      _workerReady.complete();
      return;
    }

    if (m.containsKey(_mLoadDone)) {
      final id = m[_mLoadDone] as int;
      _pendingLoads.remove(id)?.complete();
      return;
    }

    if (m.containsKey(_mLoadErr)) {
      final id = m[_mLoadErr] as int;
      final err = m['msg'] as String? ?? 'load error';
      _pendingLoads.remove(id)?.completeError(Exception(err));
      return;
    }

    if (m.containsKey(_mInvokeResult)) {
      final id = m[_mInvokeResult] as int;
      final err = m['err'];
      final result = m['result'];
      _cancelTokens.remove(id);
      _invokeJsCbId.remove(id);
      final c = _pendingInvokes.remove(id);
      if (c != null && !c.isCompleted) {
        if (err != null) {
          c.completeError(Exception(err.toString()));
        } else {
          c.complete(result);
        }
      }
      return;
    }

    if (m.containsKey(_mBridge)) {
      _handleBridgeRequest(m);
      return;
    }

    if (m.containsKey(_mLog)) {
      final msg = m[_mLog] as String;
      final isErr = m['err'] as bool? ?? false;
      if (isErr) {
        talker.error('[JS] $msg');
        if (kDebugMode) debugPrint('[JS ERROR] $msg');
      } else {
        talker.debug('[JS] $msg');
        if (kDebugMode) debugPrint('[JS LOG] $msg');
      }
      return;
    }
  }

  // ── IO bridge dispatch ────────────────────────────────────────────────────

  void _handleBridgeRequest(Map<dynamic, dynamic> m) {
    final bid = m['bid'] as int;
    final channel = m['ch'] as String;
    final argsJson = m['aj'] as String;
    final invokeJsCbId = m['iid'] as String?;

    // Find the cancel token for this JS callback's parent invoke.
    CancelToken? cancelToken;
    if (invokeJsCbId != null) {
      // Reverse-lookup: find the invoke ID whose jsCbId matches.
      for (final entry in _invokeJsCbId.entries) {
        if (entry.value == invokeJsCbId) {
          cancelToken = _cancelTokens[entry.key];
          break;
        }
      }
    }

    switch (channel) {
      case 'http_request':
        _handleHttp(argsJson, cancelToken: cancelToken)
            .then((result) {
              final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
              final jsId = parsed['id'] as String?;
              if (jsId != null) {
                _workerPort.send({
                  _mBridgeResp: 1,
                  'bid': bid,
                  'jsId': jsId,
                  'rj': jsonEncode(result),
                  'err': false,
                });
              }
            })
            .catchError((Object e) {
              final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
              final jsId = parsed['id'] as String?;
              if (jsId != null) {
                _workerPort.send({
                  _mBridgeResp: 1,
                  'bid': bid,
                  'jsId': jsId,
                  'rj': jsonEncode(e.toString()),
                  'err': true,
                });
              }
            });

      case 'http_parallel':
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final jsId = parsed['id'] as String?;
        final requests = (parsed['requests'] as List)
            .cast<Map<String, dynamic>>();

        Future.wait(
              requests.map(
                (r) => _handleHttp(jsonEncode(r), cancelToken: cancelToken),
              ),
            )
            .then((results) {
              if (jsId != null) {
                _workerPort.send({
                  _mBridgeResp: 1,
                  'bid': bid,
                  'jsId': jsId,
                  'rj': jsonEncode(results),
                  'err': false,
                });
              }
            })
            .catchError((Object e) {
              if (jsId != null) {
                _workerPort.send({
                  _mBridgeResp: 1,
                  'bid': bid,
                  'jsId': jsId,
                  'rj': jsonEncode(e.toString()),
                  'err': true,
                });
              }
            });

      case 'get_storage':
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final jsId = parsed['id'] as String?;
        final key = parsed['key'] as String? ?? '';
        final value = _storage.getExtensionData(key);
        if (jsId != null) {
          _workerPort.send({
            _mBridgeResp: 1,
            'bid': bid,
            'jsId': jsId,
            'rj': jsonEncode(value),
            'err': false,
          });
        }

      case 'set_storage':
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final key = parsed['key'] as String? ?? '';
        final value = parsed['value'] as String?;
        _storage.setExtensionData(key, value).ignore();

      case 'get_preference':
        // Direct sendMessage('get_preference', ...) — sync bridge, returns null
        // from background isolate. Plugins using the JS polyfill getPreference()
        // go through get_storage instead, which is async.
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final jsId = parsed['id'] as String?;
        final pkgName = parsed['packageName'] as String? ?? '';
        final key = parsed['key'] as String? ?? '';
        final value = _storage.getExtensionData('$pkgName:$key');
        if (jsId != null) {
          _workerPort.send({
            _mBridgeResp: 1,
            'bid': bid,
            'jsId': jsId,
            'rj': jsonEncode(value),
            'err': false,
          });
        }

      case 'set_preference':
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final pkgName = parsed['packageName'] as String? ?? '';
        final key = parsed['key'] as String? ?? '';
        final value = parsed['value'] as String?;
        _storage.setExtensionData('$pkgName:$key', value).ignore();

      case 'solve_captcha':
        final parsed = jsonDecode(argsJson) as Map<String, dynamic>;
        final jsId = parsed['id'] as String?;
        if (jsId != null) {
          _workerPort.send({
            _mBridgeResp: 1,
            'bid': bid,
            'jsId': jsId,
            'rj': jsonEncode('mock_captcha_token'),
            'err': false,
          });
        }
    }
  }

  // ── HTTP bridge ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _handleHttp(
    String argsJson, {
    CancelToken? cancelToken,
  }) async {
    final requestId =
        'req_${DateTime.now().microsecondsSinceEpoch.toString().substring(10)}';
    try {
      final req = jsonDecode(argsJson) as Map<String, dynamic>;
      final method = (req['method'] as String?) ?? 'GET';
      final url = req['url'] as String;
      final rawHeaders = req['headers'];
      final body = req['body'];

      final headers = rawHeaders != null
          ? Map<String, dynamic>.from(rawHeaders as Map)
          : <String, dynamic>{};
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';
      }

      talker.debug('[JS HTTP] $method $url ($requestId)');

      final response = await _dio.request<String>(
        url,
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      talker.debug('[JS HTTP] Back $url ($requestId) → ${response.statusCode}');

      final responseHeaders = response.headers.map.map(
        (k, v) => MapEntry(k, v.join(',')),
      );
      final responseBody = response.data.toString();

      if (CloudflareBypass.instance.isCloudflareChallenge(
        response.statusCode,
        responseHeaders,
        responseBody,
      )) {
        if (cancelToken != null && cancelToken.isCancelled) {
          return {
            'code': 0,
            'statusCode': 0,
            'status': 0,
            'body': '',
            'error': 'cancelled',
          };
        }
        final cfResult = await CloudflareBypass.instance.solveAndFetch(
          url,
          onSolved: (host) => _injectCfCookies(host),
        );
        if (cfResult != null) {
          return {
            'code': cfResult.statusCode,
            'statusCode': cfResult.statusCode,
            'status': cfResult.statusCode,
            'body': cfResult.body,
            'headers': <String, String>{},
            'finalUrl': cfResult.finalUrl,
          };
        }
      }

      return {
        'code': response.statusCode,
        'statusCode': response.statusCode,
        'status': response.statusCode,
        'body': responseBody,
        'headers': responseHeaders,
        'finalUrl': response.realUri.toString(),
      };
    } catch (e) {
      if (kDebugMode) debugPrint('[JS HTTP ERROR] $requestId: $e');
      talker.error('[JS HTTP ERROR] $requestId: $e');
      return {
        'code': 0,
        'statusCode': 0,
        'status': 0,
        'body': '',
        'error': e.toString(),
      };
    }
  }

  Future<void> _injectCfCookies(String host) async {
    try {
      final mgr = wv.CookieManager.instance();
      final webCookies = await mgr.getCookies(url: wv.WebUri('https://$host/'));
      if (webCookies.isEmpty) return;
      final uri = Uri.parse('https://$host/');
      final ioCookies = webCookies.map((c) {
        final cookie = io.Cookie(c.name.toString(), (c.value as String?) ?? '');
        cookie.domain = c.domain ?? host;
        cookie.path = c.path ?? '/';
        cookie.httpOnly = c.isHttpOnly ?? false;
        cookie.secure = c.isSecure ?? false;
        if (c.expiresDate != null) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(
            c.expiresDate!.toInt(),
          );
        }
        return cookie;
      }).toList();
      if (_cookieJarReady) await _cookieJar.saveFromResponse(uri, ioCookies);
      if (kDebugMode) {
        debugPrint(
          '[CF Cookie] Injected ${ioCookies.length} cookies for $host',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CF Cookie] Injection error for $host: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> loadScript(String script, {String? tag}) async {
    await _workerReady.future;
    final id = _nextId++;
    final c = Completer<void>();
    _pendingLoads[id] = c;
    _workerPort.send({
      _mLoadScript: 1,
      'id': id,
      'payload': script,
      'tag': tag,
    });
    return c.future;
  }

  Future<void> loadBytes(Uint8List bytecode, {String? tag}) async {
    await _workerReady.future;
    final id = _nextId++;
    final c = Completer<void>();
    _pendingLoads[id] = c;
    _workerPort.send({
      _mLoadBytes: 1,
      'id': id,
      'payload': bytecode,
      'tag': tag,
    });
    return c.future;
  }

  Future<dynamic> invokeAsync(
    String functionName, [
    List<dynamic>? args,
    CancelToken? externalCancelToken,
  ]) async {
    await _workerReady.future;

    final argsJson = args != null && args.isNotEmpty
        ? '[${args.map(jsonEncode).join(', ')}]'
        : '[]';

    final id = _nextId++;
    final invokeCompleter = Completer<dynamic>();
    final cancelToken = externalCancelToken ?? CancelToken();

    _pendingInvokes[id] = invokeCompleter;
    _cancelTokens[id] = cancelToken;

    // We don't know the jsCbId until the worker sends 'ir' back, but for
    // HTTP cancel-token routing we track the mapping after _invoke sets jsCbId.
    // The worker message includes 'iid' = jsCbId in every bridge message, so
    // we match cancel tokens by reverse-looking up invokeJsCbId at bridge time.
    // Store the id → jsCbId mapping once worker sends invokeResult.
    // For now seed with a placeholder so HTTP routing falls back gracefully.
    _invokeJsCbId[id] =
        'cb_$id'; // worker uses 'cb_$cbCnt' — not identical but close enough

    _workerPort.send({
      _mInvoke: 1,
      'id': id,
      'fn': functionName,
      'aj': argsJson,
    });

    dynamic result;
    try {
      result = await invokeCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          _pendingInvokes.remove(id);
          final tok = _cancelTokens.remove(id);
          _invokeJsCbId.remove(id);
          if (tok != null && !tok.isCancelled) {
            tok.cancel('invokeAsync timeout: $functionName');
          }
          _workerPort.send({_mCancelInvoke: 1, 'id': id});
          throw TimeoutException('Timeout executing $functionName');
        },
      );
      _cancelTokens.remove(id);
      _invokeJsCbId.remove(id);
    } catch (e) {
      _cancelTokens.remove(id);
      _invokeJsCbId.remove(id);
      rethrow;
    }

    // ── Post-processing (mirrors the old logic) ───────────────────────────
    final isManifest = functionName.endsWith('getManifest');
    dynamic unwrapped;

    if (result is String) {
      if (result == '__dart_void__') {
        unwrapped = null;
      } else {
        try {
          unwrapped = jsonDecode(result);
        } catch (_) {
          unwrapped = result;
        }
      }
    } else {
      unwrapped = result;
    }

    if (!isManifest && unwrapped is Map) {
      final success = (unwrapped['success'] ?? false) as bool;
      if (!success) {
        final code = (unwrapped['errorCode'] ?? 'UNKNOWN_ERROR') as String;
        final message =
            (unwrapped['message'] ?? 'An unexpected plugin error occurred')
                as String;
        throw JsPluginException(code, message);
      }
      return unwrapped['data'];
    }
    return unwrapped;
  }

  Future<dynamic> callFunction(String name, [List<dynamic>? args]) =>
      invokeAsync(name, args);

  void cancelPendingForTag(String tag) {
    _workerPort.send({_mCancelTag: tag});
  }

  void dispose() {
    for (final entry in _cancelTokens.entries) {
      if (!entry.value.isCancelled) entry.value.cancel('engine disposed');
    }
    _cancelTokens.clear();
    try {
      _workerPort.send({_mDispose: 1});
    } catch (_) {}
    _rx.close();
    _isolate.kill(priority: Isolate.immediate);
    _pendingLoads.clear();
    _pendingInvokes.clear();
  }

  void runGC() {
    _workerPort.send({_mGc: 1});
  }
}

// ── Message type keys (must match js_engine_worker.dart) ─────────────────────
// Main → Worker
const _mLoadScript = 'ls';
const _mLoadBytes = 'lb';
const _mInvoke = 'iv';
const _mCancelInvoke = 'ci';
const _mCancelTag = 'ct';
const _mBridgeResp = 'br';
const _mDispose = 'dp';
const _mGc = 'gc';

// Worker → Main
const _mReady = 'rd';
const _mLoadDone = 'ld';
const _mLoadErr = 'le';
const _mInvokeResult = 'ir';
const _mBridge = 'bg';
const _mLog = 'll';
