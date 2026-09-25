#include "voice_thumb_bar.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <vector>

namespace {

constexpr char kChannelName[] = "chat.commet.commetapp/taskbar";

// "Choose your Windows mode", which the taskbar follows. The runner's title
// bar reads AppsUseLightTheme from the same key; that is the app mode, and
// the taskbar can differ from it.
constexpr wchar_t kPersonalizeKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr wchar_t kSystemUsesLightTheme[] = L"SystemUsesLightTheme";

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      utf16.data(), length);
  return utf16;
}

// A 32-bit icon from straight-alpha RGBA, which is how Dart draws it.
HICON IconFromRgba(const std::vector<uint8_t>& rgba, int size) {
  const size_t pixels = static_cast<size_t>(size) * static_cast<size_t>(size);
  if (size <= 0 || rgba.size() != pixels * 4) {
    return nullptr;
  }

  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = size;
  header.bV5Height = -size;  // Top-down, like the RGBA rows.
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;

  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP color =
      CreateDIBSection(screen, reinterpret_cast<BITMAPINFO*>(&header),
                       DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (color == nullptr) {
    return nullptr;
  }

  auto* bgra = static_cast<uint8_t*>(bits);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    bgra[i] = rgba[i + 2];
    bgra[i + 1] = rgba[i + 1];
    bgra[i + 2] = rgba[i];
    bgra[i + 3] = rgba[i + 3];
  }

  // The alpha channel does the masking; the AND mask only has to exist.
  std::vector<uint8_t> mask_bits(
      static_cast<size_t>(((size + 15) / 16) * 2 * size), 0);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, mask_bits.data());

  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmMask = mask;
  info.hbmColor = color;
  HICON icon = CreateIconIndirect(&info);

  DeleteObject(mask);
  DeleteObject(color);
  return icon;
}

}  // namespace

VoiceThumbBar::VoiceThumbBar(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_button_created_(RegisterWindowMessage(L"TaskbarButtonCreated")),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  // An elevated roscord would otherwise never hear from Explorer, which runs
  // unelevated.
  ChangeWindowMessageFilterEx(window_, taskbar_button_created_, MSGFLT_ALLOW,
                              nullptr);
  ChangeWindowMessageFilterEx(window_, WM_COMMAND, MSGFLT_ALLOW, nullptr);

  appearance_ = ReadAppearance();
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        OnMethodCall(call, std::move(result));
      });
}

VoiceThumbBar::~VoiceThumbBar() {
  channel_->SetMethodCallHandler(nullptr);
  if (taskbar_ != nullptr) {
    taskbar_->Release();
  }
  for (Button& button : buttons_) {
    if (button.icon != nullptr) {
      DestroyIcon(button.icon);
    }
  }
}

std::optional<LRESULT> VoiceThumbBar::HandleMessage(HWND /* window */,
                                                    UINT message,
                                                    WPARAM wparam,
                                                    LPARAM /* lparam */) {
  if (message == taskbar_button_created_) {
    // A new taskbar button: the first show, a show after the window was
    // hidden, or Explorer coming back. It has no buttons yet.
    added_ = false;
    AddButtons();
    return std::nullopt;
  }

  switch (message) {
    case WM_COMMAND:
      if (HIWORD(wparam) == THBN_CLICKED) {
        const WORD id = LOWORD(wparam);
        if (static_cast<size_t>(id) < kButtonCount) {
          channel_->InvokeMethod(
              "onButtonClicked",
              std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                  {flutter::EncodableValue("id"),
                   flutter::EncodableValue(static_cast<int32_t>(id))}}));
          return 0;
        }
      }
      break;
    case WM_SETTINGCHANGE:  // "ImmersiveColorSet": Windows mode.
    case WM_SYSCOLORCHANGE:  // A contrast theme on, off or changed.
    case WM_THEMECHANGED:
    case WM_DPICHANGED:
      NotifyIfAppearanceChanged();
      break;
  }
  return std::nullopt;
}

void VoiceThumbBar::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getAppearance") {
    appearance_ = ReadAppearance();
    result->Success(flutter::EncodableValue(appearance_));
  } else if (call.method_name() == "setButtons") {
    const auto* buttons = std::get_if<flutter::EncodableList>(call.arguments());
    if (buttons == nullptr) {
      result->Error("bad-arguments", "setButtons takes a list");
      return;
    }
    SetButtons(*buttons);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void VoiceThumbBar::SetButtons(const flutter::EncodableList& buttons) {
  std::array<HICON, kButtonCount> old_icons = {};
  for (const flutter::EncodableValue& value : buttons) {
    const auto* map = std::get_if<flutter::EncodableMap>(&value);
    if (map == nullptr) {
      continue;
    }
    const auto* id = Find(*map, "id");
    if (id == nullptr || !std::holds_alternative<int32_t>(*id)) {
      continue;
    }
    const int32_t index = std::get<int32_t>(*id);
    if (index < 0 || index >= static_cast<int32_t>(kButtonCount)) {
      continue;
    }

    Button& button = buttons_[static_cast<size_t>(index)];
    old_icons[static_cast<size_t>(index)] = button.icon;
    button.icon = nullptr;

    const auto* tooltip = Find(*map, "tooltip");
    button.tooltip = tooltip != nullptr && std::holds_alternative<std::string>(
                                               *tooltip)
                         ? Utf16FromUtf8(std::get<std::string>(*tooltip))
                         : std::wstring();

    const auto* icon = Find(*map, "icon");
    const auto* size = Find(*map, "size");
    if (icon != nullptr && size != nullptr &&
        std::holds_alternative<std::vector<uint8_t>>(*icon) &&
        std::holds_alternative<int32_t>(*size)) {
      button.icon = IconFromRgba(std::get<std::vector<uint8_t>>(*icon),
                                 std::get<int32_t>(*size));
    }

    const auto* hidden = Find(*map, "hidden");
    // A button whose icon could not be made is hidden rather than blank.
    button.hidden = button.icon == nullptr ||
                    (hidden != nullptr && std::holds_alternative<bool>(*hidden) &&
                     std::get<bool>(*hidden));
  }

  UpdateButtons();

  // The taskbar keeps its own copies.
  for (HICON icon : old_icons) {
    if (icon != nullptr) {
      DestroyIcon(icon);
    }
  }
}

void VoiceThumbBar::FillButtons(
    std::array<THUMBBUTTON, kButtonCount>& out) const {
  for (size_t i = 0; i < kButtonCount; i++) {
    const Button& button = buttons_[i];
    THUMBBUTTON& thumb = out[i];
    thumb = {};
    thumb.iId = static_cast<UINT>(i);
    thumb.dwMask = THB_FLAGS | THB_TOOLTIP;
    thumb.dwFlags = button.hidden ? THBF_HIDDEN : THBF_ENABLED;
    wcsncpy_s(thumb.szTip, button.tooltip.c_str(), _TRUNCATE);
    if (button.icon != nullptr) {
      thumb.dwMask |= THB_ICON;
      thumb.hIcon = button.icon;
    }
  }
}

void VoiceThumbBar::AddButtons() {
  if (taskbar_ == nullptr) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      taskbar_ = nullptr;
      return;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_->Release();
      taskbar_ = nullptr;
      return;
    }
  }

  std::array<THUMBBUTTON, kButtonCount> thumbs;
  FillButtons(thumbs);
  if (SUCCEEDED(taskbar_->ThumbBarAddButtons(
          window_, static_cast<UINT>(kButtonCount), thumbs.data()))) {
    added_ = true;
  } else if (SUCCEEDED(taskbar_->ThumbBarUpdateButtons(
                 window_, static_cast<UINT>(kButtonCount), thumbs.data()))) {
    // The message came twice for one taskbar button, which already has them.
    added_ = true;
  }
}

void VoiceThumbBar::UpdateButtons() {
  // Before the taskbar button exists this waits for TaskbarButtonCreated,
  // which adds them as they are by then.
  if (!added_ || taskbar_ == nullptr) {
    return;
  }
  std::array<THUMBBUTTON, kButtonCount> thumbs;
  FillButtons(thumbs);
  taskbar_->ThumbBarUpdateButtons(window_, static_cast<UINT>(kButtonCount),
                                  thumbs.data());
}

flutter::EncodableMap VoiceThumbBar::ReadAppearance() const {
  // Windows before 1903 has no light taskbar, and no value.
  DWORD light = 0;
  DWORD light_size = sizeof(light);
  if (RegGetValueW(HKEY_CURRENT_USER, kPersonalizeKey, kSystemUsesLightTheme,
                   RRF_RT_REG_DWORD, nullptr, &light,
                   &light_size) != ERROR_SUCCESS) {
    light = 0;
  }

  HIGHCONTRASTW contrast = {};
  contrast.cbSize = sizeof(contrast);
  const bool high_contrast =
      SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast,
                            0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;

  // What a contrast theme draws interactive things in.
  const COLORREF text = GetSysColor(COLOR_BTNTEXT);
  const int64_t text_argb = 0xFF000000LL |
                            (static_cast<int64_t>(GetRValue(text)) << 16) |
                            (static_cast<int64_t>(GetGValue(text)) << 8) |
                            static_cast<int64_t>(GetBValue(text));

  // The documented size for thumbnail toolbar images, at this window's DPI.
  const int icon_size =
      GetSystemMetricsForDpi(SM_CXICON, GetDpiForWindow(window_));

  return flutter::EncodableMap{
      {flutter::EncodableValue("light"), flutter::EncodableValue(light != 0)},
      {flutter::EncodableValue("highContrast"),
       flutter::EncodableValue(high_contrast)},
      {flutter::EncodableValue("contrastText"),
       flutter::EncodableValue(text_argb)},
      {flutter::EncodableValue("iconSize"),
       flutter::EncodableValue(static_cast<int32_t>(icon_size))},
  };
}

void VoiceThumbBar::NotifyIfAppearanceChanged() {
  // WM_SETTINGCHANGE comes for all sorts of things (locking the screen, a
  // UAC prompt), so Dart only hears about what it draws with.
  flutter::EncodableMap appearance = ReadAppearance();
  if (appearance == appearance_) {
    return;
  }
  appearance_ = appearance;
  channel_->InvokeMethod(
      "onAppearanceChanged",
      std::make_unique<flutter::EncodableValue>(appearance_));
}
