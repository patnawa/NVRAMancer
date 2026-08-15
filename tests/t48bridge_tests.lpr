program t48bridge_tests;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, processrunner, t48bridge, t48hw;

type
  TFakeOutputMode = (
    fomNone,
    fomExact,
    fomMissing,
    fomStale,
    fomShort,
    fomOversized
  );

  TFakeProcessRunner = class(TInterfacedObject, IProcessRunner)
  private
    FResponses: array of TProcessRunResult;
    FResponseIndex: SizeInt;
    function OutputArgument(const Request: TProcessRunRequest): string;
    procedure MaterializeRead(const Request: TProcessRunRequest);
    procedure CaptureVerifyInput(const Request: TProcessRunRequest);
  public
    Requests: array of TProcessRunRequest;
    OutputMode: TFakeOutputMode;
    OutputSize: SizeInt;
    VerifyInputFile: string;
    VerifyInputData: TBytes;
    LeaveVerifySidecar: boolean;
    VerifySidecarFile: string;
    function Run(const Request: TProcessRunRequest): TProcessRunResult;
    procedure Queue(const Value: TProcessRunResult);
  end;

  TCallbackProbe = class
  public
    CancelCalls: cardinal;
    PumpCalls: cardinal;
    CancelAfter: cardinal;
    function CancelRequested: boolean;
    procedure Pump;
  end;

  TReconfigureProbe = class
  public
    Hardware: TT48Hardware;
    Called: boolean;
    NestedAccepted: boolean;
    NestedResult: TT48BridgeResult;
    procedure Pump;
  end;

var
  Assertions: integer = 0;
  Failures: integer = 0;
  RequestsOutsideReadOnlyAllowlist: integer = 0;

procedure Check(const Name: string; Condition: boolean);
begin
  Inc(Assertions);
  if Condition then
    WriteLn('  ok    ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('  FAIL  ', Name);
  end;
end;

function Completed(const StdOutText, StdErrText: string;
  ExitCode: LongInt = 0): TProcessRunResult;
begin
  InitProcessRunResult(Result);
  Result.Status := prsCompleted;
  Result.ExitCode := ExitCode;
  Result.StdOutText := StdOutText;
  Result.StdErrText := StdErrText;
end;

function FailedRun(Status: TProcessRunStatus;
  const ErrorText: string): TProcessRunResult;
begin
  InitProcessRunResult(Result);
  Result.Status := Status;
  Result.ExitCode := -1;
  Result.ErrorText := ErrorText;
end;

function ValidExactDeviceArgument(const Value: string): boolean;
var
  DevicePart, PackagePart, ErrorText: string;
begin
  Result := ValidateT48DeviceName(Value, DevicePart, PackagePart, ErrorText);
end;

function ArgumentsEqual(const Request: TProcessRunRequest;
  const Expected: array of string): boolean;
var
  I: SizeInt;
begin
  Result := Length(Request.Arguments) = Length(Expected);
  if not Result then Exit;
  for I := 0 to High(Expected) do
    if Request.Arguments[I] <> Expected[I] then Exit(False);
end;

function IsAllowedReadOnlyRequest(
  const Request: TProcessRunRequest): boolean;
begin
  Result :=
    ArgumentsEqual(Request, ['-V']) or
    ArgumentsEqual(Request, ['-k']) or
    ((Length(Request.Arguments) = 4) and
      (Request.Arguments[0] = '-q') and
      (Request.Arguments[1] = 't48') and
      (Request.Arguments[2] = '-d') and
      ValidExactDeviceArgument(Request.Arguments[3])) or
    ((Length(Request.Arguments) = 3) and
      (Request.Arguments[0] = '-p') and
      ValidExactDeviceArgument(Request.Arguments[1]) and
      (Request.Arguments[2] = '-D')) or
    ((Length(Request.Arguments) = 6) and
      (Request.Arguments[0] = '-p') and
      ValidExactDeviceArgument(Request.Arguments[1]) and
      (Request.Arguments[2] = '-c') and
      (Request.Arguments[3] = 'code') and
      ((Request.Arguments[4] = '-r') or
       (Request.Arguments[4] = '-m')) and
      (Request.Arguments[5] <> ''));
end;

procedure SetRequestArguments(var Request: TProcessRunRequest;
  const Values: array of string);
var
  I: SizeInt;
begin
  SetLength(Request.Arguments, Length(Values));
  for I := 0 to High(Values) do Request.Arguments[I] := Values[I];
end;

function TFakeProcessRunner.OutputArgument(
  const Request: TProcessRunRequest): string;
var
  I: SizeInt;
begin
  Result := '';
  for I := 0 to High(Request.Arguments) - 1 do
    if Request.Arguments[I] = '-r' then
      Exit(Request.Arguments[I + 1]);
end;

procedure TFakeProcessRunner.MaterializeRead(
  const Request: TProcessRunRequest);
var
  FileName: string;
  Stream: TFileStream;
  Data: array of byte;
  I, Count: SizeInt;
  OldStamp: LongInt;
begin
  FileName := OutputArgument(Request);
  if (FileName = '') or (OutputMode in [fomNone, fomMissing]) then Exit;
  case OutputMode of
    fomShort: Count := OutputSize - 1;
    fomOversized: Count := OutputSize + 1;
  else
    Count := OutputSize;
  end;
  if Count < 0 then Count := 0;
  SetLength(Data, Count);
  for I := 0 to High(Data) do Data[I] := byte((I * 29 + 7) and $FF);
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Data) > 0 then Stream.WriteBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if OutputMode = fomStale then
  begin
    OldStamp := DateTimeToFileDate(EncodeDate(2020, 1, 2));
    FileSetDate(FileName, OldStamp);
  end;
end;

procedure TFakeProcessRunner.CaptureVerifyInput(
  const Request: TProcessRunRequest);
var
  I: SizeInt;
  Stream: TFileStream;
begin
  VerifyInputFile := '';
  VerifyInputData := nil;
  VerifySidecarFile := '';
  for I := 0 to High(Request.Arguments) - 1 do
    if Request.Arguments[I] = '-m' then
    begin
      VerifyInputFile := Request.Arguments[I + 1];
      if not FileExists(VerifyInputFile) then Exit;
      Stream := TFileStream.Create(VerifyInputFile,
        fmOpenRead or fmShareDenyNone);
      try
        SetLength(VerifyInputData, SizeInt(Stream.Size));
        if Length(VerifyInputData) > 0 then
          Stream.ReadBuffer(VerifyInputData[0], Length(VerifyInputData));
      finally
        Stream.Free;
      end;
      if LeaveVerifySidecar then
      begin
        VerifySidecarFile := IncludeTrailingPathDelimiter(
          ExtractFileDir(VerifyInputFile)) + 'unexpected.sidecar';
        Stream := TFileStream.Create(VerifySidecarFile, fmCreate);
        Stream.Free;
      end;
      Exit;
    end;
end;

function TFakeProcessRunner.Run(
  const Request: TProcessRunRequest): TProcessRunResult;
begin
  if not IsAllowedReadOnlyRequest(Request) then
    Inc(RequestsOutsideReadOnlyAllowlist);
  SetLength(Requests, Length(Requests) + 1);
  Requests[High(Requests)] := Request;
  if Assigned(Request.WaitPump) then Request.WaitPump();
  MaterializeRead(Request);
  CaptureVerifyInput(Request);
  if FResponseIndex > High(FResponses) then
    Result := Completed('', '')
  else
  begin
    Result := FResponses[FResponseIndex];
    Inc(FResponseIndex);
  end;
end;

procedure TFakeProcessRunner.Queue(const Value: TProcessRunResult);
begin
  SetLength(FResponses, Length(FResponses) + 1);
  FResponses[High(FResponses)] := Value;
end;

function TCallbackProbe.CancelRequested: boolean;
begin
  Inc(CancelCalls);
  Result := (CancelAfter > 0) and (CancelCalls >= CancelAfter);
end;

procedure TCallbackProbe.Pump;
begin
  Inc(PumpCalls);
end;

procedure TReconfigureProbe.Pump;
var
  Options: TT48RunOptions;
begin
  if Called then Exit;
  Called := True;
  Hardware.Configure('C:\replacement\minipro.exe', 'REPLACED@DIP8');
  InitT48RunOptions(Options);
  NestedAccepted := Hardware.CheckConfiguration(Options, NestedResult);
end;

procedure InitBridge(out Fake: TFakeProcessRunner;
  out Runner: IProcessRunner; out Bridge: TT48Bridge);
begin
  Fake := TFakeProcessRunner.Create;
  Runner := Fake;
  Bridge := TT48Bridge.Create(Runner, 'C:\Program Files\minipro\minipro.exe');
end;

procedure TestExactDeviceNames;
var
  DevicePart, PackagePart, Err, CanonicalA, CanonicalB: string;
begin
  WriteLn('T48 bridge: exact device/package identifiers');
  Check('exact SOIC name is accepted',
    ValidateT48DeviceName('W25Q64JV@SOIC8', DevicePart, PackagePart, Err));
  Check('device part is retained', DevicePart = 'W25Q64JV');
  Check('package part is retained', PackagePart = 'SOIC8');
  Check('missing package is refused',
    not ValidateT48DeviceName('W25Q64JV', DevicePart, PackagePart, Err));
  Check('empty device is refused',
    not ValidateT48DeviceName('@SOIC8', DevicePart, PackagePart, Err));
  Check('empty package is refused',
    not ValidateT48DeviceName('W25Q64JV@', DevicePart, PackagePart, Err));
  Check('two package separators are refused',
    not ValidateT48DeviceName('W25Q64JV@SOIC8@DIP8',
      DevicePart, PackagePart, Err));
  Check('leading whitespace is refused',
    not ValidateT48DeviceName(' W25Q64JV@SOIC8',
      DevicePart, PackagePart, Err));
  Check('embedded whitespace is refused',
    not ValidateT48DeviceName('W25 Q64JV@SOIC8',
      DevicePart, PackagePart, Err));
  Check('command punctuation is refused even though argv is direct',
    not ValidateT48DeviceName('W25Q64JV@SOIC8;erase',
      DevicePart, PackagePart, Err));
  Check('leading-zero chip ID normalizes canonically',
    NormalizeT48ChipID('010210', CanonicalA) and
    (CanonicalA = '10210'));
  Check('lowercase chip ID normalizes to uppercase',
    NormalizeT48ChipID('ef4017', CanonicalA) and
    (CanonicalA = 'EF4017'));
  Check('equivalent leading-zero chip IDs compare equal',
    T48ChipIDsEqual('010210', '10210', CanonicalA, CanonicalB) and
    (CanonicalA = '10210') and (CanonicalB = '10210'));
  Check('empty chip ID is rejected',
    not NormalizeT48ChipID('', CanonicalA));
  Check('prefixed chip ID is rejected',
    not NormalizeT48ChipID('0x10210', CanonicalA));
  Check('non-hex chip ID is rejected',
    not T48ChipIDsEqual('10210', '10Z10', CanonicalA, CanonicalB));
end;

procedure TestReadOnlyAllowlistDefinition;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Request: TProcessRunRequest;
begin
  WriteLn('T48 bridge: exact argv allowlist excludes every other command');
  InitProcessRunRequest(Request);
  SetRequestArguments(Request, ['-V']);
  Check('version query is an allowed complete shape',
    IsAllowedReadOnlyRequest(Request));
  SetRequestArguments(Request, ['-u']);
  Check('unprotect command is outside the allowlist',
    not IsAllowedReadOnlyRequest(Request));
  SetRequestArguments(Request, ['-P']);
  Check('protect command is outside the allowlist',
    not IsAllowedReadOnlyRequest(Request));
  SetRequestArguments(Request, ['-p', ExactName, '-u']);
  Check('a mutating switch cannot replace the ID action',
    not IsAllowedReadOnlyRequest(Request));
  SetRequestArguments(Request,
    ['-p', ExactName, '-c', 'code', '-m', '']);
  Check('verify requires a concrete input path',
    not IsAllowedReadOnlyRequest(Request));
end;

procedure TestToolVersion;
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
begin
  WriteLn('T48 bridge: tool availability and supported version');
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('',
      'minipro version 0.7.4     A free and open TL866 series programmer' +
      LineEnding));
    R := Bridge.CheckTool;
    Check('minimum supported version succeeds', R.Error = tbeNone);
    Check('version is parsed', R.ToolVersion = '0.7.4');
    Check('version argv is exact',
      ArgumentsEqual(Fake.Requests[0], ['-V']));
    Check('configured executable is a direct executable path',
      Fake.Requests[0].Executable =
        'C:\Program Files\minipro\minipro.exe');
  finally
    Bridge.Free;
    Runner := nil;
  end;

  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('', 'minipro version 0.7.3' + LineEnding));
    R := Bridge.CheckTool;
    Check('older tool is typed unsupported',
      R.Error = tbeUnsupportedToolVersion);
  finally
    Bridge.Free;
    Runner := nil;
  end;

  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('', 'version unknown' + LineEnding));
    R := Bridge.CheckTool;
    Check('malformed version output fails closed',
      R.Error = tbeMalformedOutput);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

procedure TestTypedProcessFailures;
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
begin
  WriteLn('T48 bridge: process failures remain typed');
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(FailedRun(prsStartFailed, 'not found'));
    R := Bridge.CheckTool;
    Check('start failure means unavailable tool',
      R.Error = tbeToolUnavailable);
    Fake.Queue(FailedRun(prsTimedOut, 'deadline'));
    R := Bridge.CheckProgrammer;
    Check('timeout is not flattened', R.Error = tbeTimeout);
    Fake.Queue(FailedRun(prsCancelled, 'operator requested'));
    R := Bridge.CheckProgrammer;
    Check('cancellation is not flattened', R.Error = tbeCancelled);
    Fake.Queue(Completed('', 'fatal', 19));
    R := Bridge.CheckProgrammer;
    Check('nonzero tool exit is typed', R.Error = tbeToolFailed);
    Check('nonzero exit code is retained', R.ExitCode = 19);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

procedure TestPresence;
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
begin
  WriteLn('T48 bridge: shared VID/PID never chooses the model');
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('', 't48: T48' + LineEnding));
    R := Bridge.CheckProgrammer;
    Check('exact live T48 is accepted', R.Error = tbeNone);
    Check('live model is retained', R.Programmer = 'T48');
    Check('presence argv is exact',
      ArgumentsEqual(Fake.Requests[0], ['-k']));

    Fake.Queue(Completed('', 't56: T56' + LineEnding));
    R := Bridge.CheckProgrammer;
    Check('T56 is rejected as the wrong programmer',
      R.Error = tbeWrongProgrammer);

    Fake.Queue(Completed('', '[No programmer found]' + LineEnding));
    R := Bridge.CheckProgrammer;
    Check('no programmer is distinct from no tool',
      R.Error = tbeProgrammerNotFound);

    Fake.Queue(Completed('', 'warning' + LineEnding +
      't48: T48' + LineEnding));
    R := Bridge.CheckProgrammer;
    Check('ambiguous multi-line presence output is refused',
      R.Error = tbeMalformedOutput);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

procedure TestDeviceInfo;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
begin
  WriteLn('T48 bridge: database facts are exact and byte-sized');
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('',
      '---------------Chip Info----------------' + LineEnding +
      'Name: ' + ExactName + LineEnding +
      'Available on: TL866II, T48, T56' + LineEnding +
      'Memory: 8388608 Bytes' + LineEnding +
      'Package: DIP8' + LineEnding));
    R := Bridge.GetDeviceInfo(ExactName);
    Check('exact database entry succeeds', R.Error = tbeNone);
    Check('exact full name is retained', R.DeviceName = ExactName);
    Check('package suffix is retained', R.PackageName = 'SOIC8');
    Check('capacity is parsed without narrowing',
      R.CapacityBytes = QWord(8388608));
    Check('device-info argv pins the T48 database',
      ArgumentsEqual(Fake.Requests[0],
        ['-q', 't48', '-d', ExactName]));

    Fake.Queue(Completed('',
      'Name: W25Q64JV@DIP8' + LineEnding +
      'Memory: 8388608 Bytes' + LineEnding));
    R := Bridge.GetDeviceInfo(ExactName);
    Check('near-name database result is rejected',
      R.Error = tbeDeviceMismatch);

    Fake.Queue(Completed('',
      'Name: ' + ExactName + LineEnding +
      'Memory: 8388608 Words' + LineEnding));
    R := Bridge.GetDeviceInfo(ExactName);
    Check('non-byte memory geometry is refused',
      R.Error = tbeMalformedDeviceInfo);

    R := Bridge.GetDeviceInfo('W25Q64JV');
    Check('invalid input is typed before launch',
      R.Error = tbeInvalidDeviceName);
    Check('invalid input launches nothing', Length(Fake.Requests) = 3);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

procedure TestLiveID;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
begin
  WriteLn('T48 bridge: live ID remains bound to a live T48');
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Device code: 44B18278' + LineEnding +
      'Serial code: REDACTED' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChipID(ExactName);
    Check('matching live ID succeeds', R.Error = tbeNone);
    Check('chip ID is canonical uppercase hex', R.ChipID = 'EF4017');
    Check('ID argv is exact',
      ArgumentsEqual(Fake.Requests[0], ['-p', ExactName, '-D']));

    Fake.Queue(Completed('',
      'Found T56 01.0.0 (0x100)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChipID(ExactName);
    Check('operation output from T56 is rejected',
      R.Error = tbeWrongProgrammer);

    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID mismatch: expected 0xEF4017, got 0xC84017' + LineEnding,
      1));
    R := Bridge.ReadChipID(ExactName);
    Check('ID mismatch is typed, not generic process failure',
      R.Error = tbeChipIDMismatch);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

procedure TestReadFiles;
const
  ExactName = 'W25Q64JV@SOIC8';
  ExpectedSize = 64;
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
  Options: TT48RunOptions;
begin
  WriteLn('T48 bridge: full-chip output must be fresh and exact');
  InitBridge(Fake, Runner, Bridge);
  try
    InitT48RunOptions(Options);
    Options.TimeoutMS := 4321;
    Fake.OutputSize := ExpectedSize;
    Fake.OutputMode := fomExact;
    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding +
      'Reading Code... 0.01Sec OK' + LineEnding));
    R := Bridge.ReadChip(ExactName, ExpectedSize, Options);
    Check('fresh exact-size read succeeds', R.Error = tbeNone);
    Check('every expected byte is returned',
      Length(R.Data) = ExpectedSize);
    Check('full read retains its live chip ID', R.ChipID = 'EF4017');
    Check('read bytes are not an empty-file success',
      (Length(R.Data) > 1) and (R.Data[0] = 7) and (R.Data[1] = 36));
    Check('timeout reaches the process boundary',
      Fake.Requests[0].TimeoutMS = 4321);
    Check('T48 defaults to natural exit after capture saturation',
      Fake.Requests[0].OutputLimitPolicy = polWaitForNaturalExit);
    Check('read argv selects code and a unique output file',
      (Length(Fake.Requests[0].Arguments) = 6) and
      (Fake.Requests[0].Arguments[0] = '-p') and
      (Fake.Requests[0].Arguments[1] = ExactName) and
      (Fake.Requests[0].Arguments[2] = '-c') and
      (Fake.Requests[0].Arguments[3] = 'code') and
      (Fake.Requests[0].Arguments[4] = '-r') and
      (Fake.Requests[0].Arguments[5] <> ''));
    Check('successful temporary read is removed',
      not FileExists(Fake.Requests[0].Arguments[5]));
    Check('private temporary read directory is removed',
      not DirectoryExists(ExtractFileDir(Fake.Requests[0].Arguments[5])));

    Fake.OutputMode := fomMissing;
    Fake.Queue(Completed('', 'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChip(ExactName, ExpectedSize);
    Check('success exit with no output is refused',
      R.Error = tbeReadOutputMissing);

    Fake.OutputMode := fomStale;
    Fake.Queue(Completed('', 'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChip(ExactName, ExpectedSize);
    Check('stale output is refused', R.Error = tbeReadOutputStale);

    Fake.OutputMode := fomShort;
    Fake.Queue(Completed('', 'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChip(ExactName, ExpectedSize);
    Check('short output is refused', R.Error = tbeReadOutputSizeMismatch);

    Fake.OutputMode := fomOversized;
    Fake.Queue(Completed('', 'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding));
    R := Bridge.ReadChip(ExactName, ExpectedSize);
    Check('oversized output is refused',
      R.Error = tbeReadOutputSizeMismatch);
  finally
    Bridge.Free;
    Runner := nil;
  end;
end;

function NewInputFile(Size: SizeInt): string;
var
  Stream: TFileStream;
  Data: array of byte;
  I: SizeInt;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'nvramancer-t48-verify-' + IntToStr(GetTickCount64) + '.bin';
  SetLength(Data, Size);
  for I := 0 to High(Data) do Data[I] := byte(I);
  Stream := TFileStream.Create(Result, fmCreate);
  try
    if Length(Data) > 0 then Stream.WriteBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
end;

procedure TestVerifyAndNoDestructiveArgv;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Bridge: TT48Bridge;
  R: TT48BridgeResult;
  FileName: string;
  I: SizeInt;
  Data: TBytes;
begin
  WriteLn('T48 bridge: independent verify is the only file-input action');
  FileName := NewInputFile(32);
  InitBridge(Fake, Runner, Bridge);
  try
    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding +
      'Verification OK' + LineEnding));
    R := Bridge.VerifyChip(ExactName, FileName, 32);
    Check('independent verify succeeds', R.Error = tbeNone);
    Check('independent verify retains its live chip ID',
      R.ChipID = 'EF4017');
    Check('verify argv is exact',
      ArgumentsEqual(Fake.Requests[0],
        ['-p', ExactName, '-c', 'code', '-m', FileName]));

    R := Bridge.VerifyChip(ExactName, FileName, 31);
    Check('wrong-size verify input is refused before launch',
      R.Error = tbeVerifyInputSizeMismatch);
    Check('wrong-size verify launches nothing', Length(Fake.Requests) = 1);

    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Verification OK' + LineEnding));
    R := Bridge.VerifyChip(ExactName, FileName, 32);
    Check('successful verify without a live ID fails closed',
      R.Error = tbeMalformedOutput);

    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding +
      'Verification failed at address 0x10' + LineEnding, 1));
    R := Bridge.VerifyChip(ExactName, FileName, 32);
    Check('verification mismatch is typed',
      R.Error = tbeVerificationMismatch);

    SetLength(Data, 32);
    for I := 0 to High(Data) do Data[I] := byte((I * 11 + 3) and $FF);
    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding +
      'Verification OK' + LineEnding));
    R := Bridge.VerifyChipData(ExactName, Data, 32);
    Check('in-memory independent verify succeeds', R.Error = tbeNone);
    Check('in-memory verify reaches minipro as exact bytes',
      (Length(Fake.VerifyInputData) = Length(Data)) and
      (CompareByte(Fake.VerifyInputData[0], Data[0], Length(Data)) = 0));
    Check('in-memory verify temporary input is removed',
      (Fake.VerifyInputFile <> '') and not FileExists(Fake.VerifyInputFile));
    Check('in-memory verify private directory is removed',
      (Fake.VerifyInputFile <> '') and
      not DirectoryExists(ExtractFileDir(Fake.VerifyInputFile)));

    Fake.LeaveVerifySidecar := True;
    Fake.Queue(Completed('',
      'Found T48 01.1.31 (0x11f)' + LineEnding +
      'Chip ID: 0xEF4017  OK' + LineEnding +
      'Verification OK' + LineEnding));
    R := Bridge.VerifyChipData(ExactName, Data, 32);
    Check('private-input cleanup failure remains typed',
      R.Error = tbeTempCleanupFailed);
    Fake.LeaveVerifySidecar := False;
    if FileExists(Fake.VerifySidecarFile) then
      DeleteFile(Fake.VerifySidecarFile);
    if DirectoryExists(ExtractFileDir(Fake.VerifySidecarFile)) then
      RemoveDir(ExtractFileDir(Fake.VerifySidecarFile));

    SetLength(Data, 31);
    R := Bridge.VerifyChipData(ExactName, Data, 32);
    Check('wrong-size in-memory verify is refused before launch',
      R.Error = tbeVerifyInputSizeMismatch);

    for I := 0 to High(Fake.Requests) do
      Check('request ' + IntToStr(I) +
        ' matches one complete read-only argv shape',
        IsAllowedReadOnlyRequest(Fake.Requests[I]));
  finally
    Bridge.Free;
    Runner := nil;
    DeleteFile(FileName);
  end;
end;

procedure TestDirectRunner;
var
  Runner: IProcessRunner;
  Request: TProcessRunRequest;
  R: TProcessRunResult;
  Probe: TCallbackProbe;
  StartedAt, Elapsed: QWord;
  MarkerName: string;
begin
  WriteLn('Process runner: direct argv, timeout, cancel and pump');
  Runner := TDirectProcessRunner.Create;
  InitProcessRunRequest(Request);
  Request.Executable := ParamStr(0);
  SetLength(Request.Arguments, 3);
  Request.Arguments[0] := '--processrunner-helper';
  Request.Arguments[1] := 'two words';
  Request.Arguments[2] := '&echo SHOULD_NOT_RUN';
  R := Runner.Run(Request);
  Check('direct helper completes', R.Status = prsCompleted);
  Check('argument containing spaces stays one argument',
    Pos('ARG=two words', R.StdOutText) > 0);
  Check('shell punctuation is inert argument data',
    Pos('ARG=&echo SHOULD_NOT_RUN', R.StdOutText) > 0);

  InitProcessRunRequest(Request);
  Request.Executable := ParamStr(0);
  SetLength(Request.Arguments, 1);
  Request.Arguments[0] := '--processrunner-exit-helper';
  R := Runner.Run(Request);
  Check('nonzero child still completed', R.Status = prsCompleted);
  Check('nonzero child exit is exact', R.ExitCode = 23);

  InitProcessRunRequest(Request);
  Request.Executable := ParamStr(0);
  SetLength(Request.Arguments, 1);
  Request.Arguments[0] := '--processrunner-short-wait-helper';
  Request.TimeoutMS := 0;
  R := Runner.Run(Request);
  Check('zero timeout means no forced deadline',
    (R.Status = prsCompleted) and
    (Pos('UNLIMITED', R.StdOutText) > 0));

  InitProcessRunRequest(Request);
  Request.Executable := ParamStr(0);
  SetLength(Request.Arguments, 1);
  Request.Arguments[0] := '--processrunner-flood-helper';
  Request.TimeoutMS := 2000;
  Request.MaxOutputBytes := 4096;
  StartedAt := GetTickCount64;
  R := Runner.Run(Request);
  Elapsed := GetTickCount64 - StartedAt;
  Check('continuous output reaches the configured limit',
    R.Status = prsOutputLimit);
  Check('continuous output cannot starve output-limit handling',
    Elapsed < 2000);

  InitProcessRunRequest(Request);
  Request.Executable := ParamStr(0);
  SetLength(Request.Arguments, 1);
  Request.Arguments[0] := '--processrunner-wait-helper';
  Request.TimeoutMS := 50;
  R := Runner.Run(Request);
  Check('real child timeout is typed', R.Status = prsTimedOut);

  Probe := TCallbackProbe.Create;
  try
    MarkerName := NewInputFile(0);
    DeleteFile(MarkerName);
    InitProcessRunRequest(Request);
    Request.Executable := ParamStr(0);
    SetRequestArguments(Request,
      ['--processrunner-finite-flood-helper', MarkerName]);
    Request.TimeoutMS := 0;
    Request.MaxOutputBytes := 4096;
    Request.OutputLimitPolicy := polWaitForNaturalExit;
    Request.WaitPump := @Probe.Pump;
    StartedAt := GetTickCount64;
    R := Runner.Run(Request);
    Elapsed := GetTickCount64 - StartedAt;
    Check('non-terminating capture mode still reports output limit',
      R.Status = prsOutputLimit);
    Check('non-terminating capture mode lets the child reach natural exit',
      FileExists(MarkerName));
    Check('non-terminating capture remains pump-responsive while discarding',
      (Probe.PumpCalls > 0) and (Elapsed < 2000));
    DeleteFile(MarkerName);

    InitProcessRunRequest(Request);
    Request.Executable := ParamStr(0);
    SetLength(Request.Arguments, 1);
    Request.Arguments[0] := '--processrunner-flood-helper';
    Request.TimeoutMS := 120;
    Request.MaxOutputBytes := QWord(16 * 1024 * 1024);
    Request.WaitPump := @Probe.Pump;
    StartedAt := GetTickCount64;
    R := Runner.Run(Request);
    Elapsed := GetTickCount64 - StartedAt;
    Check('continuous output cannot starve timeout handling',
      (R.Status = prsTimedOut) and (Elapsed < 2000));
    Check('continuous output cannot starve the wait pump',
      Probe.PumpCalls > 0);

    Probe.CancelAfter := 2;
    InitProcessRunRequest(Request);
    Request.Executable := ParamStr(0);
    SetLength(Request.Arguments, 1);
    Request.Arguments[0] := '--processrunner-wait-helper';
    Request.TimeoutMS := 5000;
    Request.CancelCheck := @Probe.CancelRequested;
    Request.WaitPump := @Probe.Pump;
    R := Runner.Run(Request);
    Check('real child cancellation is typed', R.Status = prsCancelled);
    Check('wait pump is independent and called', Probe.PumpCalls > 0);
  finally
    Probe.Free;
  end;
end;

procedure TestHardwareAdapterFailClosed;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Hardware: TT48Hardware;
  Options: TT48RunOptions;
  R: TT48BridgeResult;
  Buffer: array[0..0] of byte;
  RequestCount: SizeInt;
begin
  WriteLn('T48 hardware adapter: raw and mutation-shaped calls launch nothing');
  Fake := TFakeProcessRunner.Create;
  Runner := Fake;
  Hardware := TT48Hardware.CreateWithRunner(Runner);
  try
    Hardware.Configure(ParamStr(0), ExactName);
    Check('test executable is accepted as an existing configured path',
      Hardware.Configured);
    Buffer[0] := $9F;
    Check('raw SPI init is refused', not Hardware.SPIInit(0));
    Check('raw SPI write is refused',
      Hardware.SPIWrite(1, 1, Buffer) = -1);
    Check('raw SPI read is refused',
      Hardware.SPIRead(1, 1, Buffer) = -1);
    Check('MicroWire init is refused', not Hardware.MWInit(0));
    Check('I2C write byte is refused', not Hardware.I2CWriteByte($AA));
    Check('unsupported raw calls launch no child process',
      Length(Fake.Requests) = 0);

    Fake.Queue(Completed('',
      'minipro version 0.7.4     A free and open TL866 series programmer' +
      LineEnding));
    Fake.Queue(Completed('',
      'Name: ' + ExactName + LineEnding +
      'Available on: TL866II, T48, T56' + LineEnding +
      'Memory: 64 Bytes' + LineEnding));
    Fake.Queue(Completed('', 't48: T48' + LineEnding));
    InitT48RunOptions(Options);
    Check('managed open validates tool, exact database entry and live model',
      Hardware.OpenWithOptions(Options, R));
    Check('managed open retains exact capacity',
      Hardware.DeviceInfo.CapacityBytes = 64);
    Check('managed open retains the validated tool version',
      Hardware.DeviceInfo.ToolVersion = '0.7.4');
    Check('managed open uses exactly three read-only process requests',
      Length(Fake.Requests) = 3);

    Hardware.DevClose;
    RequestCount := Length(Fake.Requests);
    Check('operation after close is refused',
      not Hardware.ReadChipID(Options, R));
    Check('operation after close launches nothing',
      Length(Fake.Requests) = RequestCount);
  finally
    Hardware.Free;
    Runner := nil;
  end;
end;

procedure TestHardwareReentrantConfigure;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Hardware: TT48Hardware;
  Options: TT48RunOptions;
  R: TT48BridgeResult;
  Probe: TReconfigureProbe;
begin
  WriteLn('T48 hardware adapter: reentrant configuration is fail-closed');
  Fake := TFakeProcessRunner.Create;
  Runner := Fake;
  Hardware := TT48Hardware.CreateWithRunner(Runner);
  Probe := TReconfigureProbe.Create;
  try
    Hardware.Configure(ParamStr(0), ExactName);
    Probe.Hardware := Hardware;
    Fake.Queue(Completed('',
      'minipro version 0.7.4     A free and open TL866 series programmer' +
      LineEnding));
    Fake.Queue(Completed('',
      'Name: ' + ExactName + LineEnding +
      'Available on: T48' + LineEnding +
      'Memory: 64 Bytes' + LineEnding));
    InitT48RunOptions(Options);
    Options.WaitPump := @Probe.Pump;
    Check('configuration check survives a reentrant Configure call',
      Hardware.CheckConfiguration(Options, R));
    Check('reentrant Configure callback was exercised', Probe.Called);
    Check('reentrant bridge call is rejected with a typed busy result',
      (not Probe.NestedAccepted) and
      (Probe.NestedResult.Error = tbeBusy));
    Check('in-flight tool path is immutable', Hardware.ToolPath = ParamStr(0));
    Check('in-flight exact device is immutable',
      Hardware.DeviceName = ExactName);
    Check('configuration result retains the validated tool version',
      Hardware.DeviceInfo.ToolVersion = '0.7.4');
    Check('configuration check still launches both original requests',
      Length(Fake.Requests) = 2);
    if Length(Fake.Requests) = 2 then
    begin
      Check('both in-flight launches keep the original executable',
        (Fake.Requests[0].Executable = ParamStr(0)) and
        (Fake.Requests[1].Executable = ParamStr(0)));
      Check('second in-flight launch keeps the original device',
        ArgumentsEqual(Fake.Requests[1],
          ['-q', 't48', '-d', ExactName]));
    end;
  finally
    Probe.Free;
    Hardware.Free;
    Runner := nil;
  end;
end;

procedure TestHardwareBetweenStepCancellation;
const
  ExactName = 'W25Q64JV@SOIC8';
var
  Fake: TFakeProcessRunner;
  Runner: IProcessRunner;
  Hardware: TT48Hardware;
  Options: TT48RunOptions;
  R: TT48BridgeResult;
  Probe: TCallbackProbe;
begin
  WriteLn('T48 hardware adapter: cancellation is honored between launches');
  Fake := TFakeProcessRunner.Create;
  Runner := Fake;
  Hardware := TT48Hardware.CreateWithRunner(Runner);
  Probe := TCallbackProbe.Create;
  try
    Hardware.Configure(ParamStr(0), ExactName);
    Fake.Queue(Completed('',
      'minipro version 0.7.4     A free and open TL866 series programmer' +
      LineEnding));
    InitT48RunOptions(Options);
    Probe.CancelAfter := 1;
    Options.BetweenStepCancelCheck := @Probe.CancelRequested;
    Check('configuration cancellation is typed between tool and device info',
      not Hardware.CheckConfiguration(Options, R) and
      (R.Error = tbeCancelled));
    Check('configuration cancellation prevents the second launch',
      Length(Fake.Requests) = 1);
  finally
    Probe.Free;
    Hardware.Free;
    Runner := nil;
  end;

  Fake := TFakeProcessRunner.Create;
  Runner := Fake;
  Hardware := TT48Hardware.CreateWithRunner(Runner);
  Probe := TCallbackProbe.Create;
  try
    Hardware.Configure(ParamStr(0), ExactName);
    Fake.Queue(Completed('',
      'minipro version 0.7.4     A free and open TL866 series programmer' +
      LineEnding));
    Fake.Queue(Completed('',
      'Name: ' + ExactName + LineEnding +
      'Available on: T48' + LineEnding +
      'Memory: 64 Bytes' + LineEnding));
    InitT48RunOptions(Options);
    Probe.CancelAfter := 2;
    Options.BetweenStepCancelCheck := @Probe.CancelRequested;
    Check('open cancellation is typed before programmer presence',
      not Hardware.OpenWithOptions(Options, R) and
      (R.Error = tbeCancelled));
    Check('open cancellation prevents the presence launch',
      Length(Fake.Requests) = 2);
  finally
    Probe.Free;
    Hardware.Free;
    Runner := nil;
  end;
end;

procedure RunHelperAndExit;
var
  I: integer;
  StartedAt: QWord;
  FloodLine: string;
  Marker: TFileStream;
begin
  if ParamCount = 0 then Exit;
  if ParamStr(1) = '--processrunner-helper' then
  begin
    for I := 2 to ParamCount do WriteLn('ARG=', ParamStr(I));
    Halt(0);
  end;
  if ParamStr(1) = '--processrunner-exit-helper' then Halt(23);
  if ParamStr(1) = '--processrunner-short-wait-helper' then
  begin
    Sleep(120);
    WriteLn('UNLIMITED');
    Halt(0);
  end;
  if ParamStr(1) = '--processrunner-wait-helper' then
  begin
    Sleep(5000);
    Halt(0);
  end;
  if ParamStr(1) = '--processrunner-flood-helper' then
  begin
    // A write larger than the pipe buffer keeps the producer blocked while
    // the parent drains it.  An unbounded drain loop can therefore stay in
    // that one call until this helper stops producing.
    FloodLine := StringOfChar('X', 64 * 1024);
    StartedAt := GetTickCount64;
    while GetTickCount64 - StartedAt < 3000 do
    begin
      Write(FloodLine);
      Flush(Output);
    end;
    Halt(0);
  end;
  if (ParamStr(1) = '--processrunner-finite-flood-helper') and
     (ParamCount = 2) then
  begin
    FloodLine := StringOfChar('X', 64 * 1024);
    StartedAt := GetTickCount64;
    while GetTickCount64 - StartedAt < 350 do
    begin
      Write(FloodLine);
      Flush(Output);
    end;
    Marker := TFileStream.Create(ParamStr(2), fmCreate);
    Marker.Free;
    Halt(0);
  end;
end;

begin
  RunHelperAndExit;
  TestExactDeviceNames;
  TestReadOnlyAllowlistDefinition;
  TestToolVersion;
  TestTypedProcessFailures;
  TestPresence;
  TestDeviceInfo;
  TestLiveID;
  TestReadFiles;
  TestVerifyAndNoDestructiveArgv;
  TestDirectRunner;
  TestHardwareAdapterFailClosed;
  TestHardwareReentrantConfigure;
  TestHardwareBetweenStepCancellation;
  Check('all bridge scenarios stayed inside the exact read-only allowlist',
    RequestsOutsideReadOnlyAllowlist = 0);
  WriteLn;
  WriteLn(Assertions, ' assertions, ', Failures, ' failures');
  if Failures <> 0 then Halt(1);
  WriteLn('ALL PASSED');
end.
