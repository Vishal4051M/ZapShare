import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class ScreenMirrorKeyboardHandler {
  final Function(String, {String? text}) sendControl;
  final StringBuffer typeBuffer = StringBuffer();
  Timer? typeBufferTimer;
  bool remoteInputEnabled = true;

  ScreenMirrorKeyboardHandler({required this.sendControl});

  KeyEventResult handleKeyEvent(
    KeyEvent event,
    BuildContext context,
    Function(String) showInputStatus,
  ) {
    if (event is! KeyDownEvent || !remoteInputEnabled) {
      return KeyEventResult.ignored;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final char = event.character;
    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    if (isCtrl && key == LogicalKeyboardKey.keyV) {
      flushTypeBuffer();
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        final text = data?.text ?? '';
        if (text.isNotEmpty) {
          sendControl('type', text: text);
          showInputStatus('Pasted: ${summarizeText(text)}');
        }
      });
      return KeyEventResult.handled;
    }

    final keyMap = {
      LogicalKeyboardKey.enter: 'enter',
      LogicalKeyboardKey.numpadEnter: 'enter',
      LogicalKeyboardKey.backspace: 'backspace',
      LogicalKeyboardKey.tab: 'tab',
      LogicalKeyboardKey.delete: 'delete',
      LogicalKeyboardKey.escape: 'escape',
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
    };

    if (keyMap.containsKey(key)) {
      flushTypeBuffer();
      sendControl('key', text: keyMap[key]);
      showInputStatus('Sent: ${keyMap[key]}');
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.space) {
      queueTypedText(' ');
      return KeyEventResult.handled;
    } else if (char != null && char.isNotEmpty && !isCtrl && !isAlt) {
      queueTypedText(char);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void queueTypedText(String text) {
    typeBuffer.write(text);
    typeBufferTimer?.cancel();
    typeBufferTimer = Timer(const Duration(milliseconds: 60), flushTypeBuffer);
  }

  void flushTypeBuffer() {
    if (typeBuffer.isEmpty) return;
    final text = typeBuffer.toString();
    typeBuffer.clear();
    sendControl('type', text: text);
  }

  String summarizeText(String text) {
    final compact = text.replaceAll('\n', ' ').trim();
    return compact.length <= 18 ? compact : '${compact.substring(0, 18)}...';
  }

  void dispose() {
    typeBufferTimer?.cancel();
  }
}
