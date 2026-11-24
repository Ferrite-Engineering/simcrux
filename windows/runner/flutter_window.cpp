#include "flutter_window.h"

#include <cstdint>
#include <memory>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

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
