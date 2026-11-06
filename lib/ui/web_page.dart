/// The browser: one site full screen in Android's own Chromium WebView, driven with the remote by an on-screen pointer.
/// Mark, 24 Oct 2026: a Chromium browser with a pop-up blocker, opened from the guide's Web category; on-screen
/// pointer; pop-ups and new tabs blocked.
///
/// The arrows move the pointer (faster while held), OK clicks where it points, pushing against the top or bottom edge
/// scrolls (as do channel up / down), Back goes back a page, Back twice within two seconds leaves the site (a page
/// that sends the browser straight on again would otherwise trap Back in its history), and from the first page Back
/// returns to the TV. A click into a text box leaves the keys with the page for typing; Back gives them to the pointer
/// again. Pages cannot open windows by themselves; a link that opens a new tab opens here. The screen stays on while a
/// site is open. A site reopens at the page it was left on (one of its own pages; a held OK in the guide opens it
/// from the start). While a page's video is full screen the keys are the video's: OK plays and pauses, Left and
/// Right go 10 s back and forward (held: 30 s a step), Up or Down brings the pointer for the player's own buttons
/// for a moment (it hides after 3 s and the keys are the video's again), Back leaves full screen (Mark, 6 Nov 2026).
///
/// The page sees Android's WebView as it is: no agent line of its own (web.dart says why: Cloudflare's Turnstile
/// refused every disguise and passed the stock identity).
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/library.dart';
import '../core/web.dart';
import 'tv.dart';

class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.name, required this.url, String? site}) : site = site ?? url;

  final String name;

  /// The page to open.
  final String url;

  /// The site it belongs to (the house file's address), under which its last page is kept.
  final String site;

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
  DateTime? _lastBack;

  /// The page the first Back of a double Back left: that is where the site was left, not the page Back went to.
  String? _beforeBack;
  bool _leaveHint = false;
  Timer? _leaveTimer;

  @override
  void initState() {
    super.initState();
    _web = WebViewController(onPermissionRequest: _permission)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _error = null);
          },
          onUrlChange: (c) {
            if (mounted && _error != null) setState(() => _error = null);
            _remember(c.url);
          },
          // a mailto:, tel: or app link has nowhere to go on a TV, and would only leave an error card on the page
          onNavigationRequest: (r) =>
              r.url.startsWith('http://') || r.url.startsWith('https://') || r.url.startsWith('about:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) setState(() => _error = e.description);
          },
        ),
      );
    unawaited(_prepareAndLoad());
    unawaited(_screen.invokeMethod<void>('awake', {'who': 'web', 'on': true}).catchError((_) {}));
    _hintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  /// The Android settings, then the page: the pop-up blocker must be set before any script of the page can run.
  Future<void> _prepareAndLoad() async {
    final android = _web.platform;
    if (android is AndroidWebViewController) {
      await android.setMediaPlaybackRequiresUserGesture(false);
      await android.setCustomWidgetCallbacks(onShowCustomWidget: _showFull, onHideCustomWidget: _hideFull);
      // club sites keep the sign-in in a cookie and play from another domain's frame, which must see that cookie
      final cookies = WebViewCookieManager().platform;
      if (cookies is AndroidWebViewCookieManager) await cookies.setAcceptThirdPartyCookies(android, true);
      // a plain-http stream on an https page
      await android.setMixedContentMode(MixedContentMode.compatibilityMode);
      // the pop-up blocker: the plug-in lets scripts open windows by themselves (and loads them over the page)
      try {
        final blocked = await _native.invokeMethod<bool>('blockPopups', android.webViewIdentifier);
        if (blocked != true) debugPrint('browser: the pop-up blocker was not set');
      } catch (err) {
        debugPrint('browser: the pop-up blocker was not set: $err');
      }
    }
    await _web.loadRequest(Uri.parse(widget.url));
  }

  /// The page the site is left on, kept for the next open: one of its own pages only (web.dart onSite).
  void _remember(String? url) {
    if (url == null || !onSite(widget.site, url)) return;
    unawaited(library.setSitePage(widget.site, url).catchError((_) {}));
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _leaveTimer?.cancel();
    unawaited(_screen.invokeMethod<void>('awake', {'who': 'web', 'on': false}).catchError((_) {}));
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
            body: PointerSurface(web: _web, video: true, onBack: () async => onHidden(), child: view),
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
    final now = DateTime.now();
    final again = _lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2);
    _lastBack = now;
    if (!again && await _web.canGoBack()) {
      _beforeBack = await _web.currentUrl();
      await _web.goBack();
      _leaveTimer?.cancel();
      if (mounted) setState(() => _leaveHint = true);
      _leaveTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _leaveHint = false);
      });
      return;
    }
    if (again && _beforeBack != null) _remember(_beforeBack);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final margin = overscanOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PointerSurface(
            web: _web,
            onBack: _back,
            // the plug-in's default way of showing the page (as its full-screen video does): with hybrid composition a
            // real Google TV drew the page over the pointer (24 Oct 2026)
            child: WebViewWidget(controller: _web),
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
          if (_hint || _leaveHint)
            Positioned(
              left: 0,
              right: 0,
              bottom: margin.bottom,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: tvBackground.withAlpha(225),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _leaveHint
                          ? 'Back again to leave ${widget.name}'
                          : 'Arrows move the pointer  -  OK clicks  -  Back goes back',
                      style: text.bodyMedium,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A pointer over [child] (a web page or a full-screen video) for the remote: OK is a tap where it points. With
/// [video], the keys are the video's (play, pause, seek); Up or Down brings the pointer until it hides again.
class PointerSurface extends StatefulWidget {
  const PointerSurface({super.key, required this.child, required this.onBack, this.web, this.video = false});

  final Widget child;

  /// Back while the pointer has the keys.
  final Future<void> Function() onBack;

  /// Asked whether a click went into a text box, and told the video keys.
  final WebViewController? web;

  /// A page's video gone full screen: the video keys first.
  final bool video;

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

  /// The keys are the video's (OK, Left, Right), not the pointer's.
  bool _videoKeys = false;
  String? _note;
  Timer? _noteTimer;

  /// The pointer hides after a few seconds without a key, as a mouse pointer does over a video (Mark, 24 Oct 2026:
  /// "when you play the video full screen it stays"); the next arrow shows it where it was.
  bool _shown = true;
  Timer? _idle;
  static const _hideAfter = Duration(seconds: 3);

  /// Touches made here, numbered well clear of real ones, and timed from one clock (a page reads the times of a
  /// gesture: a tap from a long press, a fling from a held drag).
  static int _touch = 900000;
  static final _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _idle = Timer(_hideAfter, _hide);
    _videoKeys = widget.video;
    if (widget.video) {
      _say('OK play / pause  -  Left / Right 10 s  -  Up: the pointer a moment  -  Back: leave', seconds: 6);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _keys.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    _noteTimer?.cancel();
    _keys.dispose();
    super.dispose();
  }

  /// The pointer hides; over a full-screen video the keys are the video's again (Back there reaches the video's own
  /// view as well, which leaves full screen on it, so the pointer cannot be left with Back).
  void _hide() {
    if (!mounted) return;
    setState(() {
      _shown = false;
      if (widget.video && !_videoKeys) {
        _videoKeys = true;
        _say('The video keys');
      }
    });
  }

  /// A key used: the pointer stays (or comes back) for a few seconds more. False when it was hidden.
  bool _wake() {
    _idle?.cancel();
    _idle = Timer(_hideAfter, _hide);
    if (_shown) return true;
    setState(() => _shown = true);
    return false;
  }

  /// A word at the top for a moment ("Paused", "10 s back").
  void _say(String what, {int seconds = 2}) {
    _noteTimer?.cancel();
    _note = what;
    if (mounted) setState(() {});
    _noteTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _note = null);
    });
  }

  /// The page's full-screen video element (the one inside document.fullscreenElement), told to play, pause or seek.
  static const _videoJs =
      "(function(c,d){var e=document.fullscreenElement||document.webkitFullscreenElement||document.body;"
      "var v=e.tagName==='VIDEO'?e:e.querySelector('video');if(!v)return 'none';"
      "if(c==='toggle'){if(v.paused){v.play();return 'playing';}v.pause();return 'paused';}"
      "var s=v.seekable,end=s&&s.length?s.end(s.length-1):v.duration;var t=v.currentTime+d;if(t<0)t=0;"
      "if(isFinite(end)&&t>end)t=end;v.currentTime=t;return 'seek';})";

  /// [cmd] 'toggle' or 'seek' by [seconds]. A page whose player has no video element the page can reach (one in a
  /// frame of its own) gets the pointer instead, as before.
  Future<void> _video(String cmd, [int seconds = 0]) async {
    final web = widget.web;
    if (web == null) return;
    String r;
    try {
      r = '${await web.runJavaScriptReturningResult("$_videoJs('$cmd',$seconds)")}'.replaceAll('"', '');
    } catch (_) {
      r = 'none';
    }
    if (!mounted) return;
    _keys.requestFocus();
    switch (r) {
      case 'playing':
        _say('Playing');
      case 'paused':
        _say('Paused');
      case 'seek':
        _say(seconds < 0 ? '${-seconds} s back' : '$seconds s forward');
      default:
        setState(() => _videoKeys = false);
        _wake();
        _say('This player has its own buttons: the pointer');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final k = event.logicalKey;
    if (event is KeyUpEvent) {
      _speed = 0;
      return KeyEventResult.ignored;
    }
    if (_videoKeys) {
      if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA) {
        if (event is KeyDownEvent) unawaited(_video('toggle'));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        final step = event is KeyRepeatEvent ? 30 : 10;
        unawaited(_video('seek', k == LogicalKeyboardKey.arrowLeft ? -step : step));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        setState(() => _videoKeys = false);
        _wake();
        _say('The pointer, for the buttons of the player');
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final dir = switch (k) {
      LogicalKeyboardKey.arrowUp => const Offset(0, -1),
      LogicalKeyboardKey.arrowDown => const Offset(0, 1),
      LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight => const Offset(1, 0),
      _ => null,
    };
    // the first arrow while hidden only shows the pointer where it is
    if (!_wake() && dir != null) return KeyEventResult.handled;
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

  Duration get _now => _clock.elapsed;

  /// A tap where the pointer is, as a finger would make it (so the page counts it as the viewer's). Not during a
  /// scroll: a second finger down would be a pinch.
  Future<void> _click() async {
    final at = _at;
    if (at == null || _scrolling) return;
    final p = _global(at);
    final id = ++_touch;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(timeStamp: _now, pointer: id, position: p, kind: PointerDeviceKind.touch),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(timeStamp: _now, pointer: id, position: p, kind: PointerDeviceKind.touch),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // the click may have sent a video full screen: that page has the keys now, not this one
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
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
      PointerDownEvent(timeStamp: _now, pointer: id, position: from, kind: PointerDeviceKind.touch),
    );
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      GestureBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          timeStamp: _now,
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
      PointerUpEvent(timeStamp: _now, pointer: id, position: from + travel, kind: PointerDeviceKind.touch),
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
    final margin = overscanOf(context);
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
                // a full-screen video's own view takes Android's focus as it appears, and the keys with it; Flutter
                // only tells it to let go when the focus moves on from its node, so it is let in and sent away
                // (the page's view is handled the same way after each click). Touches need no focus
                if (widget.video)
                  Focus(
                    skipTraversal: true,
                    descendantsAreTraversable: false,
                    onFocusChange: (has) {
                      if (has && _videoKeys) _keys.requestFocus();
                    },
                    child: widget.child,
                  )
                else
                  widget.child,
                if (!_typing && !_videoKeys)
                  Positioned(
                    left: at.dx,
                    top: at.dy,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _shown ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: const CustomPaint(size: Size(24, 34), painter: _Arrow()),
                      ),
                    ),
                  ),
                if (_note != null)
                  Positioned(
                    top: margin.top,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            color: tvBackground.withAlpha(225),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(_note!),
                        ),
                      ),
                    ),
                  ),
                if (_typing)
                  Positioned(
                    top: margin.top,
                    right: margin.right,
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
