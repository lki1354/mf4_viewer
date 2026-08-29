; Inno Setup script for the MF4 Viewer Windows installer.
;
; Build the app first, then compile this script:
;
;   flutter build windows --release
;   iscc windows\packaging\mf4_viewer.iss
;
; The result is dist\mf4_viewer-<version>-windows-x64-setup.exe.
;
; CI overrides the defaults below on the command line, e.g.
;
;   iscc /DMyAppVersion=1.2.3 /DMyVersionInfo=1.2.3.0 ^
;        /DOutputBaseFilename=mf4_viewer-v1.2.3-windows-x64-setup ^
;        windows\packaging\mf4_viewer.iss
;
; Requires Inno Setup 6 (https://jrsoftware.org/isdl.php).

#define MyAppName "MF4 Viewer"
#define MyAppPublisher "Lukas Riegler"
#define MyAppURL "https://github.com/lki1354/mf4_viewer"
#define MyAppExeName "mf4_viewer.exe"

; Version shown in the wizard and in "Apps & features".
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
; Numeric a.b.c.d version stamped into the setup executable itself.
#ifndef MyVersionInfo
  #define MyVersionInfo "1.0.0.0"
#endif
; Folder holding the release build that is packaged.
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "mf4_viewer-" + MyAppVersion + "-windows-x64-setup"
#endif

[Setup]
; Never change AppId: it is what ties an upgrade to an existing installation.
AppId={{2BDB3841-557C-4D7A-8888-2FE5A5C80D96}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyVersionInfo}
VersionInfoProductName={#MyAppName}
VersionInfoCompany={#MyAppPublisher}

DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile=..\..\LICENSE

; No admin rights needed for a per-user install; the user can still pick an
; all-users install in the first wizard page.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; Flutter desktop apps need 64-bit Windows 10 or newer.
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0

OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole release folder: mf4_viewer.exe, the Flutter/plugin DLLs and data\.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
