program writeworkflow_tests;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, operationmodel, norplanner, norengine, virtualspi25,
  writeworkflow, recoveryworkflow, writejournal, prodevidence,
  basehw, eepromengine, eepromsession, virtualeeprom;

type
  TSessionHardware = class(TBaseHardware)
  public
    OpenAttempts, Opens, Closes, BusStarts, BusEnds, RailRestores: integer;
    FailOpenAt: integer;
    Voltage: cardinal;
    function GetLastError: string; override;
    function DevOpen: boolean; override;
    procedure DevClose; override;
    function SPIInit(Speed: integer): boolean; override;
    procedure SPIDeinit; override;
    function SupportsTargetVoltage: boolean; override;
    function SetTargetVoltageMv(Millivolts: cardinal): boolean; override;
  end;
  TFreshEEPROM = class(TVirtualEEPROM)
  public
    CorruptOnReopen, FailClose: boolean;
    function Open: TEEPROMIOResult; override;
    function Close: TEEPROMIOResult; override;
  end;

function TSessionHardware.GetLastError: string;
begin
  Result := 'injected disconnected programmer';
end;

function TSessionHardware.DevOpen: boolean;
begin
  Inc(OpenAttempts);
  Result := (FailOpenAt = 0) or (OpenAttempts <> FailOpenAt);
  if Result then Inc(Opens);
end;

procedure TSessionHardware.DevClose;
begin
  Inc(Closes);
  Voltage := 0;
end;

function TSessionHardware.SPIInit(Speed: integer): boolean;
begin
  Inc(BusStarts);
  Result := Voltage = 1800;
end;

procedure TSessionHardware.SPIDeinit;
begin
  Inc(BusEnds);
end;

function TSessionHardware.SupportsTargetVoltage: boolean;
begin
  Result := True;
end;

function TSessionHardware.SetTargetVoltageMv(Millivolts: cardinal): boolean;
begin
  Inc(RailRestores);
  Voltage := Millivolts;
  Result := True;
end;

function TFreshEEPROM.Open: TEEPROMIOResult;
begin
  Result := inherited Open;
  if Result.Success and CorruptOnReopen and (OpenCount = 2) then
    Memory[1] := Memory[1] xor $01;
end;

function TFreshEEPROM.Close: TEEPROMIOResult;
begin
  Result := inherited Close;
  if FailClose then Result := EEPROMIOFailure(eioTransport, 'injected cleanup failure');
end;

var
  Assertions, Failures: integer;

procedure Check(Condition: boolean; const Text: string);
begin
  Inc(Assertions);
  if not Condition then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Text);
  end;
end;

procedure TestGate;
var
  Gate: TInlineWriteGate;
begin
  Gate := TInlineWriteGate.Create;
  try
    Check(not Gate.Present('image-A', 'plan-A', True),
      'first click only presents a plan');
    Check(Gate.ReadyFor('image-A'), 'presented plan is ready');
    Check(not Gate.ReadyFor('image-B'), 'edited input invalidates readiness');
    Check(not Gate.Present('image-A', 'plan-B', True),
      'changed physical snapshot requires a newly presented plan');
    Check(Gate.Present('image-A', 'plan-B', True),
      'explicit Write accepts the plan that was presented');
    Check(not Gate.Present('image-A', 'plan-B', True),
      'accepted plan cannot be reused by a repeated click');
  finally
    Gate.Free;
  end;
end;

procedure TestEEPROMSessions;
var
  Hardware: TSessionHardware;
  Chip: TFreshEEPROM;
  Session: TEEPROMSession;
  Executor: TEEPROMPlanExecutor;
  Plan: TEEPROMPlan;
  Request: TOperationRequest;
  Outcome: TOperationOutcome;
  Snapshot, Patch: TBytes;
  Err: string;
  Mode: integer;
begin
  for Mode := 0 to 4 do
  begin
    Hardware := TSessionHardware.Create;
    Chip := TFreshEEPROM.Create(32, 8);
    Snapshot := Copy(Chip.Memory);
    Patch := BytesOf(#$A5#$5A);
    Check(BuildEEPROMDifferentialPlan(Snapshot, Patch, 1, 8, Plan, Err), Err);
    InitOperationRequest(Request);
    Request.OperationID := 'session-test';
    Request.Kind := okProgram;
    Request.Policy.RequireEvidenceCommit := False;
    case Mode of
      1: Chip.Memory[31] := 0; // changed outside the planned write page
      2: Hardware.FailOpenAt := 2;
      3: Chip.CorruptOnReopen := True;
      4: Chip.FailClose := True;
    end;
    Session := TEEPROMSession.Create(Chip, Hardware, ebSPI, 3, 1800, 8, Snapshot);
    Executor := TEEPROMPlanExecutor.Create(Session);
    try
      Outcome := Executor.Execute(Request, Plan, 32, nil);
      if Mode = 0 then
      begin
        Check((Outcome.Status = osSucceeded) and Outcome.FreshSessionVerifyCompleted,
          'EEPROM completes only after fresh-session verification');
        Check((Hardware.Opens = 2) and (Hardware.RailRestores = 2),
          'each physical EEPROM session reopens and restores the prepared voltage');
      end
      else
      begin
        Check(Outcome.Status = osFailed, 'EEPROM fault cannot produce PASS: ' + IntToStr(Mode));
        Check(not Outcome.FreshSessionVerifyCompleted,
          'failed EEPROM verification is never marked complete');
      end;
      Check((Hardware.Closes = Hardware.Opens) and
        (Hardware.BusEnds = Hardware.BusStarts), 'every EEPROM hardware session is released');
      if Mode = 1 then
        Check(Chip.WritePagesDone = 0, 'changed full-chip preimage blocks every EEPROM write');
      if Mode = 3 then
        Check(Outcome.ErrorCode = oeVerifyMismatch, 'corruption visible only after reopening is detected');
      if Mode = 4 then
        Check(Hardware.OpenAttempts = 1, 'failed EEPROM cleanup prevents a second session');
    finally
      Executor.Free;
      Session.Free;
      Hardware.Free;
    end;
  end;
end;

procedure TestPreparedAndRecovery;
var
  Request: TOperationRequest;
  Geometry, ChangedGeometry: TNORGeometry;
  Snapshot, Patch, Live, Desired, CopyData: TBytes;
  Job, Recovery, Refused: TPreparedNORWrite;
  Chip: TVirtualSPI25;
  Outcome: TOperationOutcome;
  Header: TJournalHeader;
  Err, JournalPath, Dir, BackupPath: string;
  I: integer;
  G: TGUID;
begin
  CreateGUID(G);
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'write-recovery-' + GUIDToString(G);
  ForceDirectories(Dir);
  BackupPath := IncludeTrailingPathDelimiter(Dir) + 'original.bin';
  Job := nil;
  Recovery := nil;
  Refused := nil;
  Chip := nil;
  InitOperationRequest(Request);
  Request.OperationID := 'recovery-fixture';
  Request.Kind := okProgram;
  Request.Chip.Name := 'virtual';
  Request.Chip.JedecID := 'EF4014';
  Request.Chip.UniqueID := '0123456789ABCDEF';
  Request.Chip.Capacity := 8192;
  Request.Target.Address := 300;
  Request.Target.Length := 2;
  Request.Policy.RequireEvidenceCommit := False;
  SetLength(Snapshot, 8192);
  for I := 0 to High(Snapshot) do Snapshot[I] := byte(I mod 251);
  Patch := BytesOf(#$FF#$A5);
  Desired := Copy(Snapshot);
  Move(Patch[0], Desired[300], Length(Patch));
  Check(BuildUniformNORGeometry(8192, 256, 4096, $20, Geometry, Err), Err);
  try
    Check(TPreparedNORWrite.Prepare(Request, Geometry, Snapshot, Patch,
      'fixture', Job, Err), Err);
    if Job = nil then Exit;
    CopyData := Job.Snapshot;
    CopyData[0] := CopyData[0] xor $FF;
    Check(Job.Snapshot[0] = Snapshot[0], 'snapshot getters do not leak ownership');
    Patch[0] := 0;
    Check(Job.Patch[0] = $FF, 'caller mutation cannot change the owned image');
    Check(AtomicWriteDurable(BackupPath, Snapshot, False, Err), Err);
    Check(SaveRecoveryInputs(BackupPath, Job, 'test', JournalPath, Err), Err);

    // Cable loss after erase: untouched neighbours must come from the original
    // backup, never from this damaged snapshot or from completed journal marks.
    Live := Copy(Snapshot);
    FillChar(Live[0], 4096, $FF);
    Check(PrepareRecovery(JournalPath, Request, Geometry, Live, 'recover',
      Recovery, Header, Err), Err);
    if Recovery = nil then Exit;
    Chip := TVirtualSPI25.Create(Geometry, Live);
    Outcome := Recovery.Execute(Chip, 'recover', DefaultNORExecutorOptions);
    Check(Outcome.Status = osSucceeded, Outcome.ErrorText);
    Check(Outcome.FreshSessionVerifyCompleted,
      'recovery completes only after verification in a reopened session');
    CopyData := Chip.Snapshot;
    Check((Length(CopyData) = Length(Desired)) and
      CompareMem(@CopyData[0], @Desired[0], Length(Desired)),
      'recovery restores the patch and every erased neighbour');
    Outcome := Recovery.Execute(Chip, 'recover', DefaultNORExecutorOptions);
    Check(Outcome.Status = osFailed, 'a prepared job is consumed exactly once');

    // A retry may itself be interrupted. Completed marks never substitute
    // for rereading the live chip or for the original preserved bytes.
    Recovery.Free;
    Recovery := nil;
    Live := Copy(Desired);
    FillChar(Live[0], 4096, $FF);
    Check(PrepareRecovery(JournalPath, Request, Geometry, Live, 'retry',
      Recovery, Header, Err), 'an interrupted recovery can be prepared again: ' + Err);
    CopyData := Recovery.Patch;
    Check(CompareMem(@CopyData[0], @Desired[0], Length(Desired)),
      'a recovery retry still reconstructs original untouched neighbours');
    Recovery.Free;
    Recovery := nil;
    Check(PrepareRecovery(JournalPath, Request, Geometry, Desired, 'already-written',
      Recovery, Header, Err), Err);
    Check(not NORPlanHasDestructiveSteps(Recovery.Plan),
      'an already completed image needs verification only');
    Chip.Free;
    Chip := TVirtualSPI25.Create(Geometry, Desired);
    Outcome := Recovery.Execute(Chip, 'already-written', DefaultNORExecutorOptions);
    Check((Outcome.Status = osSucceeded) and Outcome.FreshSessionVerifyCompleted,
      'already-written recovery still verifies in a fresh session');

    Check(AtomicWriteDurable(BackupPath, BytesOf('tampered'), True, Err), Err);
    Check(not PrepareRecovery(JournalPath, Request, Geometry, Live, 'recover',
      Refused, Header, Err), 'a changed original backup is refused');
    Check(AtomicWriteDurable(BackupPath, Snapshot, True, Err), Err);
    Request.Chip.JedecID := 'EF4015';
    Check(not PrepareRecovery(JournalPath, Request, Geometry, Live, 'recover',
      Refused, Header, Err), 'a changed chip ID is refused');
    Request.Chip.JedecID := 'EF4014';
    Request.Chip.UniqueID := 'DIFFERENT';
    Check(not PrepareRecovery(JournalPath, Request, Geometry, Live, 'recover',
      Refused, Header, Err), 'a different physical UID is refused');
    Request.Chip.UniqueID := '0123456789ABCDEF';
    ChangedGeometry := Geometry;
    ChangedGeometry.Blocks := Copy(Geometry.Blocks);
    ChangedGeometry.Blocks[0].Opcode := $21;
    Check(not PrepareRecovery(JournalPath, Request, ChangedGeometry, Live,
      'recover', Refused, Header, Err), 'a changed address/erase strategy is refused');
    CopyData := BytesOf('tampered');
    Check(AtomicWriteDurable(JournalPath + '.image', CopyData, True, Err), Err);
    Check(not PrepareRecovery(JournalPath, Request, Geometry, Live, 'recover',
      Refused, Header, Err), 'a changed saved image is refused');
  finally
    Refused.Free;
    Recovery.Free;
    Job.Free;
    Chip.Free;
    DeleteFile(JournalPath + '.image');
    DeleteFile(JournalPath);
    DeleteFile(BackupPath);
    RemoveDir(Dir);
  end;
end;

begin
  TestGate;
  TestEEPROMSessions;
  TestPreparedAndRecovery;
  WriteLn(Assertions, ' assertions, ', Failures, ' failures');
  if Failures > 0 then Halt(1);
  WriteLn('ALL PASSED');
end.
