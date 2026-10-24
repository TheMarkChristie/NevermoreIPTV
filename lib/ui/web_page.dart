/// The browser: one site full screen in Android's own Chromium WebView, driven with the remote by an on-screen pointer.
/// Mark, 24 Oct 2026: a Chromium browser with a pop-up blocker, opened from the guide's Web category; on-screen
/// pointer; pop-ups and new tabs blocked.
///
/// The arrows move the pointer (faster while held), OK clicks where it points, pushing against the top or bottom edge
/// scrolls (as do channel up / down), Back goes back a page and from the first page to the TV. A click into a text box
/// leaves the keys with the page for typing; Back gives them to the pointer again. Pages cannot open windows by
/// themselves; a link that opens a new tab opens here. The screen stays on while a site is open.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/web.dart';
import 'tv.dart';

class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.name, required this.url});

  final String name;
  final String url;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  static const _native = MethodChannel('nevermore/web');
  static const _screen = MethodChannel('nevermore/screen');

  late final WebViewController _web;
  int _progress = 0;
  String? _error;
  bool _hint = true;
  bool _fullScreen = false;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _web = WebViewController(onPermissionRequest: _permission)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(browserUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _error = null);
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) setState(() => _error = e.description);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
    final android = _web.platform;
    if (android is AndroidWebViewController) {
      unawaited(android.setMediaPlaybackRequiresUserGesture(false));
      unawaited(android.setCustomWidgetCallbacks(onShowCustomWidget: _showFull, onHideCustomWidget: _hideFull));
      // the pop-up blocker: the plug-in lets scripts open windows by themselves (and loads them over the page)
      unawaited(_native.invokeMethod<void>('blockPopups', android.webViewIdentifier).catchError((_) {}));
    }
    unawaited(_screen.invokeMethod<void>('awake', true).catchError((_) {}));
    _hintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    unawaited(_screen.invokeMethod<void>('awake', false).catchError((_) {}));
    super.dispose();
  }

  /// Protected (DRM) video is allowed; the camera and microphone are not.
  Future<void> _permission(WebViewPermissionRequest request) async {
    if (request.types.isNotEmpty &&
        request.types.every((t) => t == AndroidWebViewPermissionResourceType.protectedMediaId)) {
      await request.grant();
    } else {
      await request.deny();
    }
  }

  /// A video gone full screen: shown over the page, with the pointer; Back leaves full screen.
  void _showFull(Widget view, void Function() onHidden) {
    _fullScreen = true;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            body: PointerSurface(onBack: () async => onHidden(), child: view),
          ),
        ),
      ),
    );
  }

  void _hideFull() {
    if (!_fullScreen || !mounted) return;
    _fullScreen = false;
    Navigator.of(context).pop();
  }

  Future<void> _back() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final android = _web.platform;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PointerSurface(
            web: _web,
            onBack: _back,
            child: android is AndroidWebViewController
                ? WebViewWidget.fromPlatformCreationParams(
                    params: AndroidWebViewWidgetCreationParams(controller: android, displayWithHybridComposition: true),
                  )
                : WebViewWidget(controller: _web),
          ),
          if (_progress < 100)
            Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(value: _progress / 100, minHeight: 3)),
          if (_error != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 640),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(12)),
                  child: Text('${widget.name} did not open: $_error', style: text.titleMedium),
                ),
              ),
            ),
          if (_hint)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: tvBackground.withAlpha(225),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('Arrows move the pointer  -  OK clicks  -  Back goes back', style: text.bodyMedium),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A pointer over [child] (a web page or a full-screen video) for the remote: OK is a tap where it points.
class PointerSurface extends StatefulWidget {
  const PointerSurface({super.key, required this.child, required this.onBack, this.web});

  final Widget child;

  /// Back while the pointer has the keys.
  final Future<void> Function() onBack;

  /// Asked whether a click went into a text box.
  final WebViewController? web;

  @override
  State<PointerSurface> createState() => _PointerSurfaceState();
}

class _PointerSurfaceState extends State<PointerSurface> {
  final _keys = FocusNode(debugLabel: 'pointer');
  Offset? _at;
  Size _size = Size.zero;
  double _speed = 0;
  bool _typing = false;
  bool _scrolling = false;

  /// Touches made here, numbered well clear of real ones.
  static int _touch = 900000;

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      _speed = 0;
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent) unawaited(_click());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.pageUp) {
      unawaited(_scroll(1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.pageDown) {
      unawaited(_scroll(-1));
      return KeyEventResult.handled;
    }
    final dir = switch (k) {
      LogicalKeyboardKey.arrowUp => const Offset(0, -1),
      LogicalKeyboardKey.arrowDown => const Offset(0, 1),
      LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight => const Offset(1, 0),
      _ => null,
    };
    if (dir == null) return KeyEventResult.ignored;
    _speed = event is KeyDownEvent ? 14 : min(_speed + 6, 60);
    _move(dir * _speed);
    return KeyEventResult.handled;
  }

  void _move(Offset by) {
    final at = _at;
    if (at == null) return;
    final next = at + by;
    // pushing against the top or bottom: the page scrolls
    if (by.dy < 0 && next.dy < 2) unawaited(_scroll(1));
    if (by.dy > 0 && next.dy > _size.height - 2) unawaited(_scroll(-1));
    setState(() => _at = Offset(next.dx.clamp(0, _size.width - 1), next.dy.clamp(0, _size.height - 1)));
  }

  Offset _global(Offset local) => (context.findRenderObject() as RenderBox?)?.localToGlobal(local) ?? local;

  /// A tap where the pointer is, as a finger would make it (so the page counts it as the viewer's).
  Future<void> _click() async {
    final at = _at;
    if (at == null) return;
    final p = _global(at);
    final id = ++_touch;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: id, position: p, kind: PointerDeviceKind.touch),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: id, position: p, kind: PointerDeviceKind.touch));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    if (await _intoTextBox()) {
      setState(() => _typing = true);
    } else {
      _keys.requestFocus();
    }
  }

  /// A finger drag through the middle of the page: [direction] 1 shows what is above, -1 what is below.
  Future<void> _scroll(int direction) async {
    if (_scrolling || _size == Size.zero) return;
    _scrolling = true;
    final travel = Offset(0, min(360.0, _size.height * 0.4) * direction);
    final from = _global(_size.center(Offset.zero) - travel / 2);
    final id = ++_touch;
    const steps = 8;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: id, position: from, kind: PointerDeviceKind.touch),
    );
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      GestureBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          pointer: id,
          position: from + travel * (i / steps),
          delta: travel / steps.toDouble(),
          kind: PointerDeviceKind.touch,
        ),
      );
    }
    // held still before lifting, so the page does not fling on
    await Future<void>.delayed(const Duration(milliseconds: 80));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: id, position: from + travel, kind: PointerDeviceKind.touch),
    );
    _scrolling = false;
    if (mounted && !_typing) _keys.requestFocus();
  }

  Future<bool> _intoTextBox() async {
    final web = widget.web;
    if (web == null) return false;
    try {
      final r = await web.runJavaScriptReturningResult(
        '(function(){var e=document.activeElement;if(!e)return false;if(e.isContentEditable)return true;'
        'var t=(e.tagName||"").toLowerCase();if(t==="textarea")return true;if(t!=="input")return false;'
        'return ["text","search","email","password","url","tel","number"].indexOf((e.type||"text").toLowerCase())>=0;})()',
      );
      return r == true || '$r' == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _back() async {
    if (_typing) {
      setState(() => _typing = false);
      _keys.requestFocus();
      return;
    }
    await widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, box) {
            _size = box.biggest;
            final at = _at ??= _size.center(Offset.zero);
            return Stack(
              fit: StackFit.expand,
              children: [
                widget.child,
                if (!_typing)
                  Positioned(
                    left: at.dx,
                    top: at.dy,
                    child: const IgnorePointer(
                      child: CustomPaint(size: Size(24, 34), painter: _Arrow()),
                    ),
                  ),
                if (_typing)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: tvBackground.withAlpha(225),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('Typing  -  Back for the pointer'),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The pointer: a white arrow with a dark edge, its tip at the point.
class _Arrow extends CustomPainter {
  const _Arrow();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h * 0.78)
      ..lineTo(w * 0.28, h * 0.6)
      ..lineTo(w * 0.48, h)
      ..lineTo(w * 0.66, h * 0.92)
      ..lineTo(w * 0.47, h * 0.53)
      ..lineTo(w, h * 0.53)
      ..close();
    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_Arrow old) => false;
}
