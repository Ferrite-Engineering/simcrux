cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  # GTK file dialogs drawn in-process, with no DBus desktop portal (which a
  # remote display often lacks), and the handler that keeps an X server's
  # refusal of the alert sound from ending the process. Shared by every
  # product through crux-shared's crux_file_dialogs package.
  "${CMAKE_SOURCE_DIR}/../crux-shared/packages/crux_file_dialogs/native/linux/crux_file_dialogs.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
# crux_file_dialogs.cc installs an X error handler (XSetErrorHandler).
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}/../crux-shared/packages/crux_file_dialogs/native/linux")
