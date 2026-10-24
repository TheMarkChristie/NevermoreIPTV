/// The pieces every screen uses: colours, the overscan margin, a button that shows the remote's focus clearly, and text
/// fields that work with a remote (OK opens a page with the TV keyboard; Done on the keyboard finishes).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const tvBackground = Color(0xFF101114);
const tvSurface = Color(0xFF1C1F25);
const tvMuted = Color(0xFFAAB0BA);
const tvAccent = Color(0xFF8A9BB0);
const tvAlert = Color(0xFFE8A0A0);

/// Nothing in the outer 5% of the screen: TVs can crop it (overscan).
const overscan = EdgeInsets.symmetric(horizontal: 48, vertical: 27);

/// The screen's margin: [overscan] on a TV (or anything wider than tall); a phone held upright (Mark, 23 Oct 2026: "it
/// also doesnt auto rotate and fit") has no overscan and no width to spare.
EdgeInsets overscanOf(BuildContext context) => isUpright(context) ? _upright : overscan;

const _upright = EdgeInsets.symmetric(horizontal: 12, vertical: 16);

bool isUpright(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < size.height;
}

class TvButton extends StatelessWidget {
  const TvButton({
    super.key,
    this.label,
    this.child,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.onFocusChange,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final String? label;
  final Widget? child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Picked (the category shown, a kind chosen): outlined in the accent colour.
  final bool selected;
  final ValueChanged<bool>? onFocusChange;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      onFocusChange: onFocusChange,
      style: ButtonStyle(
        alignment: Alignment.centerLeft,
        padding: WidgetStatePropertyAll(padding),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? Colors.black : Colors.white,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? Colors.white
              : selected
              ? tvSurface
              : Colors.transparent,
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.focused)
                ? Colors.white
                : selected
                ? tvAccent
                : Colors.white24,
            width: 2,
          ),
        ),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
      ),
      child: child ?? Text(label ?? ''),
    );
  }
}

/// A labelled value; OK opens [TextEntryPage] to change it.
class FieldRow extends StatelessWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint = '',
    this.obscure = false,
    this.keyboard = TextInputType.text,
    this.autofocus = false,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String hint;
  final bool obscure;
  final TextInputType keyboard;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final shown = value.isEmpty ? hint : (obscure ? '•' * value.length.clamp(4, 12) : value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvButton(
        autofocus: autofocus,
        onPressed: () async {
          final result = await Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) =>
                  TextEntryPage(label: label, initial: value, obscure: obscure, keyboard: keyboard, hint: hint),
            ),
          );
          if (result != null) onChanged(result.trim());
        },
        child: Row(
          children: [
            SizedBox(width: 190, child: Text(label)),
            Expanded(
              child: Builder(
                builder: (context) => Text(
                  shown,
                  overflow: TextOverflow.ellipsis,
                  style: value.isEmpty
                      ? TextStyle(color: DefaultTextStyle.of(context).style.color?.withAlpha(140))
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One text box and the TV keyboard. Done on the keyboard keeps the text; Back leaves it as it was.
class TextEntryPage extends StatefulWidget {
  const TextEntryPage({
    super.key,
    required this.label,
    required this.initial,
    this.obscure = false,
    this.keyboard = TextInputType.text,
    this.hint = '',
  });

  final String label;
  final String initial;
  final bool obscure;
  final TextInputType keyboard;
  final String hint;

  @override
  State<TextEntryPage> createState() => _TextEntryPageState();
}

class _TextEntryPageState extends State<TextEntryPage> {
  late final _controller = TextEditingController(text: widget.initial);
  final _field = FocusNode(debugLabel: 'text entry');

  @override
  void initState() {
    super.initState();
    // a TV can ignore the keyboard asked for while the page is still sliding in (Mark, 24 Oct 2026: "it also doesn't
    // bring up the TV's keyboard"): asked again once the page is up
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sliding = ModalRoute.of(context)?.animation;
      if (sliding == null || sliding.isCompleted) {
        _showKeyboard();
        return;
      }
      void whenUp(AnimationStatus status) {
        if (status != AnimationStatus.completed) return;
        sliding.removeStatusListener(whenUp);
        _showKeyboard();
      }

      sliding.addStatusListener(whenUp);
    });
  }

  void _showKeyboard() {
    if (!mounted) return;
    _field.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  /// OK on the box brings the keyboard back after Back put it away.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.select) return KeyEventResult.ignored;
    _showKeyboard();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _controller.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: tvBackground,
      body: Padding(
        padding: overscanOf(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label, style: text.headlineSmall),
            const SizedBox(height: 16),
            Focus(
              onKeyEvent: _onKey,
              skipTraversal: true,
              child: TextField(
                controller: _controller,
                focusNode: _field,
                autofocus: true,
                obscureText: widget.obscure,
                keyboardType: widget.keyboard,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(hintText: widget.hint, border: const OutlineInputBorder()),
                onSubmitted: (v) => Navigator.of(context).pop(v),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Type with the remote, or with the Google TV app on your phone. Done on the keyboard keeps it; '
              'Back leaves it as it was.',
              style: text.bodySmall?.copyWith(color: tvMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin bar: how far through the programme on now is.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.value, this.color = tvAccent, this.height = 3});

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LinearProgressIndicator(
      value: value.clamp(0.0, 1.0),
      minHeight: height,
      color: color,
      backgroundColor: Colors.white12,
      borderRadius: BorderRadius.circular(height),
    );
  }
}

/// A logo, or the channel's initials when there is none or it does not load.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.url, required this.name, this.size = 40});

  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final words = name.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty).toList();
    final initials = words.take(2).map((w) => w[0].toUpperCase()).join();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(6)),
      child: Text(
        initials,
        style: const TextStyle(color: tvMuted, fontWeight: FontWeight.w600),
      ),
    );
    final u = url;
    if (u == null || u.isEmpty) return fallback;
    return SizedBox(
      width: size,
      height: size,
      child: Image.network(
        u,
        fit: BoxFit.contain,
        cacheWidth: (size * 2).round(),
        errorBuilder: (_, _, _) => fallback,
        headers: const {'User-Agent': 'Mozilla/5.0'},
      ),
    );
  }
}
