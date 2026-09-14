unit eepromsession;

// Owns real programmer sessions around EEPROM protocol adapters. The first
// session proves the planning snapshot before writing; subsequent sessions are
// independently opened for readback. No GUI state is accessed by the worker.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, basehw, eepromengine;

type
  TEEPROMBus = (ebSPI, ebI2C, ebMicroWire);
  TEEPROMSession = class(TEEPROMDevice)
  private
    FInner: TEEPROMDevice;
    FHardware: TBaseHardware;
    FBus: TEEPROMBus;
    FSpeed: integer;
    FVoltage, FPageSize: cardinal;
    FSnapshot: TBytes;
    FFirstSession, FOpened, FBusStarted: boolean;
    procedure EndBus;
  public
    constructor Create(Inner: TEEPROMDevice; Hardware: TBaseHardware;
      Bus: TEEPROMBus; Speed: integer; Voltage, PageSize: cardinal;
      const Snapshot: TBytes);
    destructor Destroy; override;
    function Open: TEEPROMIOResult; override;
    function Initialize: TEEPROMIOResult; override;
    function WritePage(Address: QWord; const Data: TBytes): TEEPROMIOResult; override;
    function ReadPage(Address: QWord; Len: cardinal;
      out Data: TBytes): TEEPROMIOResult; override;
    function Deinitialize: TEEPROMIOResult; override;
    function Close: TEEPROMIOResult; override;
  end;

implementation

constructor TEEPROMSession.Create(Inner: TEEPROMDevice;
  Hardware: TBaseHardware; Bus: TEEPROMBus; Speed: integer;
  Voltage, PageSize: cardinal; const Snapshot: TBytes);
begin
  inherited Create;
  FHardware := Hardware;
  FBus := Bus;
  FSpeed := Speed;
  FVoltage := Voltage;
  FPageSize := PageSize;
  FSnapshot := Copy(Snapshot);
  // Transfer ownership only after allocations that can raise have succeeded.
  FInner := Inner;
  FFirstSession := True;
end;

destructor TEEPROMSession.Destroy;
begin
  FInner.Free;
  inherited Destroy;
end;

function TEEPROMSession.Open: TEEPROMIOResult;
begin
  if FOpened then Exit(EEPROMIOFailure(eioBusy, 'EEPROM session already open'));
  if (FHardware = nil) or (FInner = nil) or (FPageSize = 0) or
     (Length(FSnapshot) = 0) or (Length(FSnapshot) mod FPageSize <> 0) then
    Exit(EEPROMIOFailure(eioRejected, 'EEPROM session binding is incomplete'));
  if not FHardware.DevOpen then
    Exit(EEPROMIOFailure(eioDisconnected, FHardware.GetLastError));
  FOpened := True;
  try
    if FVoltage <> 0 then
      if (not FHardware.SupportsTargetVoltage) or
         (not FHardware.SetTargetVoltageMv(FVoltage)) then
      begin
        Close;
        Exit(EEPROMIOFailure(eioRejected, 'the prepared target voltage could not be restored'));
      end;
    Result := FInner.Open;
    if not Result.Success then Close;
  except
    Close;
    raise;
  end;
end;

procedure TEEPROMSession.EndBus;
begin
  if not FBusStarted then Exit;
  FBusStarted := False;
  case FBus of
    ebSPI: FHardware.SPIDeinit;
    ebI2C: FHardware.I2CDeinit;
    ebMicroWire: FHardware.MWDeinit;
  end;
end;

function TEEPROMSession.Initialize: TEEPROMIOResult;
var
  Good: boolean;
  Address: SizeInt;
  Data: TBytes;
begin
  if not FOpened then Exit(EEPROMIOFailure(eioRejected, 'EEPROM session is closed'));
  // Cleanup is required even when a backend partially initializes then fails.
  FBusStarted := True;
  Good := True;
  case FBus of
    ebSPI: Good := FHardware.SPIInit(FSpeed);
    ebI2C: begin FHardware.I2CInit; Sleep(50); end;
    ebMicroWire: Good := FHardware.MWInit(FSpeed);
  end;
  if not Good then Exit(EEPROMIOFailure(eioTransport, 'EEPROM bus initialization failed'));
  Result := FInner.Initialize;
  if not Result.Success then Exit;
  if FFirstSession then
  begin
    Address := 0;
    while Address < Length(FSnapshot) do
    begin
      Result := FInner.ReadPage(Address, FPageSize, Data);
      if not Result.Success then Exit;
      if (Result.Transferred <> FPageSize) or (Length(Data) <> FPageSize) then
        Exit(EEPROMIOFailure(eioTransport, 'short EEPROM planning-snapshot read'));
      if not CompareMem(@Data[0], @FSnapshot[Address], FPageSize) then
        Exit(EEPROMIOFailure(eioRejected,
          'chip content changed since preparation at 0x' + IntToHex(Address, 6)));
      Inc(Address, FPageSize);
    end;
    FFirstSession := False;
  end;
  Result := EEPROMIOSuccess;
end;

function TEEPROMSession.WritePage(Address: QWord;
  const Data: TBytes): TEEPROMIOResult;
begin
  Result := FInner.WritePage(Address, Data);
end;

function TEEPROMSession.ReadPage(Address: QWord; Len: cardinal;
  out Data: TBytes): TEEPROMIOResult;
begin
  Result := FInner.ReadPage(Address, Len, Data);
end;

function TEEPROMSession.Deinitialize: TEEPROMIOResult;
begin
  try
    Result := FInner.Deinitialize;
  finally
    EndBus;
  end;
end;

function TEEPROMSession.Close: TEEPROMIOResult;
var
  InnerResult: TEEPROMIOResult;
begin
  Result := EEPROMIOSuccess;
  if not FOpened then Exit;
  FOpened := False;
  try
    if FBusStarted then Result := Deinitialize;
    InnerResult := FInner.Close;
    if Result.Success then Result := InnerResult;
  finally
    FHardware.DevClose;
  end;
end;

end.
