; Compile through build_installer.py so required payloads are checked first.
#ifndef PayloadDir
  #error PayloadDir must name a prepared Windows runtime bundle
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId={{2941DCEF-542E-4B10-B683-D18F889EAC6E}
AppName=Graffitty
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Graffitty
DefaultGroupName=Graffitty
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Graffitty-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\assets\branding\exports\graffitty.ico
UninstallDisplayIcon={app}\Graffitty.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

; The app's languages, in config/localization.json order.
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "norwegian"; MessagesFile: "compiler:Languages\Norwegian.isl"
Name: "swedish"; MessagesFile: "compiler:Languages\Swedish.isl"
Name: "danish"; MessagesFile: "compiler:Languages\Danish.isl"

[CustomMessages]
english.CreateStartMenuIcon=Create a &Start menu shortcut
french.CreateStartMenuIcon=Créer un raccourci dans le menu &Démarrer
brazilianportuguese.CreateStartMenuIcon=Criar um atalho no menu &Iniciar
spanish.CreateStartMenuIcon=Crear un acceso directo en el menú &Inicio
italian.CreateStartMenuIcon=Crea un collegamento nel menu &Start
korean.CreateStartMenuIcon=시작 메뉴에 바로 가기 만들기(&S)
japanese.CreateStartMenuIcon=スタート メニューにショートカットを作成する(&S)
german.CreateStartMenuIcon=Verknüpfung im &Startmenü erstellen
norwegian.CreateStartMenuIcon=Opprett en snarvei i &Start-menyen
swedish.CreateStartMenuIcon=Skapa en genväg i &Start-menyn
danish.CreateStartMenuIcon=Opret en genvej i menuen &Start

english.AppDescription=Terminals and Chromium in one connected workspace
french.AppDescription=Terminaux et Chromium dans un même espace de travail connecté
brazilianportuguese.AppDescription=Terminais e Chromium em um só espaço de trabalho conectado
spanish.AppDescription=Terminales y Chromium en un mismo espacio de trabajo conectado
italian.AppDescription=Terminali e Chromium in un unico spazio di lavoro collegato
korean.AppDescription=터미널과 Chromium을 하나로 연결하는 작업 공간
japanese.AppDescription=ターミナルと Chromium をつなぐひとつのワークスペース
german.AppDescription=Terminals und Chromium in einem verbundenen Arbeitsbereich
norwegian.AppDescription=Terminaler og Chromium i ett sammenkoblet arbeidsområde
swedish.AppDescription=Terminaler och Chromium i en sammankopplad arbetsyta
danish.AppDescription=Terminaler og Chromium i ét forbundet arbejdsområde

[Tasks]
Name: "startmenuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "contextmenu"; Description: "Add Open in Graffitty to File Explorer"

; The current executable embeds its pack. An external pack left by a previous
; installation must not shadow the newly installed UI.
[InstallDelete]
Type: files; Name: "{app}\Graffitty.pck"
; Setup installs its own payload over any archive installed by install.ps1.
Type: files; Name: "{app}\.archive-sha256"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Graffitty"; Filename: "{app}\Graffitty.exe"; WorkingDir: "{%USERPROFILE}"; Comment: "{cm:AppDescription}"; Tasks: startmenuicon
Name: "{autodesktop}\Graffitty"; Filename: "{app}\Graffitty.exe"; WorkingDir: "{%USERPROFILE}"; Comment: "{cm:AppDescription}"; Tasks: desktopicon

; Per-user classic verbs. Windows 11 exposes these in Show more options.
; Appending \. keeps drive-root trailing backslashes away from closing quotes.
[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Graffitty"; ValueType: string; ValueData: "Open in Graffitty"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Graffitty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Graffitty.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Graffitty\command"; ValueType: string; ValueData: """{app}\Graffitty.exe"" -- --cwd ""%1\."""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Graffitty"; ValueType: string; ValueData: "Open in Graffitty"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Graffitty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Graffitty.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Graffitty\command"; ValueType: string; ValueData: """{app}\Graffitty.exe"" -- --cwd ""%V\."""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\Graffitty"; ValueType: string; ValueData: "Open in Graffitty"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\Graffitty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Graffitty.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\Graffitty\command"; ValueType: string; ValueData: """{app}\Graffitty.exe"" -- --cwd ""%1\."""; Tasks: contextmenu

; Files an upgrade renamed because a terminal holder was still running from them.
[UninstallDelete]
Type: files; Name: "{app}\.archive-sha256"
Type: files; Name: "{app}\*.old-*"
Type: files; Name: "{app}\tools\*.old-*"

[Run]
Filename: "{app}\Graffitty.exe"; WorkingDir: "{%USERPROFILE}"; Description: "{cm:LaunchProgram,Graffitty}"; Flags: nowait postinstall skipifsilent; Check: not Resumed

[Code]
var
  { True when Graffitty was running and this Setup closed it for the upgrade.
    Its terminals are still running. }
  Parked: Boolean;

function Resumed: Boolean;
begin
  Result := Parked;
end;

{ The file `gft internal update prepare` leaves behind when it closed a running
  Graffitty. It is in gft's state directory. }
function ParkedRecord: String;
begin
  Result := GetEnv('XDG_STATE_HOME');
  if Result = '' then
    Result := ExpandConstant('{localappdata}');
  Result := Result + '\graffitty\server.update.json';
end;

{ Windows cannot replace the files of a running Graffitty. So before copying,
  the installed gft does this (`gft internal update prepare`):
  1. Saves a checkpoint.
  2. Closes Graffitty's windows.
  3. Leaves the terminals running in their holder processes.
  4. Renames the files a holder still runs from. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  Gft: String;
begin
  Result := '';
  Gft := ExpandConstant('{app}\tools\gft.exe');
  if not FileExists(Gft) then
    Exit;
  if not Exec(Gft, 'internal update prepare', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Exit;
  { Exit codes: 0 = done, 2 = this gft is too old to know the command (carry
    on without it), anything else = failed (stop Setup).
    The record file exists only if a running Graffitty was closed. }
  if ResultCode = 0 then
    Parked := FileExists(ParkedRecord)
  else if ResultCode <> 2 then
    Result := 'Graffitty is running and could not hand over its terminals. ' +
      'Nothing was changed. Close Graffitty, then run Setup again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    { CEF's least-privileged app containers need read/execute access to the
      installed runtime. Archive extraction does not preserve these ACLs. }
    if not Exec(ExpandConstant('{sys}\icacls.exe'),
      '"' + ExpandConstant('{app}\chromium-windows') +
      '" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /T /Q',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      RaiseException('Could not configure the Chromium sandbox runtime.');
    { Start the new server, which takes over the running terminals, and
      reopen the windows. }
    if Parked then
      Exec(ExpandConstant('{app}\tools\gft.exe'), 'internal update finish', '', SW_HIDE,
        ewWaitUntilTerminated, ResultCode);
  end;
end;

{ Runs when Setup ends, also when it was cancelled or failed. If Graffitty
  was closed for the upgrade, start it again (a no-op if it already runs). }
procedure DeinitializeSetup;
var
  ResultCode: Integer;
begin
  if Parked and FileExists(ExpandConstant('{app}\tools\gft.exe')) then
    Exec(ExpandConstant('{app}\tools\gft.exe'), 'internal update finish', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
end;

procedure InitializeWizard;
begin
  { At high display scaling the modern wizard draws task checkboxes against the
    list's left edge, clipping them. Indent them by a scaled margin. }
  WizardForm.TasksList.Offset := ScaleX(6);
end;
