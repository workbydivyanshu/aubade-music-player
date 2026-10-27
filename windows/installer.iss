; Aubade - Windows installer (Inno Setup 6).
;
; Built ONLY for releases (v* tags); see .github/workflows/desktop.yml.
; Version is injected by CI: ISCC /DMyAppVersion=1.0.0
; Local dev build: ISCC windows/installer.iss  (defaults to 1.0.0-dev)
;
; Per-user install (no admin UAC): {localappdata}\Programs\Aubade.
; User data (SQLite, prefs, downloads live elsewhere) is untouched
; by install/uninstall.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0-dev"
#endif
#define MyAppName "Aubade"
#define MyAppPublisher "Aubade Team"
#define MyAppURL "https://github.com/workbydivyanshu/aubade-music-player"
#define MyAppExeName "aubade.exe"
#define MyAppId "{{E8B4F6A2-7C3D-4A1E-9F5B-2D6A8C4E1A3B5}"
; Must match kAubadeAppUserModelId in windows/runner/app_identity.h.
; The shell resolves the SMTC volume-flyout label/icon via the Start Menu
; shortcut's AppUserModelID - without this the flyout shows "Unknown app"
; with no logo even though the exe sets the same ID at runtime.
#define MyAppUserModelId "com.aubade.desktop"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\Aubade
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\windows\installer
OutputBaseFilename=aubade_{#MyAppVersion}_windows-x86_64-setup
Compression=zip/1
SolidCompression=no
SetupIconFile=runner\resources\app_icon.ico
SignedUninstaller=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
VersionInfoVersion={#MyAppVersion}
VersionInfoTextVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductTextVersion={#MyAppVersion}
; No LicenseFile yet: no license text in the repo. Add it when it lands.
; zip/1 with metadata fields and an explicit icon avoids antivirus
; false positives caused by solid ultra-compressed unsigned-looking
; installers; the setup stays a few MB larger on purpose.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "{#MyAppUserModelId}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; AppUserModelID: "{#MyAppUserModelId}"

[Registry]
; Presence, not hijack: audio files get an "Open with Aubade" entry, but
; the user's current default handler (and UserChoice) is never touched.
; Per-user install, so everything lives under HKCU\Software\Classes.
Root: HKCU; Subkey: "Software\Classes\Aubade.AudioFile"; ValueType: string; ValueName: ""; ValueData: "Aubade audio file"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Aubade.AudioFile"; ValueType: string; ValueName: "FriendlyTypeName"; ValueData: "Aubade audio file"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Aubade.AudioFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\aubade.exe,0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Aubade.AudioFile\shell\open"; ValueType: string; ValueName: ""; ValueData: "Open with Aubade"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Aubade.AudioFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\aubade.exe"" ""%1"""; Flags: uninsdeletekey
; Advertise the ProgID as an optional handler for each extension. Only
; OpenWithProgids is written; the .<ext> default value is never modified.
Root: HKCU; Subkey: "Software\Classes\.mp3\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.flac\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ogg\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.oga\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.opus\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.m4a\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.m4b\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wav\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aiff\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aif\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aifc\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wma\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aac\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ape\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wv\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mka\OpenWithProgids"; ValueType: string; ValueName: "Aubade.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
; Lets Explorer list Aubade under "Open with" even before a file type
; has been opened once. SupportedTypes is the canonical Applications key.
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Aubade"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".mp3"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".flac"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".ogg"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".oga"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".opus"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".m4a"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".m4b"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".wav"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".aiff"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".aif"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".aifc"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".wma"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".aac"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".ape"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".wv"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\aubade.exe\SupportedTypes"; ValueType: string; ValueName: ".mka"; ValueData: ""; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
{ Ask Explorer to re-read file associations once the registry entries are }
{ in place, so "Open with Aubade" shows up without a reboot or logout. }
procedure SHChangeNotify(wEventId, uFlags: DWORD; dwItem1, dwItem2: DWORD); external 'SHChangeNotify@shell32.dll stdcall';

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SHChangeNotify($08000000, 0, 0, 0);  { SHCNE_ASSOCCHANGED }
end;

