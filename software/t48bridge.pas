unit t48bridge;

// Read-only XGecu T48 seam through a separately installed minipro command.
// This unit contains no minipro implementation or device database.  It only
// constructs documented argv vectors and validates the external tool's text
// and file results.  Deliberately absent: erase, write, firmware-update,
// auto-detect and raw-command builders.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, processrunner;

const
  T48_MINIPRO_MIN_VERSION = '0.7.4';
  T48_DEFAULT_TIMEOUT_MS = QWord(10 * 60 * 1000);

type
  TT48BridgeError = (
    tbeNone,
    tbeInvalidDeviceName,
    tbeInvalidSize,
    tbeToolUnavailable,
    tbeUnsupportedToolVersion,
    tbeTimeout,
    tbeCancelled,
    tbeBusy,
    tbeRunnerFailure,
    tbeCommandRefused,
    tbeProcessOutputLimit,
    tbeToolFailed,
    tbeMalformedOutput,
    tbeProgrammerNotFound,
    tbeWrongProgrammer,
    tbeDeviceNotSupported,
    tbeDeviceMismatch,
    tbeMalformedDeviceInfo,
    tbeChipIDMismatch,
    tbeReadOutputMissing,
    tbeReadOutputStale,
    tbeReadOutputSizeMismatch,
    tbeReadOutputIO,
    tbeTempCleanupFailed,
    tbeVerifyInputMissing,
    tbeVerifyInputIO,
    tbeVerifyInputSizeMismatch,
    tbeVerificationMismatch
  );

  TT48RunOptions = record
    TimeoutMS: QWord;
    OutputLimitPolicy: TProcessOutputLimitPolicy;
    // In-child cancellation may terminate minipro.  This separate callback
    // is sampled only after one invocation has completed and before the next
    // adapter step starts.
    BetweenStepCancelCheck: TProcessCancelCheck;
    CancelCheck: TProcessCancelCheck;
    WaitPump: TProcessWaitPump;
  end;

  TT48BridgeResult = record
    Error: TT48BridgeError;
    ErrorText: string;
    ExitCode: LongInt;
    ToolVersion: string;
    Programmer: string;
    DeviceName: string;
    PackageName: string;
    ChipID: string;
    CapacityBytes: QWord;
    Data: TBytes;
  end;

  TT48Bridge = class
  private
    FRunner: IProcessRunner;
    FExecutable: string;
    function Execute(const Arguments: array of string;
      const Options: TT48RunOptions; out ProcessResult: TProcessRunResult;
      out BridgeResult: TT48BridgeResult): boolean;
    function ValidateOperationInput(const ExactDeviceName: string;
      out DevicePart, PackagePart: string;
      out BridgeResult: TT48BridgeResult): boolean;
  public
    constructor Create(const Runner: IProcessRunner;
      const Executable: string);

    function CheckTool: TT48BridgeResult; overload;
    function CheckTool(const Options: TT48RunOptions): TT48BridgeResult;
      overload;
    function CheckProgrammer: TT48BridgeResult; overload;
    function CheckProgrammer(
      const Options: TT48RunOptions): TT48BridgeResult; overload;
    function GetDeviceInfo(
      const ExactDeviceName: string): TT48BridgeResult; overload;
    function GetDeviceInfo(const ExactDeviceName: string;
      const Options: TT48RunOptions): TT48BridgeResult; overload;
    function ReadChipID(
      const ExactDeviceName: string): TT48BridgeResult; overload;
    function ReadChipID(const ExactDeviceName: string;
      const Options: TT48RunOptions): TT48BridgeResult; overload;
    function ReadChip(const ExactDeviceName: string;
      ExpectedSize: QWord): TT48BridgeResult; overload;
    function ReadChip(const ExactDeviceName: string; ExpectedSize: QWord;
      const Options: TT48RunOptions): TT48BridgeResult; overload;
    function VerifyChip(const ExactDeviceName, InputFile: string;
      ExpectedSize: QWord): TT48BridgeResult; overload;
    function VerifyChip(const ExactDeviceName, InputFile: string;
      ExpectedSize: QWord;
      const Options: TT48RunOptions): TT48BridgeResult; overload;
    function VerifyChipData(const ExactDeviceName: string;
      const Data: TBytes; ExpectedSize: QWord): TT48BridgeResult; overload;
    function VerifyChipData(const ExactDeviceName: string;
      const Data: TBytes; ExpectedSize: QWord;
      const Options: TT48RunOptions): TT48BridgeResult; overload;
  end;

procedure InitT48RunOptions(out Options: TT48RunOptions);
procedure InitT48BridgeResult(out ResultValue: TT48BridgeResult);
function ValidateT48DeviceName(const Value: string;
  out DevicePart, PackagePart, ErrorText: string): boolean;
function NormalizeT48ChipID(const Value: string;
  out Canonical: string): boolean;
function T48ChipIDsEqual(const Expected, Actual: string;
  out CanonicalExpected, CanonicalActual: string): boolean;

implementation

{$ifdef UNIX}
uses
  BaseUnix;
{$endif}

const
  FILE_TIME_TOLERANCE_DAYS = 3.0 / 86400.0;

var
  TempSequence: LongInt = 0;

procedure InitT48RunOptions(out Options: TT48RunOptions);
begin
  Options := Default(TT48RunOptions);
  Options.TimeoutMS := T48_DEFAULT_TIMEOUT_MS;
  Options.OutputLimitPolicy := polWaitForNaturalExit;
end;

procedure InitT48BridgeResult(out ResultValue: TT48BridgeResult);
begin
  ResultValue := Default(TT48BridgeResult);
  ResultValue.Error := tbeNone;
  ResultValue.ExitCode := -1;
end;

function NormalizeT48ChipID(const Value: string;
  out Canonical: string): boolean;
var
  S: string;
  I, FirstSignificant: SizeInt;
begin
  Result := False;
  Canonical := '';
  S := Trim(Value);
  if (S = '') or (Length(S) > 8) then Exit;
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
  S := UpperCase(S);
  FirstSignificant := 1;
  while (FirstSignificant < Length(S)) and
        (S[FirstSignificant] = '0') do
    Inc(FirstSignificant);
  Canonical := Copy(S, FirstSignificant, MaxInt);
  Result := Canonical <> '';
end;

function T48ChipIDsEqual(const Expected, Actual: string;
  out CanonicalExpected, CanonicalActual: string): boolean;
begin
  CanonicalExpected := '';
  CanonicalActual := '';
  Result := NormalizeT48ChipID(Expected, CanonicalExpected) and
    NormalizeT48ChipID(Actual, CanonicalActual) and
    (CanonicalExpected = CanonicalActual);
end;

function IsNameCharacter(C: char): boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '0'..'9']) or
    (C in ['-', '_', '.', '+', '/', '(', ')']);
end;

function IsPackageCharacter(C: char): boolean;
begin
  Result := (C in ['A'..'Z', 'a'..'z', '0'..'9']) or
    (C in ['-', '_', '.', '+']);
end;

function ValidateT48DeviceName(const Value: string;
  out DevicePart, PackagePart, ErrorText: string): boolean;
var
  I, Separator: SizeInt;
begin
  Result := False;
  DevicePart := '';
  PackagePart := '';
  ErrorText := '';
  if (Value = '') or (Length(Value) > 160) then
  begin
    ErrorText := 'device/package name must contain from 1 through 160 characters';
    Exit;
  end;
  if Value <> Trim(Value) then
  begin
    ErrorText := 'device/package name must not have surrounding whitespace';
    Exit;
  end;
  Separator := Pos('@', Value);
  if (Separator <= 1) or (Separator >= Length(Value)) or
     (Pos('@', Copy(Value, Separator + 1, MaxInt)) > 0) then
  begin
    ErrorText := 'use one exact minipro NAME@PACKAGE identifier';
    Exit;
  end;
  DevicePart := Copy(Value, 1, Separator - 1);
  PackagePart := Copy(Value, Separator + 1, MaxInt);
  for I := 1 to Length(DevicePart) do
    if not IsNameCharacter(DevicePart[I]) then
    begin
      ErrorText := 'device name contains an unsupported character';
      DevicePart := '';
      PackagePart := '';
      Exit;
    end;
  for I := 1 to Length(PackagePart) do
    if not IsPackageCharacter(PackagePart[I]) then
    begin
      ErrorText := 'package name contains an unsupported character';
      DevicePart := '';
      PackagePart := '';
      Exit;
    end;
  Result := True;
end;

procedure SetBridgeError(var R: TT48BridgeResult; Error: TT48BridgeError;
  const ErrorText: string);
begin
  R.Error := Error;
  R.ErrorText := ErrorText;
end;

function CombinedOutput(const R: TProcessRunResult): string;
begin
  Result := R.StdOutText;
  if (Result <> '') and (R.StdErrText <> '') and
     not (Result[Length(Result)] in [#10, #13]) then
    Result := Result + LineEnding;
  Result := Result + R.StdErrText;
end;

procedure LoadNonEmptyLines(const Text: string; Lines: TStrings);
var
  Raw: TStringList;
  I: SizeInt;
  Line: string;
begin
  Lines.Clear;
  Raw := TStringList.Create;
  try
    Raw.Text := StringReplace(Text, #13#10, #10, [rfReplaceAll]);
    for I := 0 to Raw.Count - 1 do
    begin
      Line := Trim(Raw[I]);
      if Line <> '' then Lines.Add(Line);
    end;
  finally
    Raw.Free;
  end;
end;

function FindUniquePrefixedLine(Lines: TStrings; const Prefix: string;
  out Value: string): boolean;
var
  I, Found: SizeInt;
begin
  Value := '';
  Found := 0;
  for I := 0 to Lines.Count - 1 do
    if Copy(Lines[I], 1, Length(Prefix)) = Prefix then
    begin
      Inc(Found);
      Value := Copy(Lines[I], Length(Prefix) + 1, MaxInt);
    end;
  Result := Found = 1;
end;

function ParseVersionNumber(const Value: string;
  out MajorValue, MinorValue, PatchValue: QWord): boolean;
var
  FirstDot, SecondDot: SizeInt;
  A, B, C: string;
begin
  Result := False;
  MajorValue := 0;
  MinorValue := 0;
  PatchValue := 0;
  FirstDot := Pos('.', Value);
  if FirstDot <= 1 then Exit;
  SecondDot := Pos('.', Copy(Value, FirstDot + 1, MaxInt));
  if SecondDot <= 0 then Exit;
  Inc(SecondDot, FirstDot);
  if (SecondDot >= Length(Value)) or
     (Pos('.', Copy(Value, SecondDot + 1, MaxInt)) > 0) then Exit;
  A := Copy(Value, 1, FirstDot - 1);
  B := Copy(Value, FirstDot + 1, SecondDot - FirstDot - 1);
  C := Copy(Value, SecondDot + 1, MaxInt);
  Result := TryStrToQWord(A, MajorValue) and
    TryStrToQWord(B, MinorValue) and TryStrToQWord(C, PatchValue);
end;

function SupportedVersion(const Value: string): boolean;
var
  A, B, C: QWord;
begin
  Result := ParseVersionNumber(Value, A, B, C) and
    ((A > 0) or (B > 7) or ((B = 7) and (C >= 4)));
end;

function ParseToolVersion(const Text: string; out Version: string): boolean;
var
  Lines: TStringList;
  Tail: string;
  P: SizeInt;
  MajorValue, MinorValue, PatchValue: QWord;
begin
  Version := '';
  Lines := TStringList.Create;
  try
    LoadNonEmptyLines(Text, Lines);
    Result := FindUniquePrefixedLine(Lines, 'minipro version ', Tail);
    if not Result then Exit;
    P := Pos(' ', Tail);
    if P > 0 then Version := Copy(Tail, 1, P - 1) else Version := Tail;
    Result := ParseVersionNumber(Version, MajorValue, MinorValue, PatchValue);
  finally
    Lines.Free;
  end;
end;

function ContainsTextCaseSensitive(const Text, Needle: string): boolean;
begin
  Result := Pos(Needle, Text) > 0;
end;

function ParseLiveT48(const Text: string; out Error: TT48BridgeError;
  out ErrorText: string): boolean;
var
  Lines: TStringList;
  I, FoundLines: SizeInt;
  Line: string;
begin
  Result := False;
  Error := tbeMalformedOutput;
  ErrorText := 'minipro output did not identify the live programmer';
  Lines := TStringList.Create;
  try
    LoadNonEmptyLines(Text, Lines);
    FoundLines := 0;
    Line := '';
    for I := 0 to Lines.Count - 1 do
      if Copy(Lines[I], 1, 6) = 'Found ' then
      begin
        Inc(FoundLines);
        Line := Lines[I];
      end;
    if FoundLines <> 1 then
    begin
      if ContainsTextCaseSensitive(Text, 'No programmer found') or
         ContainsTextCaseSensitive(Text, '[No programmer found]') then
      begin
        Error := tbeProgrammerNotFound;
        ErrorText := 'no programmer was found';
      end;
      Exit;
    end;
    if Copy(Line, 1, 10) <> 'Found T48 ' then
    begin
      Error := tbeWrongProgrammer;
      ErrorText := 'the live programmer is not a T48';
      Exit;
    end;
    Error := tbeNone;
    ErrorText := '';
    Result := True;
  finally
    Lines.Free;
  end;
end;

function ParseChipID(const Text: string; out ChipID: string): boolean;
var
  Lines: TStringList;
  Tail, HexText: string;
  P: SizeInt;
  C: char;
begin
  Result := False;
  ChipID := '';
  Lines := TStringList.Create;
  try
    LoadNonEmptyLines(Text, Lines);
    if not FindUniquePrefixedLine(Lines, 'Chip ID: 0x', Tail) then Exit;
    P := 1;
    HexText := '';
    while P <= Length(Tail) do
    begin
      C := Tail[P];
      if not (C in ['0'..'9', 'A'..'F', 'a'..'f']) then Break;
      HexText := HexText + UpCase(C);
      Inc(P);
    end;
    if (HexText = '') or (Length(HexText) > 8) then Exit;
    if (Length(Tail) < 2) or
       (Copy(Tail, Length(Tail) - 1, 2) <> 'OK') then Exit;
    Result := NormalizeT48ChipID(HexText, ChipID);
  finally
    Lines.Free;
  end;
end;

function ParseDeviceCapacity(const Value: string;
  out Capacity: QWord): boolean;
const
  Suffix = ' Bytes';
var
  NumberText: string;
begin
  Capacity := 0;
  Result := (Length(Value) > Length(Suffix)) and
    (Copy(Value, Length(Value) - Length(Suffix) + 1,
      Length(Suffix)) = Suffix);
  if not Result then Exit;
  NumberText := Copy(Value, 1, Length(Value) - Length(Suffix));
  Result := (NumberText <> '') and TryStrToQWord(NumberText, Capacity) and
    (Capacity > 0);
end;

function NewPrivateTempLocation(const Purpose, LeafName: string;
  out DirectoryName, FileName: string): boolean;
var
  Attempt: integer;
  Sequence: LongInt;
  Guid: TGUID;
  Token: string;
begin
  Result := False;
  DirectoryName := '';
  FileName := '';
  for Attempt := 1 to 100 do
  begin
    Sequence := InterlockedIncrement(TempSequence);
    if CreateGUID(Guid) = 0 then
    begin
      Token := GUIDToString(Guid);
      Token := StringReplace(Token, '{', '', [rfReplaceAll]);
      Token := StringReplace(Token, '}', '', [rfReplaceAll]);
    end
    else
      Token := IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64) +
        '-' + IntToStr(Sequence);
    DirectoryName := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'nvramancer-t48-' + Purpose + '-' + Token;
    if not CreateDir(DirectoryName) then Continue;
    {$ifdef UNIX}
    if FpChmod(DirectoryName, 448) <> 0 then
    begin
      RemoveDir(DirectoryName);
      Continue;
    end;
    {$endif}
    FileName := IncludeTrailingPathDelimiter(DirectoryName) + LeafName;
    Exit(True);
  end;
  DirectoryName := '';
end;

function AllowedReadOnlyArguments(const Arguments: array of string): boolean;
var
  DevicePart, PackagePart, ErrorText: string;

  function ExactDeviceAt(Index: SizeInt): boolean;
  begin
    Result := (Index >= 0) and (Index < Length(Arguments)) and
      ValidateT48DeviceName(Arguments[Index], DevicePart, PackagePart,
        ErrorText);
  end;

begin
  Result :=
    ((Length(Arguments) = 1) and
      ((Arguments[0] = '-V') or (Arguments[0] = '-k'))) or
    ((Length(Arguments) = 4) and
      (Arguments[0] = '-q') and
      (Arguments[1] = 't48') and
      (Arguments[2] = '-d') and ExactDeviceAt(3)) or
    ((Length(Arguments) = 3) and
      (Arguments[0] = '-p') and ExactDeviceAt(1) and
      (Arguments[2] = '-D')) or
    ((Length(Arguments) = 6) and
      (Arguments[0] = '-p') and ExactDeviceAt(1) and
      (Arguments[2] = '-c') and
      (Arguments[3] = 'code') and
      ((Arguments[4] = '-r') or (Arguments[4] = '-m')) and
      (Arguments[5] <> ''));
end;

constructor TT48Bridge.Create(const Runner: IProcessRunner;
  const Executable: string);
begin
  inherited Create;
  FRunner := Runner;
  FExecutable := Executable;
end;

function TT48Bridge.Execute(const Arguments: array of string;
  const Options: TT48RunOptions; out ProcessResult: TProcessRunResult;
  out BridgeResult: TT48BridgeResult): boolean;
var
  Request: TProcessRunRequest;
  I: SizeInt;
begin
  InitT48BridgeResult(BridgeResult);
  InitProcessRunResult(ProcessResult);
  Result := False;
  if not AllowedReadOnlyArguments(Arguments) then
  begin
    SetBridgeError(BridgeResult, tbeCommandRefused,
      'the requested minipro argv is outside the T48 read-only allowlist');
    Exit;
  end;
  if FRunner = nil then
  begin
    SetBridgeError(BridgeResult, tbeRunnerFailure,
      'process runner is not configured');
    Exit;
  end;
  InitProcessRunRequest(Request);
  Request.Executable := FExecutable;
  SetLength(Request.Arguments, Length(Arguments));
  for I := 0 to High(Arguments) do Request.Arguments[I] := Arguments[I];
  Request.TimeoutMS := Options.TimeoutMS;
  Request.OutputLimitPolicy := Options.OutputLimitPolicy;
  Request.CancelCheck := Options.CancelCheck;
  Request.WaitPump := Options.WaitPump;
  try
    ProcessResult := FRunner.Run(Request);
  except
    on E: Exception do
    begin
      SetBridgeError(BridgeResult, tbeRunnerFailure,
        'process runner raised ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  BridgeResult.ExitCode := ProcessResult.ExitCode;
  case ProcessResult.Status of
    prsCompleted: Result := True;
    prsStartFailed:
      SetBridgeError(BridgeResult, tbeToolUnavailable,
        ProcessResult.ErrorText);
    prsTimedOut:
      SetBridgeError(BridgeResult, tbeTimeout, ProcessResult.ErrorText);
    prsCancelled:
      SetBridgeError(BridgeResult, tbeCancelled, ProcessResult.ErrorText);
    prsOutputLimit:
      SetBridgeError(BridgeResult, tbeProcessOutputLimit,
        ProcessResult.ErrorText);
  else
    SetBridgeError(BridgeResult, tbeRunnerFailure,
      ProcessResult.ErrorText);
  end;
end;

function TT48Bridge.ValidateOperationInput(const ExactDeviceName: string;
  out DevicePart, PackagePart: string;
  out BridgeResult: TT48BridgeResult): boolean;
var
  Err: string;
begin
  InitT48BridgeResult(BridgeResult);
  Result := ValidateT48DeviceName(ExactDeviceName, DevicePart,
    PackagePart, Err);
  if not Result then
    SetBridgeError(BridgeResult, tbeInvalidDeviceName, Err)
  else
  begin
    BridgeResult.DeviceName := ExactDeviceName;
    BridgeResult.PackageName := PackagePart;
  end;
end;

function TT48Bridge.CheckTool: TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := CheckTool(Options);
end;

function TT48Bridge.CheckTool(
  const Options: TT48RunOptions): TT48BridgeResult;
var
  P: TProcessRunResult;
  Version: string;
begin
  if not Execute(['-V'], Options, P, Result) then Exit;
  if P.ExitCode <> 0 then
  begin
    SetBridgeError(Result, tbeToolFailed,
      'minipro version query exited with code ' + IntToStr(P.ExitCode));
    Exit;
  end;
  if not ParseToolVersion(CombinedOutput(P), Version) then
  begin
    SetBridgeError(Result, tbeMalformedOutput,
      'could not parse the minipro version');
    Exit;
  end;
  Result.ToolVersion := Version;
  if not SupportedVersion(Version) then
    SetBridgeError(Result, tbeUnsupportedToolVersion,
      'minipro ' + T48_MINIPRO_MIN_VERSION + ' or newer is required');
end;

function TT48Bridge.CheckProgrammer: TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := CheckProgrammer(Options);
end;

function TT48Bridge.CheckProgrammer(
  const Options: TT48RunOptions): TT48BridgeResult;
var
  P: TProcessRunResult;
  Lines: TStringList;
  Line: string;
begin
  if not Execute(['-k'], Options, P, Result) then Exit;
  if P.ExitCode <> 0 then
  begin
    SetBridgeError(Result, tbeToolFailed,
      'minipro presence query exited with code ' + IntToStr(P.ExitCode));
    Exit;
  end;
  Lines := TStringList.Create;
  try
    LoadNonEmptyLines(CombinedOutput(P), Lines);
    if Lines.Count <> 1 then
    begin
      SetBridgeError(Result, tbeMalformedOutput,
        'programmer presence output was ambiguous');
      Exit;
    end;
    Line := Lines[0];
    if Line = 't48: T48' then
    begin
      Result.Programmer := 'T48';
      Exit;
    end;
    if Line = '[No programmer found]' then
      SetBridgeError(Result, tbeProgrammerNotFound,
        'no programmer was found')
    else if (Line = 'tl866a: TL866A') or (Line = 'tl866a: TL866CS') or
            (Line = 'tl866ii: TL866II+') or (Line = 't56: T56') or
            (Line = 't76: T76') then
      SetBridgeError(Result, tbeWrongProgrammer,
        'the connected programmer is not a T48')
    else
      SetBridgeError(Result, tbeMalformedOutput,
        'unrecognized programmer presence output');
  finally
    Lines.Free;
  end;
end;

function TT48Bridge.GetDeviceInfo(
  const ExactDeviceName: string): TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := GetDeviceInfo(ExactDeviceName, Options);
end;

function TT48Bridge.GetDeviceInfo(const ExactDeviceName: string;
  const Options: TT48RunOptions): TT48BridgeResult;
var
  DevicePart, PackagePart, Name, MemoryText, Availability: string;
  P: TProcessRunResult;
  Lines: TStringList;
begin
  if not ValidateOperationInput(ExactDeviceName, DevicePart, PackagePart,
    Result) then Exit;
  if not Execute(['-q', 't48', '-d', ExactDeviceName], Options, P,
    Result) then Exit;
  Result.DeviceName := ExactDeviceName;
  Result.PackageName := PackagePart;
  if P.ExitCode <> 0 then
  begin
    SetBridgeError(Result, tbeDeviceNotSupported,
      'minipro did not accept the exact T48 device/package entry');
    Exit;
  end;
  Lines := TStringList.Create;
  try
    LoadNonEmptyLines(CombinedOutput(P), Lines);
    if not FindUniquePrefixedLine(Lines, 'Name: ', Name) then
    begin
      SetBridgeError(Result, tbeMalformedDeviceInfo,
        'device information has no unique name');
      Exit;
    end;
    if Name <> ExactDeviceName then
    begin
      SetBridgeError(Result, tbeDeviceMismatch,
        'minipro returned a different device/package entry');
      Exit;
    end;
    if not FindUniquePrefixedLine(Lines, 'Memory: ', MemoryText) or
       not ParseDeviceCapacity(MemoryText, Result.CapacityBytes) then
    begin
      SetBridgeError(Result, tbeMalformedDeviceInfo,
        'device information has no unambiguous byte capacity');
      Exit;
    end;
    if not FindUniquePrefixedLine(Lines, 'Available on: ', Availability) or
       (Pos('T48', Availability) = 0) then
    begin
      SetBridgeError(Result, tbeDeviceNotSupported,
        'the exact device/package entry is not available on T48');
      Exit;
    end;
  finally
    Lines.Free;
  end;
end;

function TT48Bridge.ReadChipID(
  const ExactDeviceName: string): TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := ReadChipID(ExactDeviceName, Options);
end;

function TT48Bridge.ReadChipID(const ExactDeviceName: string;
  const Options: TT48RunOptions): TT48BridgeResult;
var
  DevicePart, PackagePart, Text, ErrText: string;
  P: TProcessRunResult;
  Err: TT48BridgeError;
begin
  if not ValidateOperationInput(ExactDeviceName, DevicePart, PackagePart,
    Result) then Exit;
  if not Execute(['-p', ExactDeviceName, '-D'], Options, P, Result) then Exit;
  Result.DeviceName := ExactDeviceName;
  Result.PackageName := PackagePart;
  Text := CombinedOutput(P);
  if not ParseLiveT48(Text, Err, ErrText) then
  begin
    SetBridgeError(Result, Err, ErrText);
    Exit;
  end;
  Result.Programmer := 'T48';
  if P.ExitCode <> 0 then
  begin
    if ContainsTextCaseSensitive(Text, 'Chip ID mismatch:') or
       ContainsTextCaseSensitive(Text, 'Invalid Chip ID:') then
      SetBridgeError(Result, tbeChipIDMismatch,
        'the live chip ID does not match the exact device entry')
    else
      SetBridgeError(Result, tbeToolFailed,
        'minipro chip-ID query exited with code ' + IntToStr(P.ExitCode));
    Exit;
  end;
  if not ParseChipID(Text, Result.ChipID) then
    SetBridgeError(Result, tbeMalformedOutput,
      'minipro did not report one successful chip ID');
end;

function TT48Bridge.ReadChip(const ExactDeviceName: string;
  ExpectedSize: QWord): TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := ReadChip(ExactDeviceName, ExpectedSize, Options);
end;

function TT48Bridge.ReadChip(const ExactDeviceName: string;
  ExpectedSize: QWord; const Options: TT48RunOptions): TT48BridgeResult;
var
  DevicePart, PackagePart, TempDirectory, TempName, Text, ErrText: string;
  P: TProcessRunResult;
  Err: TT48BridgeError;
  StartedAt, FileTime: TDateTime;
  Stream: TFileStream;
  CleanupFailed: boolean;
begin
  if not ValidateOperationInput(ExactDeviceName, DevicePart, PackagePart,
    Result) then Exit;
  if (ExpectedSize = 0) or (ExpectedSize > QWord(High(SizeInt))) then
  begin
    SetBridgeError(Result, tbeInvalidSize,
      'expected chip size does not fit this process');
    Exit;
  end;
  if not NewPrivateTempLocation('read', 'read.bin', TempDirectory,
    TempName) then
  begin
    SetBridgeError(Result, tbeReadOutputIO,
      'could not reserve a unique read-output name');
    Exit;
  end;
  CleanupFailed := False;
  StartedAt := Now;
  try
    if not Execute(['-p', ExactDeviceName, '-c', 'code', '-r', TempName],
      Options, P, Result) then Exit;
    Result.DeviceName := ExactDeviceName;
    Result.PackageName := PackagePart;
    Text := CombinedOutput(P);
    if not ParseLiveT48(Text, Err, ErrText) then
    begin
      SetBridgeError(Result, Err, ErrText);
      Exit;
    end;
    Result.Programmer := 'T48';
    if P.ExitCode <> 0 then
    begin
      if ContainsTextCaseSensitive(Text, 'Chip ID mismatch:') or
         ContainsTextCaseSensitive(Text, 'Invalid Chip ID:') then
        SetBridgeError(Result, tbeChipIDMismatch,
          'the live chip ID does not match the exact device entry')
      else
        SetBridgeError(Result, tbeToolFailed,
          'minipro read exited with code ' + IntToStr(P.ExitCode));
      Exit;
    end;
    if not ParseChipID(Text, Result.ChipID) then
    begin
      SetBridgeError(Result, tbeMalformedOutput,
        'minipro read did not report one successful chip ID');
      Exit;
    end;
    if not FileExists(TempName) then
    begin
      SetBridgeError(Result, tbeReadOutputMissing,
        'minipro reported success without a read-output file');
      Exit;
    end;
    if not FileAge(TempName, FileTime) then
    begin
      SetBridgeError(Result, tbeReadOutputIO,
        'could not inspect the read-output timestamp');
      Exit;
    end;
    if FileTime < StartedAt - FILE_TIME_TOLERANCE_DAYS then
    begin
      SetBridgeError(Result, tbeReadOutputStale,
        'minipro read-output file is older than this read');
      Exit;
    end;
    try
      Stream := TFileStream.Create(TempName, fmOpenRead or fmShareDenyWrite);
      try
        if QWord(Stream.Size) <> ExpectedSize then
        begin
          SetBridgeError(Result, tbeReadOutputSizeMismatch,
            'read output size does not equal the declared chip capacity');
          Exit;
        end;
        SetLength(Result.Data, SizeInt(ExpectedSize));
        if ExpectedSize > 0 then
          Stream.ReadBuffer(Result.Data[0], SizeInt(ExpectedSize));
        if QWord(Stream.Size) <> ExpectedSize then
        begin
          Result.Data := nil;
          SetBridgeError(Result, tbeReadOutputSizeMismatch,
            'read output changed while it was being loaded');
          Exit;
        end;
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        Result.Data := nil;
        SetBridgeError(Result, tbeReadOutputIO,
          'could not load read output: ' + E.ClassName + ': ' + E.Message);
        Exit;
      end;
    end;
  finally
    if FileExists(TempName) and not DeleteFile(TempName) then
      CleanupFailed := True;
    if DirectoryExists(TempDirectory) and not RemoveDir(TempDirectory) then
      CleanupFailed := True;
    if CleanupFailed then
    begin
      Result.Data := nil;
      if Result.Error = tbeNone then
        SetBridgeError(Result, tbeTempCleanupFailed,
          'could not remove the temporary full-chip read file')
      else
        Result.ErrorText := Result.ErrorText +
          '; temporary full-chip read cleanup also failed';
    end;
  end;
end;

function TT48Bridge.VerifyChip(const ExactDeviceName, InputFile: string;
  ExpectedSize: QWord): TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := VerifyChip(ExactDeviceName, InputFile, ExpectedSize, Options);
end;

function TT48Bridge.VerifyChip(const ExactDeviceName, InputFile: string;
  ExpectedSize: QWord;
  const Options: TT48RunOptions): TT48BridgeResult;
var
  DevicePart, PackagePart, Text, ErrText: string;
  P: TProcessRunResult;
  Err: TT48BridgeError;
  Stream: TFileStream;
begin
  if not ValidateOperationInput(ExactDeviceName, DevicePart, PackagePart,
    Result) then Exit;
  if (ExpectedSize = 0) or (ExpectedSize > QWord(High(SizeInt))) then
  begin
    SetBridgeError(Result, tbeInvalidSize,
      'expected chip size does not fit this process');
    Exit;
  end;
  if not FileExists(InputFile) then
  begin
    SetBridgeError(Result, tbeVerifyInputMissing,
      'verification input file does not exist');
    Exit;
  end;
  try
    Stream := TFileStream.Create(InputFile, fmOpenRead or fmShareDenyNone);
    try
      if QWord(Stream.Size) <> ExpectedSize then
      begin
        SetBridgeError(Result, tbeVerifyInputSizeMismatch,
          'verification input size does not equal the declared chip capacity');
        Exit;
      end;
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      SetBridgeError(Result, tbeVerifyInputMissing,
        'could not inspect verification input: ' + E.ClassName + ': ' +
        E.Message);
      Exit;
    end;
  end;
  if not Execute(['-p', ExactDeviceName, '-c', 'code', '-m', InputFile],
    Options, P, Result) then Exit;
  Result.DeviceName := ExactDeviceName;
  Result.PackageName := PackagePart;
  Text := CombinedOutput(P);
  if not ParseLiveT48(Text, Err, ErrText) then
  begin
    SetBridgeError(Result, Err, ErrText);
    Exit;
  end;
  Result.Programmer := 'T48';
  if P.ExitCode <> 0 then
  begin
    if ContainsTextCaseSensitive(Text, 'Verification failed') then
      SetBridgeError(Result, tbeVerificationMismatch,
        'the live chip does not match the verification input')
    else if ContainsTextCaseSensitive(Text, 'Chip ID mismatch:') or
            ContainsTextCaseSensitive(Text, 'Invalid Chip ID:') then
      SetBridgeError(Result, tbeChipIDMismatch,
        'the live chip ID does not match the exact device entry')
    else
      SetBridgeError(Result, tbeToolFailed,
        'minipro verify exited with code ' + IntToStr(P.ExitCode));
    Exit;
  end;
  if not ParseChipID(Text, Result.ChipID) then
  begin
    SetBridgeError(Result, tbeMalformedOutput,
      'minipro verify did not report one successful chip ID');
    Exit;
  end;
  if not ContainsTextCaseSensitive(Text, 'Verification OK') then
    SetBridgeError(Result, tbeMalformedOutput,
      'minipro did not report successful verification');
end;

function TT48Bridge.VerifyChipData(const ExactDeviceName: string;
  const Data: TBytes; ExpectedSize: QWord): TT48BridgeResult;
var
  Options: TT48RunOptions;
begin
  InitT48RunOptions(Options);
  Result := VerifyChipData(ExactDeviceName, Data, ExpectedSize, Options);
end;

function TT48Bridge.VerifyChipData(const ExactDeviceName: string;
  const Data: TBytes; ExpectedSize: QWord;
  const Options: TT48RunOptions): TT48BridgeResult;
var
  DevicePart, PackagePart, TempDirectory, TempName: string;
  Stream: TFileStream;
  Snapshot: TBytes;
  CleanupFailed: boolean;
begin
  if not ValidateOperationInput(ExactDeviceName, DevicePart, PackagePart,
    Result) then Exit;
  if (ExpectedSize = 0) or (ExpectedSize > QWord(High(SizeInt))) then
  begin
    SetBridgeError(Result, tbeInvalidSize,
      'expected chip size does not fit this process');
    Exit;
  end;
  if QWord(Length(Data)) <> ExpectedSize then
  begin
    SetBridgeError(Result, tbeVerifyInputSizeMismatch,
      'verification data size does not equal the declared chip capacity');
    Exit;
  end;
  if not NewPrivateTempLocation('verify', 'verify.bin', TempDirectory,
    TempName) then
  begin
    SetBridgeError(Result, tbeVerifyInputIO,
      'could not reserve a private verification-input location');
    Exit;
  end;

  Snapshot := nil;
  CleanupFailed := False;
  try
    try
      Snapshot := Copy(Data);
    except
      on E: Exception do
      begin
        SetBridgeError(Result, tbeVerifyInputIO,
          'could not snapshot the private verification input: ' +
          E.ClassName + ': ' + E.Message);
        Exit;
      end;
    end;
    try
      Stream := TFileStream.Create(TempName, fmCreate or fmShareExclusive);
      try
        if Length(Snapshot) > 0 then
          Stream.WriteBuffer(Snapshot[0], Length(Snapshot));
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        SetBridgeError(Result, tbeVerifyInputIO,
          'could not create the private verification input: ' +
          E.ClassName + ': ' + E.Message);
        Exit;
      end;
    end;
    Result := VerifyChip(ExactDeviceName, TempName, ExpectedSize, Options);
  finally
    Snapshot := nil;
    if FileExists(TempName) and not DeleteFile(TempName) then
      CleanupFailed := True;
    if DirectoryExists(TempDirectory) and not RemoveDir(TempDirectory) then
      CleanupFailed := True;
    if CleanupFailed then
    begin
      if Result.Error = tbeNone then
        SetBridgeError(Result, tbeTempCleanupFailed,
          'could not remove the private verification input')
      else
        Result.ErrorText := Result.ErrorText +
          '; private verification-input cleanup also failed';
    end;
  end;
end;

end.
