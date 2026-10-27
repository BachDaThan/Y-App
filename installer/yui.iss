; Inno Setup. AppId cố định => bản mới tự cài ĐÈ lên bản cũ, giữ nguyên dữ liệu (model, lịch sử nằm trong AppData, không bị xoá).
#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif
[Setup]
AppId={{FD4A58BF-F588-4B45-BE1D-59C35ECCAD51}
AppName=Yui
AppVersion={#MyAppVersion}
AppPublisher=BachDaThan
DefaultDirName={autopf}\Yui
DefaultGroupName=Yui
OutputDir=..\dist
OutputBaseFilename=Yui-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\yui_app.exe

[Tasks]
Name: "desktopicon"; Description: "Tạo biểu tượng ngoài màn hình"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Yui"; Filename: "{app}\yui_app.exe"
Name: "{autodesktop}\Yui"; Filename: "{app}\yui_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\yui_app.exe"; Description: "Mở Yui"; Flags: nowait postinstall skipifsilent
