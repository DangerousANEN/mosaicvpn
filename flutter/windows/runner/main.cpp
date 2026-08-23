#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

// Portable builds never run the Inno Setup [Registry] section, so the
// mosaicvpn:// callback protocol would stay unregistered and website
// enrollment buttons would silently do nothing. Register it under HKCU on
// every launch - idempotent, no admin rights needed.
static void EnsureProtocolRegistration() {
  HKEY key = nullptr;
  const wchar_t *subkey = L"Software\\Classes\\mosaicvpn";
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, subkey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  ::RegSetValueExW(key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE *>(L"URL:MosaicVPN Protocol"),
                   sizeof(L"URL:MosaicVPN Protocol"));
  ::RegSetValueExW(key, L"URL Protocol", 0, REG_SZ, reinterpret_cast<const BYTE *>(L""),
                   sizeof(L""));
  ::RegCloseKey(key);

  const wchar_t *icon_key =
      L"Software\\Classes\\mosaicvpn\\DefaultIcon";
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, icon_key, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) == ERROR_SUCCESS) {
    ::RegSetValueExW(key, nullptr, 0, REG_SZ,
                     reinterpret_cast<const BYTE *>(L"MosaicVPN.exe,0"),
                     sizeof(L"MosaicVPN.exe,0"));
    ::RegCloseKey(key);
  }

  wchar_t command[MAX_PATH * 2] = {};
  wchar_t exe_path[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }
  ::swprintf_s(command, L"\"%s\" \"%%1\"", exe_path);
  const wchar_t *cmd_key =
      L"Software\\Classes\\mosaicvpn\\shell\\open\\command";
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, cmd_key, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) == ERROR_SUCCESS) {
    ::RegSetValueExW(key, nullptr, 0, REG_SZ,
                     reinterpret_cast<const BYTE *>(command),
                     static_cast<DWORD>((::wcslen(command) + 1) * sizeof(wchar_t)));
    ::RegCloseKey(key);
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A protocol launch starts a second process on Windows. Forward its URI to
  // the existing MosaicVPN window before the normal single-instance guard
  // suppresses it, then let Dart exchange the one-time enrollment code.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  EnsureProtocolRegistration();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"MosaicBox", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
