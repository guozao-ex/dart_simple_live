; Simple Live Windows x64 安装包脚本
; 编译：ISCC.exe simple_live_app.iss
; 依赖先执行 flutter build windows --release，产物在 ..\..\build\windows\x64\runner\Release

#define AppName "Simple Live"
#define AppExeName "simple_live_app.exe"
#define ReleaseDir "..\..\build\windows\x64\runner\Release"
; 版本号从 Flutter 产物的 exe 资源读取，例如 "1.11.4.11104"
#define AppVersionFull GetVersionNumbersString(ReleaseDir + "\" + AppExeName)
#define VerDotPos RPos(".", AppVersionFull)
#define AppVersionCode Copy(AppVersionFull, VerDotPos + 1, Len(AppVersionFull) - VerDotPos)
#define AppVersion Copy(AppVersionFull, 1, VerDotPos - 1)

[Setup]
AppId={{8780E2BF-589F-4BB8-86B2-841B800EF06E}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=guozao-ex
AppPublisherURL=https://github.com/guozao-ex/dart_simple_live
DefaultDirName={autopf}\Simple Live
DefaultGroupName=Simple Live
DisableProgramGroupPage=yes
OutputDir=..\..\..\dist
OutputBaseFilename=simple_live_app-{#AppVersion}+{#AppVersionCode}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoVersion={#AppVersionFull}
VersionInfoCompany=guozao-ex
VersionInfoDescription=Simple Live Installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
