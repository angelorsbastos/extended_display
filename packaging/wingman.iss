; Inno Setup script: turns PyInstaller's dist\Wingman folder into
; Wingman-Setup-<version>.exe, a normal Windows installer (no Python needed).
;
;   iscc /DAppVersion=0.2.1 packaging\wingman.iss
;
; It installs Wingman to Program Files, adds it to the Start menu (and,
; optionally, the desktop and Explorer's "Send to"), lets it through the
; firewall on private networks (so the iPad is found on Wi-Fi), can add the
; iPad 10's screen size for Extend, and offers the two free drivers Wingman
; needs if they're missing. What Wingman saves (pairings, shortcuts, the log)
; is in %APPDATA%\Wingman and survives updates and uninstalling.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define Dist SourcePath + "..\dist\Wingman"

[Setup]
AppId={{6B8E1C2A-4F7D-4E31-9A0B-57C9D3E2F1A4}
AppName=Wingman
AppVersion={#AppVersion}
AppVerName=Wingman {#AppVersion}
AppPublisher=angelorsbastos
AppPublisherURL=https://github.com/angelorsbastos/wingman
AppSupportURL=https://github.com/angelorsbastos/wingman#troubleshooting
DefaultDirName={autopf}\Wingman
DefaultGroupName=Wingman
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir={#SourcePath}..\dist
OutputBaseFilename=Wingman-Setup-{#AppVersion}
SetupIconFile={#SourcePath}..\pc\assets\icon.ico
UninstallDisplayIcon={app}\Wingman.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; the hub holds this while running: Setup asks to close it before updating
AppMutex=WingmanHub
CloseApplications=yes
; the Send to shortcut goes to the person installing (Setup runs as admin)
UsedUserAreasWarning=no

[Tasks]
Name: "desktopicon"; Description: "Put Wingman on the desktop"
Name: "sendto"; Description: "Add ""Send to > iPad (Wingman)"" to Explorer's right-click menu"
Name: "ipadres"; Description: "Add the iPad 10's screen size (2360 x 1640) for Extend"; Flags: unchecked

[Files]
Source: "{#Dist}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Wingman"; Filename: "{app}\Wingman.exe"; Comment: "Your iPad and iPhone, beside your laptop"
Name: "{autodesktop}\Wingman"; Filename: "{app}\Wingman.exe"; Tasks: desktopicon
Name: "{usersendto}\iPad (Wingman)"; Filename: "{app}\Wingman.exe"; Parameters: "--send"; Tasks: sendto

[Registry]
; extra resolution for the Parsec Virtual Display Driver (see pc\ipad-resolution.reg)
Root: HKLM; Subkey: "SOFTWARE\Parsec\vdd\0"; ValueType: dword; ValueName: "width"; ValueData: "2360"; Tasks: ipadres
Root: HKLM; Subkey: "SOFTWARE\Parsec\vdd\0"; ValueType: dword; ValueName: "height"; ValueData: "1640"; Tasks: ipadres
Root: HKLM; Subkey: "SOFTWARE\Parsec\vdd\0"; ValueType: dword; ValueName: "hz"; ValueData: "60"; Tasks: ipadres

[Run]
; let Wingman find the iPad on home Wi-Fi without a firewall pop-up (private networks only)
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Wingman"" dir=in action=allow program=""{app}\Wingman.exe"" profile=private"; Flags: runhidden
Filename: "https://apps.microsoft.com/detail/9NP83LWLPZ9K"; Description: "Get Apple Devices (needed for the cable connection)"; Flags: postinstall shellexec skipifsilent unchecked; Check: AppleServiceMissing
Filename: "https://github.com/nomi-san/parsec-vdd#-getting-started"; Description: "Get the Parsec Virtual Display Driver (needed for Extend)"; Flags: postinstall shellexec skipifsilent unchecked; Check: ParsecMissing
Filename: "{app}\Wingman.exe"; Description: "Start Wingman now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM Wingman.exe /F"; Flags: runhidden; RunOnceId: "StopWingman"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Wingman"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[Code]
{ Apple's USB service, from Apple Devices (Microsoft Store) or iTunes }
function AppleServiceMissing: Boolean;
begin
  Result := not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\Apple Mobile Device Service');
end;

{ The Parsec Virtual Display Adapter: a display device whose hardware id names Parsec }
function ParsecMissing: Boolean;
var
  Devices: TArrayOfString;
  Ids: String;
  I: Integer;
begin
  Result := True;
  if RegGetSubkeyNames(HKLM, 'SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY', Devices) then
    for I := 0 to GetArrayLength(Devices) - 1 do
      if RegQueryMultiStringValue(HKLM, 'SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY\' + Devices[I],
                                  'HardwareID', Ids) then
        if Pos('PARSEC', Uppercase(Ids)) > 0 then
        begin
          Result := False;
          Exit;
        end;
end;
