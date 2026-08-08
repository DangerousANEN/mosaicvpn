; MosaicVPN Windows Installer
; NSIS 3.x script

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WordFunc.nsh"

; ─── Product info ──────────────────────────────────────────────────────
!define PRODUCT_NAME "MosaicVPN"
!define PRODUCT_VERSION "0.5.0"
!define PRODUCT_PUBLISHER "MosaicVPN"
!define PRODUCT_WEB_SITE "https://sub.zxc1x1.ru"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
!define PRODUCT_UNINST_ROOT_KEY "HKLM"

; ─── Installer attributes ─────────────────────────────────────────────
Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "..\dist\MosaicVPN-${PRODUCT_VERSION}-setup.exe"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey HKLM "${PRODUCT_UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

; ─── MUI settings ─────────────────────────────────────────────────────
!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

; ─── Pages ─────────────────────────────────────────────────────────────
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; ─── Languages ─────────────────────────────────────────────────────────
!insertmacro MUI_LANGUAGE "Russian"
!insertmacro MUI_LANGUAGE "English"

; ─── Installer sections ───────────────────────────────────────────────
Section "MosaicVPN" SEC_MAIN
    SectionIn RO

    ; Stop running daemon if any
    nsExec::ExecToLog 'taskkill /F /IM mosaicd.exe'
    nsExec::ExecToLog 'taskkill /F /IM mosaic_vpn.exe'
    Sleep 1000

    ; ── Go daemon + CLI ──
    SetOutPath "$INSTDIR\bin"
    File "..\build\mosaicd.exe"
    File "..\build\mosaic.exe"

    ; ── Flutter UI ──
    SetOutPath "$INSTDIR\ui"
    File "..\flutter\build\windows\x64\runner\Release\mosaic_vpn.exe"
    File "..\flutter\build\windows\x64\runner\Release\flutter_windows.dll"
    File "..\flutter\build\windows\x64\runner\Release\dartjni.dll"
    File "..\flutter\build\windows\x64\runner\Release\screen_retriever_windows_plugin.dll"
    File "..\flutter\build\windows\x64\runner\Release\system_tray_plugin.dll"
    File "..\flutter\build\windows\x64\runner\Release\url_launcher_windows_plugin.dll"
    File "..\flutter\build\windows\x64\runner\Release\window_manager_plugin.dll"

    ; Flutter data directory
    SetOutPath "$INSTDIR\ui\data"
    File /r "..\flutter\build\windows\x64\runner\Release\data\*.*"

    ; ── Shortcuts ──
    SetOutPath "$INSTDIR"

    ; Start Menu
    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\ui\mosaic_vpn.exe" "" "$INSTDIR\ui\mosaic_vpn.exe" 0
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\uninstall.exe" 0

    ; Desktop shortcut
    CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\ui\mosaic_vpn.exe" "" "$INSTDIR\ui\mosaic_vpn.exe" 0

    ; ── Windows Service (daemon auto-start) ──
    ; Install mosaicd as a Windows service that starts on boot
    nsExec::ExecToLog '"$INSTDIR\bin\mosaicd.exe" service install'

    ; ── Registry (Add/Remove Programs) ──
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "NoModify" 1
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "NoRepair" 1

    ; Calculate installed size
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "EstimatedSize" "$0"

    ; Write uninstaller
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Add bin directory to system PATH
    ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path"
    WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path" "$0;$INSTDIR\bin"
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000

SectionEnd

; ─── Uninstaller ───────────────────────────────────────────────────────
Section "Uninstall"

    ; Stop services
    nsExec::ExecToLog '"$INSTDIR\bin\mosaicd.exe" service uninstall'
    nsExec::ExecToLog 'taskkill /F /IM mosaicd.exe'
    nsExec::ExecToLog 'taskkill /F /IM mosaic_vpn.exe'
    Sleep 1000

    ; Remove files
    RMDir /r "$INSTDIR\bin"
    RMDir /r "$INSTDIR\ui"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"

    ; Remove shortcuts
    Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
    RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"

    ; Remove from PATH
    ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path"
    ${WordReplace} $0 ";$INSTDIR\bin" "" "+" $0
    WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path" $0
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000

    ; Remove registry
    DeleteRegKey ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}"

SectionEnd
