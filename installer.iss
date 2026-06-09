[Setup]
AppId={{5E16A8C2-AB4C-43CD-8CD7-DF3D1294F5C0}
AppName=ZapShare
AppVersion=1.0.0
AppPublisher=ZapShare Team
DefaultDirName={autopf}\ZapShare
DisableProgramGroupPage=yes
OutputDir=d:\Desktop\ZapShare\ZapShare\build\windows\installer
OutputBaseFilename=ZapShare_Installer
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "d:\Desktop\ZapShare\ZapShare\build\windows\x64\runner\Release\zap_share.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "d:\Desktop\ZapShare\ZapShare\build\windows\x64\runner\Release\mpv\*"; DestDir: "{app}\mpv"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "d:\Desktop\ZapShare\ZapShare\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ZapShare"; Filename: "{app}\zap_share.exe"
Name: "{autodesktop}\ZapShare"; Filename: "{app}\zap_share.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\zap_share.exe"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ZapShare"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""ZapShare"" dir=in action=allow program=""{app}\zap_share.exe"" enable=yes profile=any"; Flags: runhidden
Filename: "{app}\zap_share.exe"; Description: "{cm:LaunchProgram,ZapShare}"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\zap_share.exe"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ZapShare"""; Flags: runhidden
