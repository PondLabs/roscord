import 'package:commet/browser_runtime.dart';
import 'package:commet/browser_runtime/browser_input_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeyDownEvent _down(
  PhysicalKeyboardKey physical,
  LogicalKeyboardKey logical, {
  String? character,
}) =>
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  test('physical keys are named the way KeyboardEvent.code names them', () {
    expect(w3cCode(PhysicalKeyboardKey.keyA), 'KeyA');
    expect(w3cCode(PhysicalKeyboardKey.keyZ), 'KeyZ');
    expect(w3cCode(PhysicalKeyboardKey.digit1), 'Digit1');
    expect(w3cCode(PhysicalKeyboardKey.digit9), 'Digit9');
    expect(w3cCode(PhysicalKeyboardKey.digit0), 'Digit0');
    expect(w3cCode(PhysicalKeyboardKey.space), 'Space');
    expect(w3cCode(PhysicalKeyboardKey.enter), 'Enter');
    expect(w3cCode(PhysicalKeyboardKey.arrowLeft), 'ArrowLeft');
    expect(w3cCode(PhysicalKeyboardKey.numpad5), 'Numpad5');
    expect(w3cCode(PhysicalKeyboardKey.shiftRight), 'ShiftRight');
    expect(w3cCode(PhysicalKeyboardKey.f12), 'F12');
    expect(w3cCode(PhysicalKeyboardKey.fn), 'Unidentified');
  });

  test('key values are the typed character or the name of the key', () {
    expect(
      w3cKey(_down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA,
          character: 'a')),
      'a',
    );
    expect(
      w3cKey(_down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA,
          character: 'A')),
      'A',
    );
    // A key's name wins over the control character it types.
    expect(
      w3cKey(_down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter,
          character: '\r')),
      'Enter',
    );
    expect(
      w3cKey(
          _down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft)),
      'Shift',
    );
    // Ctrl+A types a control character; the page sees the key instead.
    expect(
      w3cKey(_down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA,
          character: '\u0001')),
      'A',
    );
    expect(
      w3cKey(KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.escape,
        logicalKey: LogicalKeyboardKey.escape,
        timeStamp: Duration.zero,
      )),
      'Escape',
    );
  });

  testWidgets('key presses carry the text the keyboard layout typed',
      (tester) async {
    KeyDownEvent press(LogicalKeyboardKey logical, String? character) =>
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyQ,
          logicalKey: logical,
          character: character,
          timeStamp: Duration.zero,
        );
    const linux = TargetPlatform.linux;
    const windows = TargetPlatform.windows;

    expect(
        typedText(press(LogicalKeyboardKey.keyQ, 'q'), platform: linux), 'q');
    expect(typedText(press(LogicalKeyboardKey.enter, '\r'), platform: linux),
        '\r');
    expect(
        typedText(press(LogicalKeyboardKey.tab, '\t'), platform: linux), '\t');
    expect(
      typedText(press(LogicalKeyboardKey.backspace, '\b'), platform: linux),
      isNull,
    );
    expect(
      typedText(
        KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyQ,
          logicalKey: LogicalKeyboardKey.keyQ,
          timeStamp: Duration.zero,
        ),
        platform: linux,
      ),
      isNull,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    // Ctrl+C: Windows types a control character, Linux reports the letter.
    expect(
      typedText(press(LogicalKeyboardKey.keyC, '\u0003'), platform: windows),
      isNull,
    );
    expect(typedText(press(LogicalKeyboardKey.keyC, 'c'), platform: linux),
        isNull);
    expect(typedText(press(LogicalKeyboardKey.enter, '\r'), platform: linux),
        isNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    // AltGr+Q on a German layout: Windows reports Ctrl+Alt and the '@'.
    expect(
        typedText(press(LogicalKeyboardKey.keyQ, '@'), platform: windows), '@');
    // An unmapped Ctrl+Alt combination types nothing on either platform.
    expect(typedText(press(LogicalKeyboardKey.keyQ, null), platform: windows),
        isNull);
    expect(typedText(press(LogicalKeyboardKey.keyQ, 'q'), platform: linux),
        isNull);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('held modifier keys become input modifier bits', (tester) async {
    expect(currentInputModifiers(), 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(currentInputModifiers(), InputModifiers.shift);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(
      currentInputModifiers(),
      InputModifiers.shift | InputModifiers.control,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(currentInputModifiers(), InputModifiers.alt);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(currentInputModifiers(), 0);
  });

  test('page cursors map to Flutter cursors, anything else is the arrow', () {
    expect(mouseCursorFor('pointer'), SystemMouseCursors.click);
    expect(mouseCursorFor('text'), SystemMouseCursors.text);
    expect(mouseCursorFor('grab'), SystemMouseCursors.grab);
    expect(mouseCursorFor('ew-resize'), SystemMouseCursors.resizeLeftRight);
    expect(mouseCursorFor('none'), SystemMouseCursors.none);
    expect(mouseCursorFor('default'), SystemMouseCursors.basic);
    expect(mouseCursorFor('url(evil.png)'), SystemMouseCursors.basic);
    expect(mouseCursorFor(null), SystemMouseCursors.basic);
  });
}
