#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// crux_window_chrome's foreground hand-off channel.
constexpr char kForegroundChannel[] = "crux_window_chrome/foreground";

// crux_window_chrome's request-attention channel.
constexpr char kAttentionChannel[] = "crux_window_chrome/attention";

// The `pid` argument of a `yieldForeground` call, or 0 when it is missing or
// not a positive integer.
int64_t ForegroundPidArgument(const flutter::EncodableValue* arguments) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return 0;
  }
  const auto entry = map->find(flutter::EncodableValue("pid"));
  if (entry == map->end()) {
    return 0;
  }
  if (const auto* narrow = std::get_if<int32_t>(&entry->second)) {
    return *narrow;
  }
  if (const auto* wide = std::get_if<int64_t>(&entry->second)) {
    return *wide;
  }
  return 0;
}

// The framework's platform channel and, as a JSON method call on it, the
// cancelable exit request the engine itself sends when the last window
// closes ("System.requestAppExit" with type "cancelable", the engine's
// platform_handler.cc). The framework answers it after every
// AppLifecycleListener.onExitRequested has run.
constexpr char kPlatformChannel[] = "flutter/platform";
constexpr char kSessionEndExitRequest[] =
    "{\"method\":\"System.requestAppExit\",\"args\":{\"type\":\"cancelable\"}}";

// How long WM_ENDSESSION waits for the exit listeners. Windows lets an app
// delay its WM_ENDSESSION answer for five seconds before it offers the user
// to end it; three keeps well inside that.
constexpr ULONGLONG kSessionEndDeadlineMs = 3000;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterForegroundChannel();
  RegisterAttentionChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  foreground_channel_ = nullptr;
  attention_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    // WM_QUERYENDSESSION is left to DefWindowProc, which answers TRUE at
    // once; cleanup waits for WM_ENDSESSION, as the Win32 documentation asks.
    case WM_ENDSESSION:
      // wParam is TRUE when the session really ends: the process can be ended
      // any time after this message returns, so the exit listeners run now.
      if (wparam) {
        RunExitListenersBeforeSessionEnds();
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterForegroundChannel() {
  foreground_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kForegroundChannel,
          &flutter::StandardMethodCodec::GetInstance());
  foreground_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "yieldForeground") {
          const int64_t pid = ForegroundPidArgument(call.arguments());
          // Allowed only while this process owns the foreground, which it
          // does at the user's click; null tells the sender no hand-off was
          // made, so the target asks for attention instead.
          if (pid <= 0 || pid > MAXDWORD ||
              !::AllowSetForegroundWindow(static_cast<DWORD>(pid))) {
            result->Success();
            return;
          }
          result->Success(flutter::EncodableValue(std::string()));
          return;
        }
        if (call.method_name() == "takeForeground") {
          HWND window = GetHandle();
          if (window == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          if (::IsIconic(window)) {
            ::ShowWindow(window, SW_RESTORE);
          }
          const bool raised = ::SetForegroundWindow(window) != FALSE;
          result->Success(flutter::EncodableValue(raised));
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::RegisterAttentionChannel() {
  attention_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kAttentionChannel,
          &flutter::StandardMethodCodec::GetInstance());
  attention_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "requestUserAttention") {
          result->NotImplemented();
          return;
        }
        // Flashes the taskbar button until the window is focused, and never
        // raises the window. `critical` is the same, with no count.
        HWND window = GetHandle();
        if (window != nullptr) {
          FLASHWINFO info = {};
          info.cbSize = sizeof(info);
          info.hwnd = window;
          info.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
          info.uCount = 0;
          info.dwTimeout = 0;
          ::FlashWindowEx(&info);
        }
        result->Success();
      });
}

void FlutterWindow::RunExitListenersBeforeSessionEnds() {
  if (session_ending_ || !flutter_controller_ ||
      !flutter_controller_->engine()) {
    return;
  }
  session_ending_ = true;

  // The reply runs on this thread, from a task the pump below dispatches.
  // Shared, so a reply that arrives after the deadline writes to live memory.
  auto answered = std::make_shared<bool>(false);
  flutter_controller_->engine()->messenger()->Send(
      kPlatformChannel,
      reinterpret_cast<const uint8_t*>(kSessionEndExitRequest),
      sizeof(kSessionEndExitRequest) - 1,
      [answered](const uint8_t* /*reply*/, size_t /*reply_size*/) {
        *answered = true;
      });

  // Dart runs on this thread, so it can answer only while messages are
  // pumped: the engine wakes its task runner with posted messages and timers.
  const ULONGLONG deadline = ::GetTickCount64() + kSessionEndDeadlineMs;
  while (!*answered) {
    const ULONGLONG now = ::GetTickCount64();
    if (now >= deadline) {
      break;
    }
    ::MsgWaitForMultipleObjectsEx(0, nullptr,
                                  static_cast<DWORD>(deadline - now),
                                  QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    MSG msg;
    while (!*answered && ::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        // The app is quitting already: hand WM_QUIT back to the main loop.
        ::PostQuitMessage(static_cast<int>(msg.wParam));
        return;
      }
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }
}
