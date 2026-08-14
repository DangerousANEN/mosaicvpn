; MosaicVPN — Windows installer recipe for Inno Setup 6.
; Usage from a Windows repository checkout:
;   iscc /DSourceDir="C:\path\to\mosaicvpn\dist\windows\MosaicVPN" /DVersion="0.3.1" scripts\setup.iss

#ifndef SourceDir
  #error SourceDir must point to the staged MosaicVPN portable folder.
#endif
#ifndef Version
  #define Version "0.0.0"
#endif

#define MyAppName "MosaicVPN"
#define MyAppVersion Version
#define MyAppPublisher "MosaicVPN"
#define MyAppURL "https://github.com/DangerousANEN/mosaicvpn"
#define MyAppExeName "MosaicVPN.exe"

[Setup]
AppId={{D37B9A2F-8E41-4E76-A899-7A8B1A2C3D4E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#SourceDir}\..
OutputBaseFilename=MosaicVPN-Setup-x64-v{#MyAppVersion}
SetupIconFile={#SourceDir}\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Launch MosaicVPN when you sign in"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "MosaicVPN"; ValueData: "\"{app}\{#MyAppExeName}\""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
