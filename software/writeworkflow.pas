unit writeworkflow;

// Owned, immutable prepared NOR jobs shared by the desktop and headless runner.
// Preparation never opens a device. Execution consumes a job exactly once and
// proves its preimage again in the physical session used for programming.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, operationmodel, norplanner, norengine;

type
  // A click accepts exactly the plan last presented. Changed inputs publish a
  // replacement plan and require a new deliberate Write action.
  TInlineWriteGate = class
  private
    FContext, FIdentity: string;
    FReady: boolean;
  public
    function Present(const Context, Identity: string;
      CommitRequested: boolean): boolean;
    function ReadyFor(const Context: string): boolean;
    procedure Clear;
  end;

  TPreparedNORWrite = class
  private
    FRequest: TOperationRequest;
    FGeometry: TNORGeometry;
    FPlan: TNORPlan;
    FSnapshot, FPatch: TBytes;
    FContext: string;
    FConsumed: LongInt;
    function GetPlan: TNORPlan;
    function GetGeometry: TNORGeometry;
    function GetSnapshot: TBytes;
    function GetPatch: TBytes;
  public
    class function Prepare(const Request: TOperationRequest;
      const Geometry: TNORGeometry; const Snapshot, Patch: TBytes;
      const Context: string; out Job: TPreparedNORWrite;
      out ErrorText: string): boolean; static;
    function Matches(const Context: string): boolean;
    function Execute(Device: TNORDevice; const Context: string;
      const Options: TNORExecutorOptions; Token: TCancellationToken = nil;
      OnEvent: TOperationEventProc = nil;
      EvidenceCommit: TOperationEvidenceProc = nil;
      Clock: TOperationClockProc = nil): TOperationOutcome;
    property Request: TOperationRequest read FRequest;
    property Plan: TNORPlan read GetPlan;
    property Geometry: TNORGeometry read GetGeometry;
    property Snapshot: TBytes read GetSnapshot;
    property Patch: TBytes read GetPatch;
    property Context: string read FContext;
  end;

function NORGeometryIdentity(const Geometry: TNORGeometry): string;

implementation

function TInlineWriteGate.Present(const Context, Identity: string;
  CommitRequested: boolean): boolean;
begin
  Result := CommitRequested and ReadyFor(Context) and
    (Identity <> '') and (Identity = FIdentity);
  if Result then Clear
  else
  begin
    FContext := Context;
    FIdentity := Identity;
    FReady := (Context <> '') and (Identity <> '');
  end;
end;

function TInlineWriteGate.ReadyFor(const Context: string): boolean;
begin
  Result := FReady and (Context = FContext);
end;

procedure TInlineWriteGate.Clear;
begin
  FReady := False;
  FContext := '';
  FIdentity := '';
end;

function NORGeometryIdentity(const Geometry: TNORGeometry): string;
var
  I: SizeInt;
begin
  // Canonical bytes also bind dedicated four-byte erase opcodes and hybrid
  // maps. No compiler record layout or translated display label is serialized.
  Result := 'nor-geometry/1' + #10 + IntToStr(Geometry.ChipSize) + #10 +
    IntToStr(Geometry.PageSize) + #10 + IntToHex(Geometry.ErasedValue, 2) + #10;
  for I := 0 to High(Geometry.Blocks) do
    Result := Result + IntToStr(Geometry.Blocks[I].Address) + ':' +
      IntToStr(Geometry.Blocks[I].Size) + ':' +
      IntToHex(Geometry.Blocks[I].Opcode, 2) + #10;
end;

class function TPreparedNORWrite.Prepare(const Request: TOperationRequest;
  const Geometry: TNORGeometry; const Snapshot, Patch: TBytes;
  const Context: string; out Job: TPreparedNORWrite;
  out ErrorText: string): boolean;
var
  Candidate: TPreparedNORWrite;
begin
  Result := False;
  Job := nil;
  ErrorText := '';
  if (Context = '') or (Request.Target.Length <> QWord(Length(Patch))) or
     (Request.Chip.Capacity <> Geometry.ChipSize) or
     (QWord(Length(Snapshot)) <> Geometry.ChipSize) then
  begin
    ErrorText := 'the prepared request, image and full-chip snapshot disagree';
    Exit;
  end;
  Candidate := TPreparedNORWrite.Create;
  try
    Candidate.FRequest := Request;
    Candidate.FGeometry := Geometry;
    Candidate.FGeometry.Blocks := Copy(Geometry.Blocks);
    Candidate.FSnapshot := Copy(Snapshot);
    Candidate.FPatch := Copy(Patch);
    Candidate.FContext := Context;
    if not BuildNORDifferentialPlan(Candidate.FSnapshot, Candidate.FPatch,
      Request.Target.Address, Candidate.FGeometry, Candidate.FPlan,
      ErrorText) then Exit;
    Job := Candidate;
    Candidate := nil;
    Result := True;
  finally
    Candidate.Free;
  end;
end;

function TPreparedNORWrite.GetPlan: TNORPlan;
var
  I: SizeInt;
begin
  Result := FPlan;
  Result.Steps := Copy(FPlan.Steps);
  for I := 0 to High(Result.Steps) do
    Result.Steps[I].Data := Copy(FPlan.Steps[I].Data);
end;

function TPreparedNORWrite.GetGeometry: TNORGeometry;
begin
  Result := FGeometry;
  Result.Blocks := Copy(FGeometry.Blocks);
end;

function TPreparedNORWrite.GetSnapshot: TBytes;
begin
  Result := Copy(FSnapshot);
end;

function TPreparedNORWrite.GetPatch: TBytes;
begin
  Result := Copy(FPatch);
end;

function TPreparedNORWrite.Matches(const Context: string): boolean;
begin
  Result := (FConsumed = 0) and (Context = FContext);
end;

function TPreparedNORWrite.Execute(Device: TNORDevice; const Context: string;
  const Options: TNORExecutorOptions; Token: TCancellationToken;
  OnEvent: TOperationEventProc; EvidenceCommit: TOperationEvidenceProc;
  Clock: TOperationClockProc): TOperationOutcome;
var
  State: TOperationStateMachine;
  Executor: TNORPlanExecutor;
begin
  if (Context <> FContext) or
     (InterlockedCompareExchange(FConsumed, 1, 0) <> 0) then
  begin
    State := TOperationStateMachine.Create(FRequest, Token, OnEvent, Clock);
    try
      State.Start;
      State.Fail(oeInvalidRequest,
        'the prepared job changed or was already used; prepare it again',
        ddNotOpened);
      Exit(State.Outcome);
    finally
      State.Free;
    end;
  end;
  Executor := TNORPlanExecutor.Create(Device, OnEvent, Clock, EvidenceCommit);
  try
    Executor.Options := Options;
    Result := Executor.ExecuteBound(FRequest, FPlan, FGeometry, FSnapshot, Token);
  finally
    Executor.Free;
  end;
end;

end.
