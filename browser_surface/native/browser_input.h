// Input translation shared by the CEF hosts.
//
// The BrowserRuntime wire carries pointer input in Flutter's vocabulary
// (logical pixels, a button bitmask) and keyboard input as W3C
// KeyboardEvent `key`/`code` strings with a small modifier bitmask.  CEF's
// off-screen input API wants Windows virtual-key codes, a platform native key
// code (an XKB keycode on Linux, a scan code on Windows) and CEF event flags.
// This header does that mapping without including CEF, so the constants below
// mirror cef_event_flags_t / cef_mouse_button_type_t and the hosts
// static_assert that they still match.

#ifndef BROWSER_SURFACE_NATIVE_BROWSER_INPUT_H_
#define BROWSER_SURFACE_NATIVE_BROWSER_INPUT_H_

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

namespace browser_surface {

// Wire modifier bits (InputEvent.keyboard / pointer `modifiers`).
inline constexpr uint32_t kWireModifierShift = 1u << 0;
inline constexpr uint32_t kWireModifierControl = 1u << 1;
inline constexpr uint32_t kWireModifierAlt = 1u << 2;
inline constexpr uint32_t kWireModifierMeta = 1u << 3;

// Wire pointer buttons (Flutter's kPrimaryButton etc.).
inline constexpr uint32_t kWireButtonPrimary = 1u << 0;
inline constexpr uint32_t kWireButtonSecondary = 1u << 1;
inline constexpr uint32_t kWireButtonMiddle = 1u << 2;

// cef_event_flags_t values.
inline constexpr uint32_t kCefFlagShift = 1u << 1;
inline constexpr uint32_t kCefFlagControl = 1u << 2;
inline constexpr uint32_t kCefFlagAlt = 1u << 3;
inline constexpr uint32_t kCefFlagLeftMouse = 1u << 4;
inline constexpr uint32_t kCefFlagMiddleMouse = 1u << 5;
inline constexpr uint32_t kCefFlagRightMouse = 1u << 6;
inline constexpr uint32_t kCefFlagCommand = 1u << 7;
inline constexpr uint32_t kCefFlagIsKeyPad = 1u << 9;
inline constexpr uint32_t kCefFlagIsLeft = 1u << 10;
inline constexpr uint32_t kCefFlagIsRight = 1u << 11;

// cef_mouse_button_type_t values.
inline constexpr int kCefMouseLeft = 0;
inline constexpr int kCefMouseMiddle = 1;
inline constexpr int kCefMouseRight = 2;

inline uint32_t CefFlagsFor(uint32_t wire_modifiers, uint32_t wire_buttons) {
  uint32_t flags = 0;
  if (wire_modifiers & kWireModifierShift) flags |= kCefFlagShift;
  if (wire_modifiers & kWireModifierControl) flags |= kCefFlagControl;
  if (wire_modifiers & kWireModifierAlt) flags |= kCefFlagAlt;
  if (wire_modifiers & kWireModifierMeta) flags |= kCefFlagCommand;
  if (wire_buttons & kWireButtonPrimary) flags |= kCefFlagLeftMouse;
  if (wire_buttons & kWireButtonSecondary) flags |= kCefFlagRightMouse;
  if (wire_buttons & kWireButtonMiddle) flags |= kCefFlagMiddleMouse;
  return flags;
}

// The CEF button for a down/up event.  `buttons` is the button that changed;
// anything unrecognised is the primary button.
inline int CefMouseButtonFor(uint32_t wire_buttons) {
  if (wire_buttons & kWireButtonSecondary) return kCefMouseRight;
  if (wire_buttons & kWireButtonMiddle) return kCefMouseMiddle;
  return kCefMouseLeft;
}

struct KeyCodes {
  // Windows virtual-key code (CefKeyEvent::windows_key_code).
  int windows_key_code;
  // Linux evdev scan code.  XKB keycode = evdev + 8.
  int evdev;
  // Windows set-1 scan code; 0xE0xx marks an extended key.
  int windows_scan;
  // EVENTFLAG_IS_LEFT / IS_RIGHT / IS_KEY_PAD for this physical key.
  uint32_t location_flags;
};

struct KeyCodeEntry {
  const char* code;
  KeyCodes codes;
};

// W3C `code` values for the keys a page can reasonably need.  Letters and
// digits are handled programmatically below.
inline constexpr KeyCodeEntry kKeyCodeTable[] = {
    {"Enter", {0x0D, 28, 0x1C, 0}},
    {"Escape", {0x1B, 1, 0x01, 0}},
    {"Backspace", {0x08, 14, 0x0E, 0}},
    {"Tab", {0x09, 15, 0x0F, 0}},
    {"Space", {0x20, 57, 0x39, 0}},
    {"Minus", {0xBD, 12, 0x0C, 0}},
    {"Equal", {0xBB, 13, 0x0D, 0}},
    {"BracketLeft", {0xDB, 26, 0x1A, 0}},
    {"BracketRight", {0xDD, 27, 0x1B, 0}},
    {"Backslash", {0xDC, 43, 0x2B, 0}},
    {"Semicolon", {0xBA, 39, 0x27, 0}},
    {"Quote", {0xDE, 40, 0x28, 0}},
    {"Backquote", {0xC0, 41, 0x29, 0}},
    {"Comma", {0xBC, 51, 0x33, 0}},
    {"Period", {0xBE, 52, 0x34, 0}},
    {"Slash", {0xBF, 53, 0x35, 0}},
    {"IntlBackslash", {0xE2, 86, 0x56, 0}},
    {"CapsLock", {0x14, 58, 0x3A, 0}},
    {"F1", {0x70, 59, 0x3B, 0}},
    {"F2", {0x71, 60, 0x3C, 0}},
    {"F3", {0x72, 61, 0x3D, 0}},
    {"F4", {0x73, 62, 0x3E, 0}},
    {"F5", {0x74, 63, 0x3F, 0}},
    {"F6", {0x75, 64, 0x40, 0}},
    {"F7", {0x76, 65, 0x41, 0}},
    {"F8", {0x77, 66, 0x42, 0}},
    {"F9", {0x78, 67, 0x43, 0}},
    {"F10", {0x79, 68, 0x44, 0}},
    {"F11", {0x7A, 87, 0x57, 0}},
    {"F12", {0x7B, 88, 0x58, 0}},
    {"ShiftLeft", {0x10, 42, 0x2A, kCefFlagIsLeft}},
    {"ShiftRight", {0x10, 54, 0x36, kCefFlagIsRight}},
    {"ControlLeft", {0x11, 29, 0x1D, kCefFlagIsLeft}},
    {"ControlRight", {0x11, 97, 0xE01D, kCefFlagIsRight}},
    {"AltLeft", {0x12, 56, 0x38, kCefFlagIsLeft}},
    {"AltRight", {0x12, 100, 0xE038, kCefFlagIsRight}},
    {"MetaLeft", {0x5B, 125, 0xE05B, kCefFlagIsLeft}},
    {"MetaRight", {0x5C, 126, 0xE05C, kCefFlagIsRight}},
    {"ContextMenu", {0x5D, 127, 0xE05D, 0}},
    {"ArrowUp", {0x26, 103, 0xE048, 0}},
    {"ArrowDown", {0x28, 108, 0xE050, 0}},
    {"ArrowLeft", {0x25, 105, 0xE04B, 0}},
    {"ArrowRight", {0x27, 106, 0xE04D, 0}},
    {"Home", {0x24, 102, 0xE047, 0}},
    {"End", {0x23, 107, 0xE04F, 0}},
    {"PageUp", {0x21, 104, 0xE049, 0}},
    {"PageDown", {0x22, 109, 0xE051, 0}},
    {"Insert", {0x2D, 110, 0xE052, 0}},
    {"Delete", {0x2E, 111, 0xE053, 0}},
    {"PrintScreen", {0x2C, 99, 0xE037, 0}},
    {"ScrollLock", {0x91, 70, 0x46, 0}},
    {"Pause", {0x13, 119, 0x45, 0}},
    // Windows reports NumLock as the extended 0x45 and Pause as the plain one.
    {"NumLock", {0x90, 69, 0xE045, kCefFlagIsKeyPad}},
    {"NumpadEnter", {0x0D, 96, 0xE01C, kCefFlagIsKeyPad}},
    {"NumpadDivide", {0x6F, 98, 0xE035, kCefFlagIsKeyPad}},
    {"NumpadMultiply", {0x6A, 55, 0x37, kCefFlagIsKeyPad}},
    {"NumpadSubtract", {0x6D, 74, 0x4A, kCefFlagIsKeyPad}},
    {"NumpadAdd", {0x6B, 78, 0x4E, kCefFlagIsKeyPad}},
    {"NumpadDecimal", {0x6E, 83, 0x53, kCefFlagIsKeyPad}},
    {"Numpad0", {0x60, 82, 0x52, kCefFlagIsKeyPad}},
    {"Numpad1", {0x61, 79, 0x4F, kCefFlagIsKeyPad}},
    {"Numpad2", {0x62, 80, 0x50, kCefFlagIsKeyPad}},
    {"Numpad3", {0x63, 81, 0x51, kCefFlagIsKeyPad}},
    {"Numpad4", {0x64, 75, 0x4B, kCefFlagIsKeyPad}},
    {"Numpad5", {0x65, 76, 0x4C, kCefFlagIsKeyPad}},
    {"Numpad6", {0x66, 77, 0x4D, kCefFlagIsKeyPad}},
    {"Numpad7", {0x67, 71, 0x47, kCefFlagIsKeyPad}},
    {"Numpad8", {0x68, 72, 0x48, kCefFlagIsKeyPad}},
    {"Numpad9", {0x69, 73, 0x49, kCefFlagIsKeyPad}},
};

// evdev scan codes for KeyA..KeyZ and Digit0..Digit9 (set-1 layout, which
// Windows scan codes share for these keys).
inline constexpr int kLetterEvdev[26] = {30, 48, 46, 32, 18, 33, 34, 35, 23,
                                         36, 37, 38, 50, 49, 24, 25, 16, 19,
                                         31, 20, 22, 47, 17, 45, 21, 44};
inline constexpr int kDigitEvdev[10] = {11, 2, 3, 4, 5, 6, 7, 8, 9, 10};

// Looks up a W3C `code`.  Returns false for codes this table does not know;
// callers then fall back to the `key` value.
inline bool KeyCodesForCode(std::string_view code, KeyCodes* out) {
  if (code.size() == 4 && code.substr(0, 3) == "Key" && code[3] >= 'A' &&
      code[3] <= 'Z') {
    const int evdev = kLetterEvdev[code[3] - 'A'];
    *out = {code[3], evdev, evdev, 0};
    return true;
  }
  if (code.size() == 6 && code.substr(0, 5) == "Digit" && code[5] >= '0' &&
      code[5] <= '9') {
    const int evdev = kDigitEvdev[code[5] - '0'];
    *out = {code[5], evdev, evdev, 0};
    return true;
  }
  for (const auto& entry : kKeyCodeTable) {
    if (code == entry.code) {
      *out = entry.codes;
      return true;
    }
  }
  return false;
}

// Virtual-key code for a `key` value when the physical `code` is unknown
// (for example a key only reachable through a layout).  Returns 0 when there
// is no sensible code; the character still travels in the CHAR event.
inline int WindowsKeyCodeForKey(std::string_view key) {
  if (key.size() == 1) {
    const char c = key[0];
    if (c >= 'a' && c <= 'z') return c - 'a' + 'A';
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return c;
    if (c == ' ') return 0x20;
    return 0;
  }
  KeyCodes codes;
  // Named keys share their spelling with the code of the unshifted key for
  // everything in the table that has no layout meaning (Enter, Tab, arrows).
  if (KeyCodesForCode(key, &codes)) return codes.windows_key_code;
  return 0;
}

// The UTF-16 units of the text a key press typed, each sent as a CHAR event.
// The app sends what the platform's keyboard layout produced (so AltGr, which
// Windows reports as Ctrl+Alt, still types, and Ctrl shortcuts do not).
// Control characters other than Enter's \r and Tab's \t type nothing, and
// malformed UTF-8 types nothing at all.
inline std::u16string TypedUnits(std::string_view text) {
  static constexpr uint32_t kShortest[] = {0, 0, 0x80, 0x800, 0x10000};
  std::u16string units;
  const auto* bytes = reinterpret_cast<const unsigned char*>(text.data());
  size_t index = 0;
  while (index < text.size()) {
    const unsigned char lead = bytes[index];
    uint32_t code_point = 0;
    size_t length = 0;
    if (lead < 0x80) {
      code_point = lead;
      length = 1;
    } else if ((lead & 0xE0) == 0xC0) {
      code_point = lead & 0x1Fu;
      length = 2;
    } else if ((lead & 0xF0) == 0xE0) {
      code_point = lead & 0x0Fu;
      length = 3;
    } else if ((lead & 0xF8) == 0xF0) {
      code_point = lead & 0x07u;
      length = 4;
    } else {
      return {};
    }
    if (length > text.size() - index) return {};
    for (size_t offset = 1; offset < length; ++offset) {
      const unsigned char next = bytes[index + offset];
      if ((next & 0xC0) != 0x80) return {};
      code_point = (code_point << 6) | (next & 0x3Fu);
    }
    index += length;
    if (code_point < kShortest[length] || code_point > 0x10FFFF ||
        (code_point >= 0xD800 && code_point <= 0xDFFF) || code_point == 0x7F ||
        (code_point < 0x20 && code_point != u'\r' && code_point != u'\t')) {
      return {};
    }
    if (code_point >= 0x10000) {
      code_point -= 0x10000;
      units.push_back(static_cast<char16_t>(0xD800 + (code_point >> 10)));
      units.push_back(static_cast<char16_t>(0xDC00 + (code_point & 0x3FF)));
    } else {
      units.push_back(static_cast<char16_t>(code_point));
    }
  }
  return units;
}

}  // namespace browser_surface

#endif  // BROWSER_SURFACE_NATIVE_BROWSER_INPUT_H_
