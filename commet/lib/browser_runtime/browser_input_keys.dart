import 'package:flutter/services.dart';

import 'browser_runtime.dart';

/// Translates Flutter keyboard events into the W3C `key`/`code` values the
/// BrowserRuntime wire carries, and host cursor names into Flutter cursors.
///
/// The hosts turn `code` into platform key codes (see
/// browser_surface/native/browser_input.h), so it must name the physical key
/// the way KeyboardEvent.code does; `key` is the character typed, or the W3C
/// name of a key that types none.

/// USB HID usages (page 7) for the physical keys that are not letters or
/// digits, keyed to their W3C `code`.
const Map<int, String> _hidUsageCodes = {
  0x00070028: 'Enter',
  0x00070029: 'Escape',
  0x0007002a: 'Backspace',
  0x0007002b: 'Tab',
  0x0007002c: 'Space',
  0x0007002d: 'Minus',
  0x0007002e: 'Equal',
  0x0007002f: 'BracketLeft',
  0x00070030: 'BracketRight',
  0x00070031: 'Backslash',
  0x00070033: 'Semicolon',
  0x00070034: 'Quote',
  0x00070035: 'Backquote',
  0x00070036: 'Comma',
  0x00070037: 'Period',
  0x00070038: 'Slash',
  0x00070039: 'CapsLock',
  0x0007003a: 'F1',
  0x0007003b: 'F2',
  0x0007003c: 'F3',
  0x0007003d: 'F4',
  0x0007003e: 'F5',
  0x0007003f: 'F6',
  0x00070040: 'F7',
  0x00070041: 'F8',
  0x00070042: 'F9',
  0x00070043: 'F10',
  0x00070044: 'F11',
  0x00070045: 'F12',
  0x00070046: 'PrintScreen',
  0x00070047: 'ScrollLock',
  0x00070048: 'Pause',
  0x00070049: 'Insert',
  0x0007004a: 'Home',
  0x0007004b: 'PageUp',
  0x0007004c: 'Delete',
  0x0007004d: 'End',
  0x0007004e: 'PageDown',
  0x0007004f: 'ArrowRight',
  0x00070050: 'ArrowLeft',
  0x00070051: 'ArrowDown',
  0x00070052: 'ArrowUp',
  0x00070053: 'NumLock',
  0x00070054: 'NumpadDivide',
  0x00070055: 'NumpadMultiply',
  0x00070056: 'NumpadSubtract',
  0x00070057: 'NumpadAdd',
  0x00070058: 'NumpadEnter',
  0x00070059: 'Numpad1',
  0x0007005a: 'Numpad2',
  0x0007005b: 'Numpad3',
  0x0007005c: 'Numpad4',
  0x0007005d: 'Numpad5',
  0x0007005e: 'Numpad6',
  0x0007005f: 'Numpad7',
  0x00070060: 'Numpad8',
  0x00070061: 'Numpad9',
  0x00070062: 'Numpad0',
  0x00070063: 'NumpadDecimal',
  0x00070064: 'IntlBackslash',
  0x00070065: 'ContextMenu',
  0x000700e0: 'ControlLeft',
  0x000700e1: 'ShiftLeft',
  0x000700e2: 'AltLeft',
  0x000700e3: 'MetaLeft',
  0x000700e4: 'ControlRight',
  0x000700e5: 'ShiftRight',
  0x000700e6: 'AltRight',
  0x000700e7: 'MetaRight',
};

/// W3C `key` names for keys that type no character.
final Map<LogicalKeyboardKey, String> _namedKeys = {
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
  LogicalKeyboardKey.shiftLeft: 'Shift',
  LogicalKeyboardKey.shiftRight: 'Shift',
  LogicalKeyboardKey.controlLeft: 'Control',
  LogicalKeyboardKey.controlRight: 'Control',
  LogicalKeyboardKey.altLeft: 'Alt',
  LogicalKeyboardKey.altRight: 'Alt',
  LogicalKeyboardKey.metaLeft: 'Meta',
  LogicalKeyboardKey.metaRight: 'Meta',
  LogicalKeyboardKey.capsLock: 'CapsLock',
  LogicalKeyboardKey.numLock: 'NumLock',
  LogicalKeyboardKey.scrollLock: 'ScrollLock',
  LogicalKeyboardKey.contextMenu: 'ContextMenu',
  LogicalKeyboardKey.printScreen: 'PrintScreen',
  LogicalKeyboardKey.pause: 'Pause',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

/// The W3C KeyboardEvent.code for a physical key, or 'Unidentified'.
String w3cCode(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= 0x00070004 && usage <= 0x0007001d) {
    return 'Key${String.fromCharCode(0x41 + usage - 0x00070004)}';
  }
  if (usage >= 0x0007001e && usage <= 0x00070026) {
    return 'Digit${usage - 0x0007001e + 1}';
  }
  if (usage == 0x00070027) return 'Digit0';
  return _hidUsageCodes[usage] ?? 'Unidentified';
}

/// The W3C KeyboardEvent.key for an event: the character it types, or the
/// name of the key.
String w3cKey(KeyEvent event) {
  final named = _namedKeys[event.logicalKey];
  if (named != null) return named;
  final character = event.character;
  if (character != null &&
      character.isNotEmpty &&
      character.runes.every((rune) => rune >= 0x20 && rune != 0x7f)) {
    return character;
  }
  final label = event.logicalKey.keyLabel;
  return label.isEmpty ? 'Unidentified' : label;
}

/// [InputModifiers] bits for the modifier keys held right now.
int currentInputModifiers([HardwareKeyboard? keyboard]) {
  final state = keyboard ?? HardwareKeyboard.instance;
  var modifiers = 0;
  if (state.isShiftPressed) modifiers |= InputModifiers.shift;
  if (state.isControlPressed) modifiers |= InputModifiers.control;
  if (state.isAltPressed) modifiers |= InputModifiers.alt;
  if (state.isMetaPressed) modifiers |= InputModifiers.meta;
  return modifiers;
}

/// Flutter's cursor for a CSS cursor keyword reported by the host.
MouseCursor mouseCursorFor(String? cursor) => switch (cursor) {
      'pointer' => SystemMouseCursors.click,
      'text' => SystemMouseCursors.text,
      'vertical-text' => SystemMouseCursors.verticalText,
      'wait' => SystemMouseCursors.wait,
      'progress' => SystemMouseCursors.progress,
      'crosshair' => SystemMouseCursors.precise,
      'help' => SystemMouseCursors.help,
      'move' => SystemMouseCursors.move,
      'all-scroll' => SystemMouseCursors.allScroll,
      'not-allowed' => SystemMouseCursors.forbidden,
      'no-drop' => SystemMouseCursors.noDrop,
      'grab' => SystemMouseCursors.grab,
      'grabbing' => SystemMouseCursors.grabbing,
      'zoom-in' => SystemMouseCursors.zoomIn,
      'zoom-out' => SystemMouseCursors.zoomOut,
      'context-menu' => SystemMouseCursors.contextMenu,
      'alias' => SystemMouseCursors.alias,
      'copy' => SystemMouseCursors.copy,
      'cell' => SystemMouseCursors.cell,
      'none' => SystemMouseCursors.none,
      'ew-resize' => SystemMouseCursors.resizeLeftRight,
      'ns-resize' => SystemMouseCursors.resizeUpDown,
      'nesw-resize' => SystemMouseCursors.resizeUpRightDownLeft,
      'nwse-resize' => SystemMouseCursors.resizeUpLeftDownRight,
      'col-resize' => SystemMouseCursors.resizeColumn,
      'row-resize' => SystemMouseCursors.resizeRow,
      'n-resize' => SystemMouseCursors.resizeUp,
      's-resize' => SystemMouseCursors.resizeDown,
      'e-resize' => SystemMouseCursors.resizeRight,
      'w-resize' => SystemMouseCursors.resizeLeft,
      'ne-resize' => SystemMouseCursors.resizeUpRight,
      'nw-resize' => SystemMouseCursors.resizeUpLeft,
      'se-resize' => SystemMouseCursors.resizeDownRight,
      'sw-resize' => SystemMouseCursors.resizeDownLeft,
      _ => SystemMouseCursors.basic,
    };
