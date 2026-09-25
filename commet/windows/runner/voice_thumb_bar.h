#ifndef RUNNER_VOICE_THUMB_BAR_H_
#define RUNNER_VOICE_THUMB_BAR_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>

#include <array>
#include <memory>
#include <optional>
#include <string>

// The call controls under the window's taskbar thumbnail (mute, deafen,
// disconnect), as Discord has them (issue #146).
//
// Dart decides what the buttons show and draws their icons
// (lib/utils/voice_controls/taskbar_thumbnail.dart); this puts them on the
// taskbar, reports clicks, and tells Dart when the taskbar's look changes:
// Windows mode (not app mode), a contrast theme, or the DPI.
//
// The taskbar takes its buttons once per taskbar button and can only hide
// them afterwards, so the same three are added every time a button is
// created (first show, show after hide, Explorer restart) and then updated.
class VoiceThumbBar {
 public:
  VoiceThumbBar(HWND window, flutter::BinaryMessenger* messenger);
  ~VoiceThumbBar();

  VoiceThumbBar(const VoiceThumbBar&) = delete;
  VoiceThumbBar& operator=(const VoiceThumbBar&) = delete;

  // Called with every message to the top-level window. Returns a result for
  // the messages it consumes.
  std::optional<LRESULT> HandleMessage(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam);

 private:
  struct Button {
    bool hidden = true;
    std::wstring tooltip;
    HICON icon = nullptr;
  };

  // The same order and ids as VoiceControl in Dart.
  static constexpr size_t kButtonCount = 3;

  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SetButtons(const flutter::EncodableList& buttons);
  void AddButtons();
  void UpdateButtons();
  void FillButtons(std::array<THUMBBUTTON, kButtonCount>& out) const;
  flutter::EncodableMap ReadAppearance() const;
  void NotifyIfAppearanceChanged();

  HWND window_;
  UINT taskbar_button_created_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  ITaskbarList3* taskbar_ = nullptr;
  bool added_ = false;
  std::array<Button, kButtonCount> buttons_;
  flutter::EncodableMap appearance_;
};

#endif  // RUNNER_VOICE_THUMB_BAR_H_
