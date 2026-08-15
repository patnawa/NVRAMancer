unit t48hw;

// XGecu T48 selection adapter.
//
// The T48 is a managed socket programmer, not a raw SPI transport.  The
// actual protocol and device database remain in a separately installed
// minipro executable.  This class gives the application one honest hardware
// object while exposing only the read-only operations validated before the
// physical programmer arrives.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, basehw, processrunner, t48bridge;

type
  TT48Hardware = class(TBaseHardware)
  private
    FRunner: IProcessRunner;
    FBridge: TT48Bridge;
    FToolPath: string;
    FDeviceName: string;
    FLastError: string;
    FOpened: boolean;
    FDeviceInfo: TT48BridgeResult;
    FBridgeCallDepth: LongInt;
    procedure RebuildBridge;
    procedure RememberResult(const Value: TT48BridgeResult);
    function ClosedResult: TT48BridgeResult;
    function TryBeginBridgeCall(out BridgeResult: TT48BridgeResult): boolean;
    procedure EndBridgeCall;
    function ContinueBetweenSteps(const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function CheckConfigurationCore(const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
  public
    constructor Create; overload;
    constructor CreateWithRunner(const Runner: IProcessRunner); overload;
    destructor Destroy; override;

    procedure Configure(const ToolPath, ExactDeviceName: string);
    function Configured: boolean;
    function CheckConfiguration(const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function OpenWithOptions(const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function ReadChipID(const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function ReadWholeChip(ExpectedSize: QWord; const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function VerifyWholeChip(const InputFile: string; ExpectedSize: QWord;
      const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;
    function VerifyWholeChipData(const Data: TBytes; ExpectedSize: QWord;
      const Options: TT48RunOptions;
      out BridgeResult: TT48BridgeResult): boolean;

    property ToolPath: string read FToolPath;
    property DeviceName: string read FDeviceName;
    property DeviceInfo: TT48BridgeResult read FDeviceInfo;

    function GetLastError: string; override;
    function DevOpen: boolean; override;
    procedure DevClose; override;

    function SPIInit(speed: integer): boolean; override;
    procedure SPIDeinit; override;
    function SPIRead(CS: byte; BufferLen: integer;
      var buffer: array of byte): integer; override;
    function SPIWrite(CS: byte; BufferLen: integer;
      buffer: array of byte): integer; override;

    procedure I2CInit; override;
    procedure I2CDeinit; override;
    function I2CReadWrite(DevAddr: byte;
      WBufferLen: integer; WBuffer: array of byte;
      RBufferLen: integer; var RBuffer: array of byte): integer; override;
    procedure I2CStart; override;
    procedure I2CStop; override;
    function I2CReadByte(ack: boolean): byte; override;
    function I2CWriteByte(data: byte): boolean; override;

    function MWInit(speed: integer): boolean; override;
    procedure MWDeinit; override;
    function MWRead(CS: byte; BufferLen: integer;
      var buffer: array of byte): integer; override;
    function MWWrite(CS: byte; BitsWrite: byte;
      buffer: array of byte): integer; override;
    function MWIsBusy: boolean; override;
  end;

implementation

const
  T48_RAW_UNSUPPORTED =
    'T48 preview exposes managed whole-chip reads and verification only; ' +
    'raw bus commands are unavailable';
  T48_BUSY_ERROR =
    'a T48 operation is already active; configuration cannot change ' +
    'during an in-flight minipro request';

function AbsoluteToolPath(const Value: string): boolean;
begin
  Result := False;
  if (Value = '') or (Value <> Trim(Value)) then Exit;
  {$ifdef WINDOWS}
  Result := ((Length(Value) >= 3) and (Value[2] = ':') and
             (Value[3] in ['\', '/'])) or
            ((Length(Value) >= 3) and
             (((Value[1] = '\') and (Value[2] = '\')) or
              ((Value[1] = '/') and (Value[2] = '/'))));
  {$else}
  Result := (Length(Value) >= 1) and (Value[1] = '/');
  {$endif}
end;

constructor TT48Hardware.Create;
begin
  CreateWithRunner(TDirectProcessRunner.Create);
end;

constructor TT48Hardware.CreateWithRunner(const Runner: IProcessRunner);
begin
  inherited Create;
  FHardwareID := CHW_T48;
  FHardwareName := 'XGecu T48 (minipro read-only preview)';
  FRunner := Runner;
  FBridge := nil;
  FOpened := False;
  FBridgeCallDepth := 0;
  InitT48BridgeResult(FDeviceInfo);
end;

destructor TT48Hardware.Destroy;
begin
  DevClose;
  FBridge.Free;
  FRunner := nil;
  inherited Destroy;
end;

procedure TT48Hardware.RebuildBridge;
begin
  if FBridgeCallDepth <> 0 then
  begin
    FLastError := T48_BUSY_ERROR;
    Exit;
  end;
  FreeAndNil(FBridge);
  if FRunner <> nil then
    FBridge := TT48Bridge.Create(FRunner, FToolPath);
end;

procedure TT48Hardware.Configure(const ToolPath,
  ExactDeviceName: string);
begin
  if FBridgeCallDepth <> 0 then
  begin
    FLastError := T48_BUSY_ERROR;
    Exit;
  end;
  FToolPath := ToolPath;
  FDeviceName := ExactDeviceName;
  FOpened := False;
  FLastError := '';
  InitT48BridgeResult(FDeviceInfo);
  RebuildBridge;
end;

function TT48Hardware.Configured: boolean;
var
  DevicePart, PackagePart, Err: string;
begin
  Result := AbsoluteToolPath(FToolPath) and FileExists(FToolPath) and
    ValidateT48DeviceName(FDeviceName, DevicePart, PackagePart, Err);
end;

procedure TT48Hardware.RememberResult(const Value: TT48BridgeResult);
begin
  if Value.Error = tbeNone then
    FLastError := ''
  else
    FLastError := Value.ErrorText;
end;

function TT48Hardware.ClosedResult: TT48BridgeResult;
begin
  InitT48BridgeResult(Result);
  Result.Error := tbeProgrammerNotFound;
  Result.ErrorText := 'the T48 operation was requested without a validated ' +
    'live T48 session';
end;

function TT48Hardware.TryBeginBridgeCall(
  out BridgeResult: TT48BridgeResult): boolean;
begin
  InitT48BridgeResult(BridgeResult);
  Result := FBridgeCallDepth = 0;
  if not Result then
  begin
    BridgeResult.Error := tbeBusy;
    BridgeResult.ErrorText := T48_BUSY_ERROR;
    RememberResult(BridgeResult);
    Exit;
  end;
  Inc(FBridgeCallDepth);
end;

procedure TT48Hardware.EndBridgeCall;
begin
  if FBridgeCallDepth > 0 then Dec(FBridgeCallDepth);
end;

function TT48Hardware.ContinueBetweenSteps(const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := True;
  if not Assigned(Options.BetweenStepCancelCheck) then Exit;
  try
    if Options.BetweenStepCancelCheck() then
    begin
      InitT48BridgeResult(BridgeResult);
      BridgeResult.Error := tbeCancelled;
      BridgeResult.ErrorText :=
        'the T48 operation was cancelled between minipro invocations';
      Result := False;
    end;
  except
    on E: Exception do
    begin
      InitT48BridgeResult(BridgeResult);
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'between-step cancellation callback raised ' +
        E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
  if not Result then RememberResult(BridgeResult);
end;

function TT48Hardware.CheckConfigurationCore(const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
var
  DevicePart, PackagePart, Err, ToolVersion: string;
begin
  InitT48BridgeResult(BridgeResult);
  Result := False;
  FOpened := False;
  if FToolPath = '' then
  begin
    BridgeResult.Error := tbeToolUnavailable;
    BridgeResult.ErrorText := 'the minipro executable has not been selected';
    RememberResult(BridgeResult);
    Exit;
  end;
  if not AbsoluteToolPath(FToolPath) then
  begin
    BridgeResult.Error := tbeToolUnavailable;
    BridgeResult.ErrorText :=
      'the minipro executable must be selected by an absolute path';
    RememberResult(BridgeResult);
    Exit;
  end;
  if not FileExists(FToolPath) then
  begin
    BridgeResult.Error := tbeToolUnavailable;
    BridgeResult.ErrorText := 'the selected minipro executable does not exist';
    RememberResult(BridgeResult);
    Exit;
  end;
  if not ValidateT48DeviceName(FDeviceName, DevicePart, PackagePart, Err) then
  begin
    BridgeResult.Error := tbeInvalidDeviceName;
    BridgeResult.ErrorText := Err;
    RememberResult(BridgeResult);
    Exit;
  end;
  if FBridge = nil then
  begin
    BridgeResult.Error := tbeRunnerFailure;
    BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    RememberResult(BridgeResult);
    Exit;
  end;

  BridgeResult := FBridge.CheckTool(Options);
  if BridgeResult.Error <> tbeNone then
  begin
    RememberResult(BridgeResult);
    Exit;
  end;
  ToolVersion := BridgeResult.ToolVersion;
  if not ContinueBetweenSteps(Options, BridgeResult) then Exit;
  BridgeResult := FBridge.GetDeviceInfo(FDeviceName, Options);
  if BridgeResult.Error <> tbeNone then
  begin
    RememberResult(BridgeResult);
    Exit;
  end;
  BridgeResult.ToolVersion := ToolVersion;
  FDeviceInfo := BridgeResult;
  RememberResult(BridgeResult);
  Result := True;
end;

function TT48Hardware.CheckConfiguration(const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    Result := CheckConfigurationCore(Options, BridgeResult);
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.OpenWithOptions(const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    Result := CheckConfigurationCore(Options, BridgeResult);
    if not Result then Exit;
    if not ContinueBetweenSteps(Options, BridgeResult) then
    begin
      FOpened := False;
      Result := False;
      Exit;
    end;
    if FBridge = nil then
    begin
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    end
    else
      BridgeResult := FBridge.CheckProgrammer(Options);
    Result := BridgeResult.Error = tbeNone;
    FOpened := Result;
    RememberResult(BridgeResult);
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.ReadChipID(const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    if not FOpened then
      BridgeResult := ClosedResult
    else if FBridge = nil then
    begin
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    end
    else
      BridgeResult := FBridge.ReadChipID(FDeviceName, Options);
    RememberResult(BridgeResult);
    Result := BridgeResult.Error = tbeNone;
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.ReadWholeChip(ExpectedSize: QWord;
  const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    if not FOpened then
      BridgeResult := ClosedResult
    else if FBridge = nil then
    begin
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    end
    else
      BridgeResult := FBridge.ReadChip(FDeviceName, ExpectedSize, Options);
    RememberResult(BridgeResult);
    Result := BridgeResult.Error = tbeNone;
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.VerifyWholeChip(const InputFile: string;
  ExpectedSize: QWord; const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    if not FOpened then
      BridgeResult := ClosedResult
    else if FBridge = nil then
    begin
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    end
    else
      BridgeResult := FBridge.VerifyChip(FDeviceName, InputFile,
        ExpectedSize, Options);
    RememberResult(BridgeResult);
    Result := BridgeResult.Error = tbeNone;
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.VerifyWholeChipData(const Data: TBytes;
  ExpectedSize: QWord; const Options: TT48RunOptions;
  out BridgeResult: TT48BridgeResult): boolean;
begin
  Result := False;
  if not TryBeginBridgeCall(BridgeResult) then Exit;
  try
    if not FOpened then
      BridgeResult := ClosedResult
    else if FBridge = nil then
    begin
      BridgeResult.Error := tbeRunnerFailure;
      BridgeResult.ErrorText := 'the minipro process runner is unavailable';
    end
    else
      BridgeResult := FBridge.VerifyChipData(FDeviceName, Data,
        ExpectedSize, Options);
    RememberResult(BridgeResult);
    Result := BridgeResult.Error = tbeNone;
  finally
    EndBridgeCall;
  end;
end;

function TT48Hardware.GetLastError: string;
begin
  Result := FLastError;
end;

function TT48Hardware.DevOpen: boolean;
var
  Options: TT48RunOptions;
  BridgeResult: TT48BridgeResult;
begin
  InitT48RunOptions(Options);
  Result := OpenWithOptions(Options, BridgeResult);
end;

procedure TT48Hardware.DevClose;
begin
  //Each minipro invocation owns and closes its own process/USB transaction.
  FOpened := False;
end;

function TT48Hardware.SPIInit(speed: integer): boolean;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := False;
end;

procedure TT48Hardware.SPIDeinit;
begin
end;

function TT48Hardware.SPIRead(CS: byte; BufferLen: integer;
  var buffer: array of byte): integer;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := -1;
end;

function TT48Hardware.SPIWrite(CS: byte; BufferLen: integer;
  buffer: array of byte): integer;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := -1;
end;

procedure TT48Hardware.I2CInit;
begin
  FLastError := T48_RAW_UNSUPPORTED;
end;

procedure TT48Hardware.I2CDeinit;
begin
end;

function TT48Hardware.I2CReadWrite(DevAddr: byte; WBufferLen: integer;
  WBuffer: array of byte; RBufferLen: integer;
  var RBuffer: array of byte): integer;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := -1;
end;

procedure TT48Hardware.I2CStart;
begin
  FLastError := T48_RAW_UNSUPPORTED;
end;

procedure TT48Hardware.I2CStop;
begin
end;

function TT48Hardware.I2CReadByte(ack: boolean): byte;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := $FF;
end;

function TT48Hardware.I2CWriteByte(data: byte): boolean;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := False;
end;

function TT48Hardware.MWInit(speed: integer): boolean;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := False;
end;

procedure TT48Hardware.MWDeinit;
begin
end;

function TT48Hardware.MWRead(CS: byte; BufferLen: integer;
  var buffer: array of byte): integer;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := -1;
end;

function TT48Hardware.MWWrite(CS: byte; BitsWrite: byte;
  buffer: array of byte): integer;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := -1;
end;

function TT48Hardware.MWIsBusy: boolean;
begin
  FLastError := T48_RAW_UNSUPPORTED;
  Result := False;
end;

end.
