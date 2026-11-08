; Inno Setup script for the Tunetrail Windows installer.
; Built in CI: ISCC.exe /DAppSource=<Release folder> /O<output dir> windows\installer.iss

#ifndef AppSource
  #define AppSource "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{8E6F3C1A-6B7B-4F51-9C1E-7A54D0A1B7E3}
AppName=Tunetrail
AppVersion=0.1.0
AppPublisher=Tunetrail
DefaultDirName={autopf}\Tunetrail
DefaultGroupName=Tunetrail
OutputBaseFilename=Tunetrail-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Tunetrail.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Tunetrail"; Filename: "{app}\Tunetrail.exe"
Name: "{autodesktop}\Tunetrail"; Filename: "{app}\Tunetrail.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\Tunetrail.exe"; Description: "Launch Tunetrail"; Flags: nowait postinstall skipifsilent
