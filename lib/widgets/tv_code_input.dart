import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// A TV-friendly code input widget that allows D-pad navigation to enter codes
class TVCodeInput extends StatefulWidget {
  final Function(String) onCodeComplete;
  final int codeLength;
  final bool autofocus;

  const TVCodeInput({
    super.key,
    required this.onCodeComplete,
    this.codeLength = 11,
    this.autofocus = false,
  });

  @override
  State<TVCodeInput> createState() => _TVCodeInputState();
}

class _TVCodeInputState extends State<TVCodeInput> {
  final List<String> _code = [];
  int _currentIndex = 0;
  final List<FocusNode> _focusNodes = [];

  // Characters available for code (0-9, A-Z in base-36)
  static const String _chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final List<int> _charIndices = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < widget.codeLength; i++) {
      _code.add('');
      _charIndices.add(0);
      _focusNodes.add(FocusNode());
    }
  }

  @override
  void dispose() {
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _incrementChar() {
    setState(() {
      _charIndices[_currentIndex] =
          (_charIndices[_currentIndex] + 1) % _chars.length;
      _code[_currentIndex] = _chars[_charIndices[_currentIndex]];
    });
  }

  void _decrementChar() {
    setState(() {
      _charIndices[_currentIndex] =
          (_charIndices[_currentIndex] - 1 + _chars.length) % _chars.length;
      _code[_currentIndex] = _chars[_charIndices[_currentIndex]];
    });
  }

  void _moveNext() {
    if (_currentIndex < widget.codeLength - 1) {
      setState(() {
        _currentIndex++;
      });
      _focusNodes[_currentIndex].requestFocus();
    } else {
      // Code complete
      final code = _code.join();
      if (code.length == widget.codeLength) {
        widget.onCodeComplete(code);
      }
    }
  }

  void _movePrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
      _focusNodes[_currentIndex].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Code boxes
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.codeLength, (index) {
            return Focus(
              focusNode: _focusNodes[index],
              autofocus: index == 0 && widget.autofocus,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    if (index == _currentIndex) {
                      _incrementChar();
                      return KeyEventResult.handled;
                    }
                  } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    if (index == _currentIndex) {
                      _decrementChar();
                      return KeyEventResult.handled;
                    }
                  } else if (event.logicalKey ==
                          LogicalKeyboardKey.arrowRight ||
                      event.logicalKey == LogicalKeyboardKey.select) {
                    _moveNext();
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _movePrevious();
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _currentIndex = index;
                  });
                  _focusNodes[index].requestFocus();
                },
                child: Container(
                  width: 24,
                  height: 48,
                  margin: EdgeInsets.only(
                    right: index < widget.codeLength - 1 ? 3 : 0,
                    left: index == 8 ? 6 : 0,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _code[index].isNotEmpty
                            ? const Color(0xFFFFD600).withOpacity(0.1)
                            : Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color:
                          _currentIndex == index
                              ? const Color(0xFFFFD600)
                              : _code[index].isNotEmpty
                              ? const Color(0xFFFFD600).withOpacity(0.3)
                              : Colors.white.withOpacity(0.1),
                      width: _currentIndex == index ? 3 : 1,
                    ),
                    boxShadow:
                        _currentIndex == index
                            ? [
                              BoxShadow(
                                color: const Color(0xFFFFD600).withOpacity(0.4),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ]
                            : null,
                  ),
                  child: Center(
                    child:
                        _code[index].isNotEmpty
                            ? Text(
                              _code[index],
                              style: GoogleFonts.outfit(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                            : _currentIndex == index
                            ? Container(
                              width: 2,
                              height: 20,
                              color: const Color(0xFFFFD600),
                            )
                            : Text(
                              '•',
                              style: GoogleFonts.outfit(
                                color: Colors.grey[700],
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        // Instructions
        Text(
          'Use ↑↓ to change character, →← to move, SELECT to confirm',
          style: GoogleFonts.outfit(color: Colors.grey[500], fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
