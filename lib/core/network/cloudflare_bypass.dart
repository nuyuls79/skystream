import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Cross-platform Cloudflare JS challenge bypass.
class CloudflareBypass {
  CloudflareBypass._();
  static final instance = CloudflareBypass._();

  static const _tag = '[CF Bypass]';
  static const _cfErrorCodes = [403, 503];
  static const _cfServers = ['cloudflare-nginx', 'cloudflare'];
  static const _timeout = Duration(seconds: 60);
  static const _navTimeout = Duration(seconds: 20);
  static const _pollInterval = Duration(milliseconds: 200);

  // ---------------------------------------------------------------------------
  // State Management
  // ---------------------------------------------------------------------------

  /// Active background WebView sessions indexed by normalized host.
  final Map<String, _HostWebView> _hostWebViews = {};

  /// Per-host deduplication: if we're already solving CF for a host,
  /// new callers share the same Future instead of spawning a second WebView.
  final Map<String, Future<CfResult?>> _activeByHost = {};

  /// Limits concurrent WebView spawns to prevent GPU/RAM exhaustion.
  /// Each HeadlessInAppWebView spawn triggers a full Vulkan/GPU context init
  /// on Android — doing two simultaneously causes severe frame drops (40+
  /// skipped frames). Reusing existing cached sessions bypasses this limit.
  static const _maxConcurrentSpawns = 1;
  int _spawningCount = 0;
  final _spawnQueue = <Completer<void>>[];

  Future<void> _acquireSpawnSlot() async {
    if (_spawningCount < _maxConcurrentSpawns) {
      _spawningCount++;
      return;
    }
    final waiter = Completer<void>();
    _spawnQueue.add(waiter);
    await waiter.future;
  }

  void _releaseSpawnSlot() {
    if (_spawnQueue.isNotEmpty) {
      _spawnQueue.removeAt(0).complete();
    } else {
      _spawningCount--;
    }
  }

  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  bool isCloudflareChallenge(
    int? statusCode,
    Map<String, dynamic> headers,
    String body,
  ) {
    if (statusCode == null || !_cfErrorCodes.contains(statusCode)) return false;

    final server = _headerValue(headers, 'server');
    if (server == null ||
        !_cfServers.any((s) => server.toLowerCase().contains(s))) {
      return false;
    }

    return body.contains('Just a moment') ||
        body.contains('cf-mitigated') ||
        body.contains('_cf_chl_opt') ||
        body.contains('challenge-platform');
  }

  // ---------------------------------------------------------------------------
  // Solver
  // ---------------------------------------------------------------------------

  /// Solves the CF challenge and returns the actual page HTML.
  ///
  /// Different hosts solve concurrently. Same-host calls share one in-flight
  /// Future. At most [_maxConcurrentSpawns] WebViews are spawned at once to
  /// avoid GPU/RAM exhaustion; cached sessions are reused for free.
  Future<CfResult?> solveAndFetch(
    String url, {
    Future<void> Function(String host)? onSolved,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final rawHost = uri.host;
    if (rawHost.isEmpty) return null;
    final host = _normalizeHost(rawHost);

    // 1. Deduplicate: share an already-running solve for the same host.
    final inFlight = _activeByHost[host];
    if (inFlight != null) {
      if (kDebugMode) debugPrint('$_tag Joining in-flight solve for $host');
      return inFlight;
    }

    // 2. Try reusing a cached solved session (free — no spawn slot needed).
    final cachedView = _hostWebViews[host];
    if (cachedView != null) {
      if (kDebugMode) debugPrint('$_tag Reusing cached WebView for $host → $url');
      try {
        final html = await cachedView.navigate(url);
        if (html != null &&
            !html.contains('_cf_chl_opt') &&
            !html.contains('Just a moment')) {
          return CfResult(body: html, statusCode: 200, finalUrl: url);
        }
        if (kDebugMode) debugPrint('$_tag Cached session stale for $host, disposing');
        await _disposeHostSession(host);
      } catch (e) {
        if (kDebugMode) debugPrint('$_tag Cached WebView error: $e');
        await _disposeHostSession(host);
      }
    }

    // 3. Fresh solve — register future before any await so concurrent callers
    //    for this host share it rather than spawning duplicate WebViews.
    final future = _freshSolve(url, host, onSolved: onSolved);
    _activeByHost[host] = future;
    try {
      return await future;
    } finally {
      final orphan = _activeByHost.remove(host);
      if (orphan != null) unawaited(orphan);
    }
  }

  /// Acquires a spawn slot, runs a fresh WebView solve, then releases the slot.
  Future<CfResult?> _freshSolve(
    String url,
    String host, {
    Future<void> Function(String host)? onSolved,
  }) async {
    await _acquireSpawnSlot();
    try {
      final result = await _fetchViaWebView(url, host);
      if (result != null && onSolved != null) await onSolved(host);
      return result;
    } finally {
      _releaseSpawnSlot();
    }
  }

  Future<void> _disposeHostSession(String host) async {
    final view = _hostWebViews.remove(host);
    if (view != null) {
      await view.dispose();
    }
  }

  static const _maxCachedWebViews = 2;

  Future<CfResult?> _fetchViaWebView(String url, String host) async {
    if (kDebugMode) debugPrint('$_tag Starting fresh solve for $url');

    // Evict oldest cached WebViews to prevent GPU memory exhaustion.
    while (_hostWebViews.length >= _maxCachedWebViews) {
      final oldest = _hostWebViews.keys.first;
      if (kDebugMode) debugPrint('$_tag Evicting cached WebView for $oldest');
      await _disposeHostSession(oldest);
    }

    final holder = _ViewHolder();
    CfResult? result;
    bool solved = false;
    InAppWebViewController? capturedController;

    Future<void> checkSolved(
      InAppWebViewController controller,
      String? currentUrl,
    ) async {
      if (solved) return;
      try {
        // Cheap check: one tiny JS call, no DOM serialization.
        // Returns '1' when the CF challenge is gone, '0' while it's active.
        final isClear = await controller.evaluateJavascript(source: '''
          (function(){
            var t = document.title || '';
            var hasChallenge =
                t === 'Just a moment...' ||
                t.toLowerCase().indexOf('cloudflare') !== -1 ||
                !!document.getElementById('challenge-form') ||
                !!document.querySelector('[data-translate="checking_browser"]') ||
                !!document.querySelector('.cf-mitigated-content') ||
                typeof window._cf_chl_opt !== 'undefined';
            return hasChallenge ? '0' : '1';
          })()
        ''');

        if (isClear != '1') return;

        // Challenge cleared — fetch full HTML exactly once.
        final html = await controller.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        final body = html?.toString();
        if (body == null || body.isEmpty) return;

        result = CfResult(
          body: body,
          statusCode: 200,
          finalUrl: currentUrl ?? url,
        );
        solved = true;
        holder.hostView?.onLoaded(body);
      } catch (_) {}
    }

    final headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      ),
      onWebViewCreated: (c) => capturedController = c,
      onLoadStop: (c, u) => checkSolved(c, u?.toString()),
      onTitleChanged: (c, t) {
        if (!solved) checkSolved(c, null);
      },
      onProgressChanged: (c, p) {
        if (p == 100) checkSolved(c, null);
      },
      onReceivedError: (c, r, e) {
        final isCancel = e.type == WebResourceErrorType.CANCELLED ||
            e.description.contains('-999') ||
            e.description.toLowerCase().contains('cancel');
        if (isCancel) {
          return;
        }
        holder.hostView?.onLoaded(null);
      },
      // Suppress console messages from cached pages (e.g. cinemacity's
      // content-protector.min.js polls the DOM in a tight setInterval,
      // flooding the platform channel with ~40 calls/sec of serialized
      // "[object Object]" strings).
      onConsoleMessage: (_, _) {},
    );

    try {
      await headless.run();
      final deadline = DateTime.now().add(_timeout);
      while (!solved && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollInterval);
      }

      if (!solved) {
        await headless.dispose();
        return null;
      }

      final hostView = _HostWebView(host, headless, capturedController);
      holder.hostView = hostView;
      _hostWebViews[host] = hostView;
      hostView.startIdleTimer();

      // Silence the cached page's console to prevent scripts like
      // cinemacity's content-protector.min.js from flooding native logcat
      // and the plugin's method-channel debug layer with ~40 calls/sec.
      await hostView.silenceConsole();

      if (kDebugMode) debugPrint('$_tag WebView session ready for $host');
      return result;
    } catch (e) {
      await headless.dispose();
      return null;
    }
  }

  static String _normalizeHost(String host) {
    final h = host.toLowerCase();
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  String? _headerValue(Map<String, dynamic> headers, String key) {
    final value = headers[key] ?? headers[key.toLowerCase()];
    if (value == null) return null;
    if (value is List) return value.isNotEmpty ? value.first.toString() : null;
    return value.toString();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _HostWebView {
  final String host;
  final HeadlessInAppWebView _headless;
  final InAppWebViewController? _controller;

  Completer<String?>? _pending;
  bool _disposed = false;
  Timer? _idleTimer;

  static const _idleTimeout = Duration(seconds: 90);

  _HostWebView(this.host, this._headless, this._controller);

  void startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      if (!_disposed) {
        try {
          dispose();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('${CloudflareBypass._tag} Idle timer dispose error: $e');
          }
        }
      }
    });
  }

  Future<String?> navigate(String url, {int retries = 1}) async {
    if (_disposed || _controller == null) return null;
    startIdleTimer();

    if (_pending != null && !_pending!.isCompleted) {
      await _pending!.future.catchError((_) => null);
    }

    _pending = Completer<String?>();
    try {
      await _controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      final html = await _pending!.future.timeout(CloudflareBypass._navTimeout);

      if (html == null && retries > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return navigate(url, retries: retries - 1);
      }
      // Re-silence console after each navigation (page reload replaces overrides).
      await silenceConsole();
      return html;
    } on TimeoutException {
      if (!(_pending?.isCompleted ?? true)) _pending!.complete(null);
      return null;
    } catch (e) {
      return null;
    }
  }

  void onLoaded(String? html) {
    if (_pending != null && !_pending!.isCompleted) _pending!.complete(html);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    if (_pending != null && !_pending!.isCompleted) {
      if (kDebugMode) {
        debugPrint(
            '${CloudflareBypass._tag} $host: Cancelling active navigation and disposing');
      }
      _pending!.complete(null);
    }
    try {
      if (CloudflareBypass.instance._hostWebViews[host] == this) {
        CloudflareBypass.instance._hostWebViews.remove(host);
      }
      await _headless.dispose();
    } catch (_) {}
  }

  /// Permanently seal all console methods so page scripts (e.g. cinemacity's
  /// content-protector.min.js running in a setInterval) cannot re-enable them
  /// and flood the platform channel with serialized messages.
  ///
  /// Simple assignment (`console.log = noop`) is undone by any script that
  /// re-assigns afterward. `Object.defineProperty` with configurable:false
  /// makes the property non-writable and non-configurable — subsequent writes
  /// silently no-op even inside setInterval callbacks.
  Future<void> silenceConsole() async {
    if (_disposed || _controller == null) return;
    try {
      await _controller.evaluateJavascript(source: '''
        (function() {
          var noop = function(){};
          var methods = ['log','info','debug','warn','error','dir','table',
                         'trace','group','groupCollapsed','groupEnd','clear',
                         'count','assert','time','timeLog','timeEnd','timeStamp'];
          methods.forEach(function(m) {
            try {
              Object.defineProperty(console, m, {
                get: function(){ return noop; },
                set: function(){},
                configurable: false
              });
            } catch(_) {}
          });
        })();
      ''');
    } catch (_) {}
  }
}

class _ViewHolder {
  _HostWebView? hostView;
}

class CfResult {
  final String body;
  final int statusCode;
  final String finalUrl;
  const CfResult({
    required this.body,
    required this.statusCode,
    required this.finalUrl,
  });
}
