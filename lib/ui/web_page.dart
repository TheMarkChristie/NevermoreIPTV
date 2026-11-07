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
/// A held OK opens "From your phone": a page on the phone types into the box the TV's page has the focus on, or
/// fills a site's sign-in form (and keeps that sign-in on the TV, to fill it again next time).
///
/// The page sees Android's WebView as it is: no agent line of its own (web.dart says why: Cloudflare's Turnstile
/// refused every disguise and passed the stock identity).
///
/// Since 0.9.0 a site's behaviour lives in [SiteSession] and its picture in [SiteView], so a box of the four screens
/// (quad_page.dart) can hold a site too, several at once, each in a WebView of its own, the sound following the
/// highlight (Mark, 7 Nov 2026: "Does it also allow me the web streams as well" - yes, multi site).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/library.dart';
import '../core/phone_page.dart';
import '../core/site_logins.dart';
import '../core/web.dart';
import 'phone_page.dart';
import 'tv.dart';

/// What a Back did: went back a page, or it is time to leave (the site, or in a box the pointer).
enum SiteBack { page, leave }

/// One site in a WebView: the controller and the page's behaviour - the pop-up blocker, third-party cookies, mixed
/// content, the last page remembered (web.dart onSite), the kept sign-in filled in as a page loads
/// (site_logins.dart), the full-screen video handed to the view, typing and the sign-in from the phone, the sound
/// muted or not. The browser page and a box of the four screens each own one.
class SiteSession {
  SiteSession({required this.name, required this.site, required this.url});

  final String name;

  /// The site it belongs to (the house file's address), under which its last page is kept.
  final String site;

  /// The page to open first.
  final String url;

  static const _native = MethodChannel('nevermore/web');

  late final WebViewController web;
  final progress = ValueNotifier<int>(0);
  final error = ValueNotifier<String?>(null);
  final note = ValueNotifier<String?>(null);

  /// The keys are the page's (a click went into a text box); set false from outside to give them back.
  final typing = ValueNotifier<bool>(false);

  /// The view's hooks for a video gone full screen.
  void Function(Widget view, void Function() onHidden)? onShowFull;
  VoidCallback? onHideFull;

  /// The page the first Back of a double Back left: that is where the site was left, not the page Back went to.
  String? _beforeBack;

  /// Leaving: a page change the WebView reports after that (the Back it went back on) is not where the site was left.
  bool _leaving = false;
  DateTime? _lastBack;
  bool _muted = false;
  Timer? _muteTimer;
  Timer? _noteTimer;
  bool _started = false;
  bool _gone = false;

  /// Whether [start] has made the WebView.
  bool get started => _started;

  /// The WebView, made once (the view calls it as it appears).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    web = WebViewController(onPermissionRequest: _permission)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => progress.value = p,
          onPageStarted: (_) => error.value = null,
          onPageFinished: (url) => unawaited(_pageDone(url)),
          onUrlChange: (c) {
            error.value = null;
            _remember(c.url);
          },
          // a mailto:, tel: or app link has nowhere to go on a TV, and would only leave an error card on the page
          onNavigationRequest: (r) =>
              r.url.startsWith('http://') || r.url.startsWith('https://') || r.url.startsWith('about:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onWebResourceError: (e) {
            if (e.isForMainFrame == true) error.value = e.description;
          },
        ),
      );
    await _prepareAndLoad();
    _applyMute();
  }

  /// The page is left for good: an empty page takes its place, so its sound stops at once (the Android WebView
  /// outlives its widget until the controller is collected).
  void dispose() {
    _gone = true;
    _muteTimer?.cancel();
    _noteTimer?.cancel();
    if (_started) unawaited(web.loadRequest(Uri.parse('about:blank')).catchError((_) {}));
    progress.dispose();
    error.dispose();
    note.dispose();
    typing.dispose();
  }

  /// The Android settings, then the page: the pop-up blocker must be set before any script of the page can run.
  Future<void> _prepareAndLoad() async {
    final android = web.platform;
    if (android is AndroidWebViewController) {
      await android.setMediaPlaybackRequiresUserGesture(false);
      await android.setCustomWidgetCallbacks(
        onShowCustomWidget: (view, onHidden) => onShowFull?.call(view, onHidden),
        onHideCustomWidget: () => onHideFull?.call(),
      );
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
    if (_gone) return;
    await web.loadRequest(Uri.parse(url));
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

  /// The page the site is left on, kept for the next open: one of its own pages only (web.dart onSite).
  void _remember(String? url) {
    if (_leaving || _gone || url == null || !onSite(site, url)) return;
    unawaited(library.setSitePage(site, url).catchError((_) {}));
  }

  /// A line at the top for a moment ("Sign-in filled in from the TV's memory").
  void say(String what) {
    if (_gone) return;
    _noteTimer?.cancel();
    note.value = what;
    _noteTimer = Timer(const Duration(seconds: 4), () {
      if (!_gone) note.value = null;
    });
  }

  /// The script that fills a sign-in form: the first visible user box and the password box of the form the password
  /// box is in, set the way a page's own code notices (the input's own setter, then input and change events). Answers
  /// 'filled', or 'nopw' when the page has no password box.
  static const _fillJs =
      "(function(u,p){function set(e,v){var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');"
      "if(d&&d.set)d.set.call(e,v);else e.value=v;e.dispatchEvent(new Event('input',{bubbles:true}));"
      "e.dispatchEvent(new Event('change',{bubbles:true}));}"
      "var pw=null,pws=document.querySelectorAll('input[type=password]');"
      "for(var j=0;j<pws.length;j++){if(pws[j].offsetParent!==null){pw=pws[j];break;}}if(!pw)return 'nopw';"
      "var root=pw.form||document,c=root.querySelectorAll('input[type=email],input[type=text],input:not([type])'),user=null;"
      "for(var i=0;i<c.length;i++){if(c[i].offsetParent!==null){user=c[i];break;}}"
      "if(user)set(user,u);set(pw,p);return 'filled';})";

  /// The script that types into the box with the focus; 'typed', or 'none' when no text box has it.
  static const _typeJs =
      "(function(t){var e=document.activeElement;if(!e)return 'none';"
      "if(e.isContentEditable){e.textContent=t;e.dispatchEvent(new Event('input',{bubbles:true}));return 'typed';}"
      "var tag=(e.tagName||'').toUpperCase();if(tag!=='INPUT'&&tag!=='TEXTAREA')return 'none';"
      "var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');if(d&&d.set)d.set.call(e,t);else e.value=t;"
      "e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return 'typed';})";

  /// The script that mutes or unmutes the page's own video and audio, in the page and the frames it can reach (a
  /// player in a frame from another site is out of reach, and stays as it is); how many it found.
  static const _muteJs =
      "(function(m){var n=0;function go(w){try{w.document.querySelectorAll('video,audio').forEach(function(v){"
      "v.muted=m;n++;});for(var i=0;i<w.frames.length;i++)go(w.frames[i]);}catch(e){}}go(window);return n;})";

  Future<String> run(String script, List<Object> args) async {
    if (!_started || _gone) return 'error';
    final call = '$script(${args.map(jsonEncode).join(',')})';
    try {
      return '${await web.runJavaScriptReturningResult(call)}'.replaceAll('"', '');
    } catch (_) {
      return 'error';
    }
  }

  /// Fills the page's sign-in form with [login]; the answer for the phone.
  Future<String> fill(SiteLogin login) async {
    final r = await run(_fillJs, [login.user, login.password]);
    if (r == 'filled') return 'Filled in on the TV: press its sign-in button with the pointer.';
    throw const PhoneRefused('The page on the TV has no sign-in box. Open its sign-in page first, then send again.');
  }

  /// Types [text] into the box with the focus; the answer for the phone.
  Future<String> typeInto(String text) async {
    if (text.isEmpty) throw const PhoneRefused('Nothing to send.');
    if (await run(_typeJs, [text]) != 'typed') {
      throw const PhoneRefused(
        'No text box has the focus on the TV. Click into one with the pointer, then send again.',
      );
    }
    return 'Typed into the box on the TV.';
  }

  /// The page's sound off or on: a box of the four screens without the highlight is quiet. Applied again every few
  /// seconds while muted, as players appear after the page has loaded.
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _applyMute();
    if (_started && !_gone) await run(_muteJs, [muted]);
  }

  void _applyMute() {
    _muteTimer?.cancel();
    if (!_muted || !_started || _gone) return;
    _muteTimer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(run(_muteJs, [true])));
  }

  /// A page just loaded: the mute stands, and a sign-in kept for this site fills its form by itself.
  Future<void> _pageDone(String url) async {
    if (_muted) unawaited(run(_muteJs, [true]));
    final login = await siteLogins.loginFor(url);
    if (login == null || _gone) return;
    if (await run(_fillJs, [login.user, login.password]) == 'filled') say('Sign-in filled in from the TV\'s memory');
  }

  /// Back: a page back when there is one and this is not the second Back within two seconds; else it is time to
  /// leave. Leaving [forGood] (the browser page) remembers the page before the first Back as the one the site was
  /// left on and takes no more page changes; a box's site plays on, and keeps remembering.
  Future<SiteBack> back({bool forGood = true}) async {
    if (!_started || _gone) return SiteBack.leave;
    final now = DateTime.now();
    final again = _lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2);
    _lastBack = now;
    if (!again && await web.canGoBack()) {
      _beforeBack = await web.currentUrl();
      await web.goBack();
      return SiteBack.page;
    }
    if (forGood) {
      if (again && _beforeBack != null) _remember(_beforeBack);
      _leaving = true;
    }
    return SiteBack.leave;
  }
}

/// "From your phone" for [session]: the phone page's typing and sign-in sections in a dialog, open until Close.
Future<void> phoneDialog(BuildContext context, SiteSession session) async {
  final sections = [
    PhoneSection(
      id: 'text',
      title: 'Send text',
      intro: 'What you send goes into the box the TV\'s page has the focus on: click into it with the pointer first.',
      form: '<label for="text-text">Text</label><textarea id="text-text" name="text"></textarea>',
      onPost: (fields) => session.typeInto(fields['text'] ?? ''),
    ),
    PhoneSection(
      id: 'login',
      title: 'Sign in',
      intro:
          'Fills the sign-in form on the TV\'s page; the TV keeps the sign-in for this site and fills it in by '
          'itself next time.',
      form:
          '<label for="login-user">Email or user name</label>'
          '<input id="login-user" type="text" name="user" autocomplete="username">'
          '<label for="login-password">Password</label>'
          '<input id="login-password" type="password" name="password" autocomplete="current-password">'
          '<label class="check"><input type="checkbox" name="remember" checked> Keep on this TV for next time</label>',
      button: 'Fill in on the TV',
      onPost: (fields) async {
        final login = SiteLogin(fields['user'] ?? '', fields['password'] ?? '');
        if (login.user.isEmpty || login.password.isEmpty) throw const PhoneRefused('Both boxes are needed.');
        final answer = await session.fill(login);
        if (fields['remember'] == 'yes') {
          await siteLogins.remember(await session.web.currentUrl() ?? session.site, login);
        }
        return answer;
      },
    ),
  ];
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tvSurface,
      title: const Text('From your phone'),
      content: SizedBox(
        width: 760,
        child: PhoneSheet(
          title: 'From your phone',
          intro: 'Typing and signing in on the TV\'s browser, from here.',
          sections: sections,
        ),
      ),
      actions: [TvButton(label: 'Close', autofocus: true, onPressed: () => Navigator.of(context).pop())],
    ),
  );
}

/// A site's picture with the pointer over it, its progress line, its error card and its notes: the browser page's
/// whole screen, or a box of the four screens. [active]: the keys are this view's. [boxed]: no Back handling of its
/// own (the box's page asks the session), and the box's focus comes when made active.
class SiteView extends StatefulWidget {
  const SiteView({
    super.key,
    required this.session,
    required this.onLeave,
    this.onPageBack,
    this.onHold,
    this.active = true,
    this.boxed = false,
  });

  final SiteSession session;

  /// Back with nothing to go back to (or a second Back within two seconds).
  final VoidCallback onLeave;

  /// Back went back a page (the browser page shows "Back again to leave").
  final VoidCallback? onPageBack;

  /// A held OK: the phone page on the browser page, the box's menu in a box.
  final VoidCallback? onHold;
  final bool active;
  final bool boxed;

  @override
  State<SiteView> createState() => _SiteViewState();
}

class _SiteViewState extends State<SiteView> {
  bool _fullScreen = false;

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  @override
  void didUpdateWidget(SiteView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) _adopt();
  }

  void _adopt() {
    widget.session
      ..onShowFull = _showFull
      ..onHideFull = _hideFull;
    unawaited(
      widget.session
          .start()
          .then((_) {
            if (mounted) setState(() {});
          })
          .catchError((_) {}),
    );
  }

  /// A video gone full screen: shown over everything, with the video keys; Back leaves full screen.
  void _showFull(Widget view, void Function() onHidden) {
    if (!mounted) return;
    _fullScreen = true;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            body: PointerSurface(web: widget.session.web, video: true, onBack: () async => onHidden(), child: view),
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
    final r = await widget.session.back();
    if (!mounted) return;
    if (r == SiteBack.leave) {
      widget.onLeave();
    } else {
      widget.onPageBack?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final margin = overscanOf(context);
    final session = widget.session;
    // the WebView exists once start() has made it (the first frame of a box shows black for that moment)
    final ready = session.started;
    return Stack(
      fit: StackFit.expand,
      children: [
        PointerSurface(
          web: ready ? session.web : null,
          active: widget.active,
          boxed: widget.boxed,
          typing: session.typing,
          onBack: _back,
          onHold: widget.onHold,
          // the plug-in's default way of showing the page (as its full-screen video does): with hybrid composition a
          // real Google TV drew the page over the pointer (24 Oct 2026)
          child: ready ? WebViewWidget(controller: session.web) : const SizedBox.expand(),
        ),
        ValueListenableBuilder<int>(
          valueListenable: session.progress,
          builder: (context, p, _) => p < 100
              ? Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(value: p / 100, minHeight: 3))
              : const SizedBox.shrink(),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: session.error,
          builder: (context, error, _) => error == null
              ? const SizedBox.shrink()
              : Center(
                  child: IgnorePointer(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 640),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(12)),
                      child: Text('${session.name} did not open: $error', style: text.titleMedium),
                    ),
                  ),
                ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: session.note,
          builder: (context, note, _) => note == null
              ? const SizedBox.shrink()
              : Positioned(
                  top: widget.boxed ? 8 : margin.top,
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
                        child: Text(note, style: text.bodyMedium),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

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
  static const _screen = MethodChannel('nevermore/screen');

  late final SiteSession _session = SiteSession(name: widget.name, site: widget.site, url: widget.url);
  bool _hint = true;
  Timer? _hintTimer;
  bool _leaveHint = false;
  Timer? _leaveTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_screen.invokeMethod<void>('awake', {'who': 'web', 'on': true}).catchError((_) {}));
    _hintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _leaveTimer?.cancel();
    _session.dispose();
    unawaited(_screen.invokeMethod<void>('awake', {'who': 'web', 'on': false}).catchError((_) {}));
    super.dispose();
  }

  void _pageBack() {
    _leaveTimer?.cancel();
    if (mounted) setState(() => _leaveHint = true);
    _leaveTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _leaveHint = false);
    });
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
          SiteView(
            session: _session,
            onLeave: () {
              if (mounted) Navigator.of(context).pop();
            },
            onPageBack: _pageBack,
            onHold: () => unawaited(phoneDialog(context, _session)),
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
                          : 'Arrows move the pointer  -  OK clicks  -  hold OK: your phone  -  Back goes back',
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
/// [video], the keys are the video's (play, pause, seek); Up or Down brings the pointer until it hides again. With
/// [active] false (a box of the four screens that is not being browsed) it takes no keys and draws no pointer.
class PointerSurface extends StatefulWidget {
  const PointerSurface({
    super.key,
    required this.child,
    required this.onBack,
    this.web,
    this.video = false,
    this.onHold,
    this.active = true,
    this.boxed = false,
    this.typing,
  });

  final Widget child;

  /// Back while the pointer has the keys.
  final Future<void> Function() onBack;

  /// Asked whether a click went into a text box, and told the video keys.
  final WebViewController? web;

  /// A page's video gone full screen: the video keys first.
  final bool video;

  /// A held OK (the phone page); a short OK clicks where the pointer is.
  final VoidCallback? onHold;

  /// Whether the keys are this surface's.
  final bool active;

  /// In a box of the four screens: Android's Back is the box's page's to route, not this surface's.
  final bool boxed;

  /// Typing mode, shared with the owner (set false from outside to end it).
  final ValueNotifier<bool>? typing;

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

  /// OK is down; its repeats made it a hold (acted on when it comes up: opened during the hold, the remaining
  /// repeats would press the dialog's own button).
  bool _selectHeld = false;
  bool _longDone = false;
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
    widget.typing?.addListener(_typingChanged);
    if (widget.video) {
      _say('OK play / pause  -  Left / Right 10 s  -  Up: the pointer a moment  -  Back: leave', seconds: 6);
    }
    // a full-screen video, or a box being browsed from its first frame: the keys come here
    if (widget.video || (widget.boxed && widget.active)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _keys.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(PointerSurface old) {
    super.didUpdateWidget(old);
    if (old.typing != widget.typing) {
      old.typing?.removeListener(_typingChanged);
      widget.typing?.addListener(_typingChanged);
    }
    // made active (a box of the four screens being browsed again): the keys come here, after the frame in which
    // the Focus widget learns it may take them
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) {
          _keys.requestFocus();
          _wake();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.typing?.removeListener(_typingChanged);
    _idle?.cancel();
    _noteTimer?.cancel();
    _keys.dispose();
    super.dispose();
  }

  /// The owner ended typing (Back went to it): the pointer again.
  void _typingChanged() {
    final t = widget.typing?.value ?? false;
    if (!t && _typing && mounted) {
      setState(() => _typing = false);
      _keys.requestFocus();
    }
  }

  void _setTyping(bool on) {
    setState(() => _typing = on);
    widget.typing?.value = on;
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
    if (!widget.active) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final select =
        k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA;
    if (event is KeyUpEvent) {
      _speed = 0;
      if (select && !_videoKeys && _selectHeld) {
        final held = _longDone;
        _selectHeld = false;
        _longDone = false;
        if (held) {
          widget.onHold?.call();
        } else {
          unawaited(_click());
        }
        return KeyEventResult.handled;
      }
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
    if (select) {
      // the click comes on the way up (a hold opens the phone page instead)
      if (event is KeyDownEvent) {
        _selectHeld = true;
        _longDone = false;
      } else if (event is KeyRepeatEvent && _selectHeld && widget.onHold != null) {
        _longDone = true;
      }
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
    if (!widget.active) return;
    if (await _intoTextBox()) {
      _setTyping(true);
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
    if (mounted && !_typing && widget.active) _keys.requestFocus();
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
      _setTyping(false);
      _keys.requestFocus();
      return;
    }
    await widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final margin = overscanOf(context);
    final body = Focus(
      focusNode: _keys,
      autofocus: widget.active && !widget.boxed,
      canRequestFocus: widget.active,
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
              if (widget.active && !_typing && !_videoKeys)
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
                  top: widget.boxed ? 8 : margin.top,
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
                  top: widget.boxed ? 8 : margin.top,
                  right: widget.boxed ? 8 : margin.right,
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
    );
    if (widget.boxed) return body;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: body,
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
