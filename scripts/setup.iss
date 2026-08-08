; Inno Setup Script for MosaicVPN Windows Installer
#define MyAppName "MosaicVPN"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Mosaic Team"
#define MyAppURL "https://github.com/pupspochta-cpu/mosaicvpn"
#define MyAppExeName "mosaic_vpn.exe"

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
LicenseFile=C:\Users\ANEN\mosaicvpn\LICENSE
OutputDir=C:\Users\ANEN\mosaicvpn\dist
OutputBaseFilename=MosaicVPN-Setup-v{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Launch MosaicVPN on system startup"; GroupDescription: "Options:"

[Files]
Source: "C:\Users\ANEN\mosaicvpn\dist\MosaicVPN\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
