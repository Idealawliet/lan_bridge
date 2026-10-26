; Compile with Inno Setup 6 using build-windows.ps1.
[Setup]
AppId={{41D95CB4-65CF-4A0A-A80E-B1BCA9701790}
AppName=LAN Bridge
AppVersion={#AppVersion}
AppPublisher=LAN Bridge
DefaultDirName={localappdata}\Programs\LAN Bridge
DefaultGroupName=LAN Bridge
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDirectory}
OutputBaseFilename=lan-bridge-windows-x64-{#AppVersion}-setup-unsigned
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lan_bridge.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LAN Bridge"; Filename: "{app}\lan_bridge.exe"
Name: "{userdesktop}\LAN Bridge"; Filename: "{app}\lan_bridge.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\lan_bridge.exe"; Description: "Launch LAN Bridge"; Flags: nowait postinstall skipifsilent
