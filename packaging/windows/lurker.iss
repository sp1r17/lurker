; Lurker's Windows installer (Inno Setup 6). build.ps1 runs it with AppVersion and
; Dist (the folder of files to install) defined.

#ifndef AppVersion
  #define AppVersion "dev"
#endif

[Setup]
AppId={{6B3F3D52-7C1E-4D7A-9C55-2A8C1F0E9B41}
AppName=Lurker
AppVersion={#AppVersion}
AppPublisher=spirit
AppPublisherURL=https://github.com/sp1r17/lurker
AppSupportURL=https://github.com/sp1r17/lurker/issues
DefaultDirName={autopf}\Lurker
DefaultGroupName=Lurker
DisableProgramGroupPage=yes
; Installs for the current user unless they choose all users.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#Dist}\LICENSE.txt
SetupIconFile=..\..\assets\install\lurker.ico
UninstallDisplayIcon={app}\lurker.exe
OutputBaseFilename=lurker-{#AppVersion}-x86_64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#Dist}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Lurker"; Filename: "{app}\lurker.exe"
Name: "{autodesktop}\Lurker"; Filename: "{app}\lurker.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lurker.exe"; Description: "{cm:LaunchProgram,Lurker}"; Flags: nowait postinstall skipifsilent
