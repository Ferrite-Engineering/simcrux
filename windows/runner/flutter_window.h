#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Runs the app's exit listeners before a Windows logoff, shutdown or
  // restart ends the process: sends the framework the cancelable exit request
  // a last-window close sends, then pumps messages until Dart answers or
  // kSessionEndDeadlineMs passes. Called once, from WM_ENDSESSION.
  void RunExitListenersBeforeSessionEnds();

  // Answers crux_window_chrome's `crux_window_chrome/foreground` channel, the
  // directed cross-probe's foreground hand-off: `yieldForeground {pid}` lets
  // that process set the foreground window (AllowSetForegroundWindow) and
  // answers "", or null when Windows refused; `takeForeground {token}`
  // restores this window if minimised and brings it forward
  // (SetForegroundWindow), answering whether it came forward. When Windows
  // refuses, it flashes the taskbar button itself.
  void RegisterForegroundChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The foreground hand-off channel; see RegisterForegroundChannel.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      foreground_channel_;

  // Whether WM_ENDSESSION has already started the exit request.
  bool session_ending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
