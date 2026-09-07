; TrustmeWatcher Windows installer. The application payload is assembled by
; build_windows.ps1 from the pinned ActivityWatch source and Trustme modules.

#define MyAppName GetEnv("APP_NAME")
#define MyAppVersion GetEnv("RELEASE_VERSION")
#define MyAppDir GetEnv("WINDOWS_APP_DIR")
#define MyOutputDir GetEnv("WINDOWS_OUTPUT_DIR")
#define MyOutputBaseName MyAppName + "-windows-x86_64-setup"
#define MyAppExeName "aw-qt.exe"

#if MyAppName == ""
  #error "APP_NAME is required"
#endif
#if MyAppVersion == ""
  #error "RELEASE_VERSION is required"
#endif
#if MyAppDir == ""
  #error "WINDOWS_APP_DIR is required"
#endif
#if MyOutputDir == ""
  #error "WINDOWS_OUTPUT_DIR is required"
#endif

[Setup]
AppId={{5FBAFAB8-7AEC-43D7-BBEC-A72DE49E7444}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=TrustmeWatcher Contributors
AppPublisherURL=https://github.com/Yumeansfish/TrustmeWatcher
AppSupportURL=https://github.com/Yumeansfish/TrustmeWatcher/issues
AppUpdatesURL=https://github.com/Yumeansfish/TrustmeWatcher/releases
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseName}
SetupIconFile={#MyAppDir}\media\logo\logo.ico
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start {#MyAppName} when Windows starts"; GroupDescription: "Windows startup"; Flags: unchecked

[Files]
Source: "{#MyAppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
