program desktop_smoke;

// Run with tools/test_desktop.ps1, which creates an isolated fixture. This is
// the real LCL form and protocol stack; only the selected programmer is fake.
{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Classes, SysUtils, StdCtrls, ExtCtrls, Menus, DOM,
  main, search, sregedit, findchip, ScriptEdit, basehw, simhw, uilanguage,
  LCLTranslator, LResources, operationmodel, norplanner, writeworkflow,
  recoveryworkflow, prodevidence;

type
  TSmoke = class
    procedure Run(Sender: TObject);
    procedure Failed(Sender: TObject; E: Exception);
  end;

var
  Runner: TSmoke;
  Timer: TTimer;
  Report: TStringList;
  Failures: integer;
  RecoveryPath: string;

procedure RecordLine(const Text: string);
begin
  Report.Add(Text);
  Report.SaveToFile('desktop-smoke.log');
end;

procedure Check(Value: boolean; const Text: string);
begin
  if Value then RecordLine('PASS: ' + Text)
  else
  begin
    Inc(Failures);
    RecordLine('FAIL: ' + Text);
  end;
end;

function EnglishMenu(Item: TMenuItem): boolean;
var
  Text: UnicodeString;
  I: integer;
begin
  Text := UTF8Decode(Item.Caption);
  for I := 1 to Length(Text) do
    if (Ord(Text[I]) >= $400) and (Ord(Text[I]) <= $4FF) then
    begin
      RecordLine('Untranslated menu: ' + Item.Name);
      Exit(False);
    end;
  for I := 0 to Item.Count - 1 do
    if not EnglishMenu(Item.Items[I]) then Exit(False);
  Result := True;
end;

procedure CreateInterruptedFixture;
var
  Original, Patch: TBytes;
  Geometry: TNORGeometry;
  Request: TOperationRequest;
  Job: TPreparedNORWrite;
  Err, Backup: string;
begin
  SetLength(Original, SIM_CAPACITY);
  FillChar(Original[0], Length(Original), $FF);
  Original[100] := $42;
  Original[7000] := $87;
  Patch := BytesOf(#1#2#3#4#5#6#7#8);
  InitOperationRequest(Request);
  Request.OperationID := 'interrupted-fixture';
  Request.Kind := okProgram;
  Request.Chip.Name := 'W25Q64JV';
  Request.Chip.JedecID := 'EF4017';
  Request.Chip.Capacity := SIM_CAPACITY;
  Request.Target.Length := Length(Patch);
  Check(BuildUniformNORGeometry(SIM_CAPACITY, 256, 4096, $20, Geometry, Err), 'recovery fixture geometry: ' + Err);
  Check(TPreparedNORWrite.Prepare(Request, Geometry, Original, Patch, 'fixture',
    Job, Err), 'recovery fixture plan: ' + Err);
  try
    Backup := ExpandFileName('backups/recovery-original.bin');
    Check(AtomicWriteDurable(Backup, Original, False, Err), 'original backup saved: ' + Err);
    Check(SaveRecoveryInputs(Backup, Job, 'smoke', RecoveryPath, Err), 'recovery bundle saved: ' + Err);
  finally
    Job.Free;
  end;
end;

procedure TSmoke.Failed(Sender: TObject; E: Exception);
begin
  Check(False, E.ClassName + ': ' + E.Message);
  Application.Terminate;
end;

procedure TSmoke.Run(Sender: TObject);
var
  Commit: TButton;
  Summary: TMemo;
  Profiles: TComboBox;
  Chip: TSimulatedHardware;
  I: integer;
  Language: string;
begin
  Timer.Enabled := False;
  try
    Check(MainForm.Visible and (Application.MainForm = MainForm),
      'startup opens the main work window');
    Check(Application.ModalLevel = 0, 'startup has no modal screen');
    Check(MainForm.MenuOptions.Caption = 'Options',
      'menu defaults to English without an external English catalog');
    Check(EnglishMenu(MainForm.MainMenu.Items), 'all built-in menus use English defaults');
    Language := 'missing-smoke-catalog';
    ApplyUILanguage(Language);
    Check(Language = 'en', 'missing chosen catalog falls back to built-in English');

    // Explicit language choices still load from beside the executable.
    Language := 'test';
    ApplyUILanguage(Language);
    Check(Language = 'test', 'explicit available language is preserved');
    TPOTranslator(LRSTranslator).UpdateTranslation(MainForm);
    Check(MainForm.MenuOptions.Caption = 'Test options', 'chosen catalog translates menus');
    for I := 0 to MainForm.LangMenuItem.Count - 1 do
      if MainForm.LangMenuItem.Items[I].Hint = 'en' then
        MainForm.ChangeLang(MainForm.LangMenuItem.Items[I]);
    Check(MainForm.MenuOptions.Caption = 'Options', 'English can be selected again');

    MainForm.FormDropFiles(nil, ['missing-image.bin']);
    Summary := TMemo(MainForm.FindComponent('WritePlanSummary'));
    Check(Pos('Cannot open this image', Summary.Text) > 0,
      'file errors appear in the main window');
    Check(Application.ModalLevel = 0, 'file errors do not open a modal');

    MainForm.MenuHWSIMClick(nil);
    if NVRAMancer.Current_HW <> CHW_SIM then
      raise Exception.Create('simulator was not selected; refusing all device operations');
    PollProgrammer(False);
    Check(NVRAMancer.Current_HW = CHW_SIM, 'only the simulated programmer is selected');
    Chip := TSimulatedHardware(NVRAMancer.Programmer);
    MainForm.ButtonReadIDClick(nil);
    Profiles := TComboBox(MainForm.FindComponent('MatchingChipProfiles'));
    Check((Profiles.Items.Count > 1) and not ChipSearchForm.Visible,
      'ambiguous detection presents profiles inside the work window');
    for I := 0 to Profiles.Items.Count - 1 do
      if Pos('W25Q64JV@EF4017', Profiles.Items[I]) = 1 then
        Profiles.ItemIndex := I;
    TButton(MainForm.FindComponent('UseMatchingChipProfile')).Click;
    Check(CurrentICParam.ID = 'EF4017', 'the inline choice selects the exact ID');

    MainForm.FormDropFiles(nil, ['sample.bin']);
    MainForm.HwTimerTimer(nil);
    Commit := TButton(MainForm.FindComponent('CommitPreparedWrite'));
    Check(Commit.Enabled, 'preparation enables explicit Write');
    Check(Chip.PeekByte(0) = $FF, 'preparation does not program the chip');
    RecordLine('Prepared plan: ' + Summary.Text);
    Commit.Click;
    Check((Chip.PeekByte(0) = 1) and (Chip.PeekByte(7) = 8),
      'explicit Write programs the accepted image');
    Check(Pos('Both verification sessions passed', Summary.Text) > 0,
      'desktop write reports both verification sessions');
    Check(not Commit.Enabled, 'a completed write consumes its prepared plan');
    Check(Application.ModalLevel = 0, 'normal preparation and Write show no modal');
    Check(not ChipSearchForm.Visible, 'normal write does not open a chip chooser');
    SaveOptions(SettingsFile);
    Check(TDOMElement(SettingsFile.DocumentElement.FindNode('locale')).
      GetAttribute('lang') = 'en', 'English preference is saved');
    RecordLine('Operation result: ' + Summary.Text);
    MainForm.Log.Lines.SaveToFile('operation.log');

    // Model a cable loss after erasing the first sector of the separately
    // saved original image. The completed normal write above is unrelated.
    for I := 0 to 4095 do Chip.PokeByte(I, $FF);
    Chip.PokeByte(7000, $87);
    Check(TComboBox(MainForm.FindComponent('InterruptedWrites')).Items.IndexOf(
      RecoveryPath) >= 0, 'unfinished on-disk recovery appears in the workspace');
    TButton(MainForm.FindComponent('RecoverInterruptedWrite')).Click;
    Check(Commit.Enabled, 'recovery prepares an explicit Write from saved inputs');
    RecordLine('Recovery plan: ' + Summary.Text);
    Check(Chip.PeekByte(100) = $FF, 'preparing recovery does not mutate the chip');
    if Commit.Enabled then Commit.Click;
    Check((Chip.PeekByte(0) = 1) and (Chip.PeekByte(100) = $42) and
      (Chip.PeekByte(7000) = $87), 'desktop recovery restores image and erased neighbours');
    Check(not FileExists(RecoveryPath), 'successful recovery retires its journal');
    Check(Pos('Both verification sessions passed', Summary.Text) > 0,
      'desktop recovery requires both verification sessions');
    Check(Application.ModalLevel = 0, 'recovery stays in the work window');
    Check(Pos('recovery-original.bin', Summary.Text) > 0,
      'recovery result points to the original recoverable backup');
    RecordLine('Recovery result: ' + Summary.Text);
    MainForm.Log.Lines.SaveToFile('operation.log');
  except
    on E: Exception do Failed(nil, E);
  end;
  Application.Terminate;
end;

begin
  SetCurrentDir(ExtractFilePath(ParamStr(0)));
  Report := TStringList.Create;
  Runner := TSmoke.Create;
  try
    RecordLine('Desktop smoke starting');
    LoadXML;
    Translate(SettingsFile);
    CreateInterruptedFixture;
    RequireDerivedFormResource := True;
    Application.Initialize;
    Application.OnException := @Runner.Failed;
    Application.CreateForm(TMainForm, MainForm);
    MainForm.HwTimer.Enabled := False;
    Application.CreateForm(TSearchForm, SearchForm);
    Application.CreateForm(TsregeditForm, sregeditForm);
    Application.CreateForm(TChipSearchForm, ChipSearchForm);
    Application.CreateForm(TScriptEditForm, ScriptEditForm);
    Timer := TTimer.Create(nil);
    Timer.Interval := 100;
    Timer.OnTimer := @Runner.Run;
    Timer.Enabled := True;
    Application.Run;
    Timer.Free;
    MainForm.Free;
    RecordLine('Desktop smoke complete: ' + IntToStr(Failures) + ' failures');
  except
    on E: Exception do Check(False, E.ClassName + ': ' + E.Message);
  end;
  Runner.Free;
  Report.Free;
  ExitCode := Ord(Failures <> 0);
end.
