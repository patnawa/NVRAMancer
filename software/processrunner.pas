unit processrunner;

// Small process boundary for optional external tools.  Callers provide an
// executable and an argv vector; no command-line string or shell is accepted.
// The interface keeps orchestration tests independent of the host OS while the
// production adapter owns pipe draining, deadlines, cancellation and cleanup.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TStringVector = array of string;

  TProcessRunStatus = (
    prsCompleted,
    prsStartFailed,
    prsTimedOut,
    prsCancelled,
    prsIOError,
    prsOutputLimit
  );

  TProcessOutputLimitPolicy = (
    polTerminateProcess,
    polWaitForNaturalExit
  );

  TProcessCancelCheck = function: boolean of object;
  TProcessWaitPump = procedure of object;

  TProcessRunRequest = record
    Executable: string;
    Arguments: TStringVector;
    // Zero is an explicit request for no runner-enforced deadline.
    TimeoutMS: QWord;
    MaxOutputBytes: QWord;
    OutputLimitPolicy: TProcessOutputLimitPolicy;
    CancelCheck: TProcessCancelCheck;
    WaitPump: TProcessWaitPump;
  end;

  TProcessRunResult = record
    Status: TProcessRunStatus;
    ExitCode: LongInt;
    StdOutText: string;
    StdErrText: string;
    ErrorText: string;
  end;

  IProcessRunner = interface
    ['{28AD0F8D-DBE5-4A9C-BDC5-77ED8ED3A3B3}']
    function Run(const Request: TProcessRunRequest): TProcessRunResult;
  end;

  TDirectProcessRunner = class(TInterfacedObject, IProcessRunner)
  public
    function Run(const Request: TProcessRunRequest): TProcessRunResult;
  end;

procedure InitProcessRunRequest(out Request: TProcessRunRequest);
procedure InitProcessRunResult(out ResultValue: TProcessRunResult);

implementation

uses
  Process, Pipes;

const
  DEFAULT_OUTPUT_LIMIT = QWord(1024 * 1024);
  MAX_DRAIN_BYTES_PER_POLL = QWord(64 * 1024);
  POLL_INTERVAL_MS = 10;
  TERMINATE_WAIT_MS = 2000;

procedure InitProcessRunRequest(out Request: TProcessRunRequest);
begin
  Request := Default(TProcessRunRequest);
  Request.MaxOutputBytes := DEFAULT_OUTPUT_LIMIT;
  Request.OutputLimitPolicy := polTerminateProcess;
end;

procedure InitProcessRunResult(out ResultValue: TProcessRunResult);
begin
  ResultValue := Default(TProcessRunResult);
  ResultValue.Status := prsIOError;
  ResultValue.ExitCode := -1;
end;

function StreamText(Stream: TMemoryStream): string;
begin
  Result := '';
  if Stream.Size = 0 then Exit;
  if Stream.Size > High(SizeInt) then Exit;
  SetLength(Result, SizeInt(Stream.Size));
  Move(Stream.Memory^, Result[1], SizeInt(Stream.Size));
end;

procedure DrainPipe(Pipe: TInputPipeStream; Destination: TMemoryStream;
  Limit: QWord; var LimitExceeded: boolean);
var
  Buffer: array[0..4095] of byte;
  Available, Wanted, ReadCount, StoreCount: LongInt;
  Remaining, Budget: QWord;
  DiscardOnly: boolean;
begin
  if Pipe = nil then Exit;
  DiscardOnly := LimitExceeded;
  Budget := MAX_DRAIN_BYTES_PER_POLL;
  while Budget > 0 do
  begin
    Available := Pipe.NumBytesAvailable;
    if Available <= 0 then Exit;
    Wanted := Available;
    if Wanted > SizeOf(Buffer) then Wanted := SizeOf(Buffer);
    if QWord(Wanted) > Budget then Wanted := LongInt(Budget);
    ReadCount := Pipe.Read(Buffer[0], Wanted);
    if ReadCount <= 0 then Exit;
    Dec(Budget, QWord(ReadCount));

    if DiscardOnly then
      StoreCount := 0
    else
    begin
      StoreCount := ReadCount;
      if QWord(Destination.Size) >= Limit then
        StoreCount := 0
      else
      begin
        Remaining := Limit - QWord(Destination.Size);
        if QWord(StoreCount) > Remaining then
          StoreCount := SizeInt(Remaining);
      end;
    end;
    if StoreCount > 0 then
      Destination.WriteBuffer(Buffer[0], StoreCount);
    if (not DiscardOnly) and (StoreCount <> ReadCount) then
    begin
      LimitExceeded := True;
      Exit;
    end;
  end;
end;

procedure DrainBoth(P: TProcess; StdOutData, StdErrData: TMemoryStream;
  Limit: QWord; var LimitExceeded: boolean);
var
  Used, Remaining: QWord;
  DiscardOnly: boolean;
begin
  DiscardOnly := LimitExceeded;
  Used := QWord(StdOutData.Size) + QWord(StdErrData.Size);
  if Used >= Limit then Remaining := 0 else Remaining := Limit - Used;
  DrainPipe(P.Output, StdOutData, QWord(StdOutData.Size) + Remaining,
    LimitExceeded);
  if (not DiscardOnly) and LimitExceeded then Exit;

  Used := QWord(StdOutData.Size) + QWord(StdErrData.Size);
  if Used >= Limit then Remaining := 0 else Remaining := Limit - Used;
  DrainPipe(P.Stderr, StdErrData, QWord(StdErrData.Size) + Remaining,
    LimitExceeded);
end;

function TDirectProcessRunner.Run(
  const Request: TProcessRunRequest): TProcessRunResult;
var
  P: TProcess;
  StdOutData, StdErrData: TMemoryStream;
  I: SizeInt;
  StartedAt, StopStartedAt, Limit: QWord;
  LimitExceeded, StopRequested: boolean;
begin
  InitProcessRunResult(Result);
  if Request.Executable = '' then
  begin
    Result.Status := prsStartFailed;
    Result.ErrorText := 'executable path is empty';
    Exit;
  end;

  Limit := Request.MaxOutputBytes;
  if Limit = 0 then Limit := DEFAULT_OUTPUT_LIMIT;
  P := TProcess.Create(nil);
  StdOutData := TMemoryStream.Create;
  StdErrData := TMemoryStream.Create;
  try
    P.Executable := Request.Executable;
    P.Options := [poUsePipes, poNoConsole];
    for I := 0 to High(Request.Arguments) do
      P.Parameters.Add(Request.Arguments[I]);
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Result.Status := prsStartFailed;
        Result.ErrorText := E.ClassName + ': ' + E.Message;
        Exit;
      end;
    end;

    try
      StartedAt := GetTickCount64;
      LimitExceeded := False;
      StopRequested := False;
      while P.Running do
      begin
        DrainBoth(P, StdOutData, StdErrData, Limit, LimitExceeded);
        if LimitExceeded then
        begin
          Result.Status := prsOutputLimit;
          Result.ErrorText := 'process output exceeded the configured limit';
          if Request.OutputLimitPolicy = polTerminateProcess then
            StopRequested := True;
        end;
        if not StopRequested then
        begin
          if Assigned(Request.WaitPump) then
          begin
            try
              Request.WaitPump();
            except
              on E: Exception do
              begin
                Result.Status := prsIOError;
                Result.ErrorText := 'wait callback raised ' + E.ClassName +
                  ': ' + E.Message;
                StopRequested := True;
              end;
            end;
          end;
          if not StopRequested and Assigned(Request.CancelCheck) then
          begin
            try
              if Request.CancelCheck() then
              begin
                Result.Status := prsCancelled;
                Result.ErrorText := 'process was cancelled';
                StopRequested := True;
              end;
            except
              on E: Exception do
              begin
                Result.Status := prsIOError;
                Result.ErrorText := 'cancellation callback raised ' +
                  E.ClassName + ': ' + E.Message;
                StopRequested := True;
              end;
            end;
          end;
          if not StopRequested and (Request.TimeoutMS > 0) and
             (GetTickCount64 - StartedAt >= Request.TimeoutMS) then
          begin
            Result.Status := prsTimedOut;
            Result.ErrorText := 'process exceeded its deadline';
            StopRequested := True;
          end;
        end;

        if StopRequested then
        begin
          if not P.Terminate(1) and P.Running then
          begin
            Result.Status := prsIOError;
            Result.ErrorText := 'could not terminate the child process';
          end;
          Break;
        end;
        Sleep(POLL_INTERVAL_MS);
      end;

      if StopRequested then
      begin
        StopStartedAt := GetTickCount64;
        while P.Running and
              (GetTickCount64 - StopStartedAt < TERMINATE_WAIT_MS) do
        begin
          DrainBoth(P, StdOutData, StdErrData, Limit, LimitExceeded);
          Sleep(POLL_INTERVAL_MS);
        end;
        if P.Running then
        begin
          Result.Status := prsIOError;
          Result.ErrorText := 'child process did not stop after termination';
        end;
      end;

      DrainBoth(P, StdOutData, StdErrData, Limit, LimitExceeded);
      Result.StdOutText := StreamText(StdOutData);
      Result.StdErrText := StreamText(StdErrData);
      if not StopRequested then
      begin
        if LimitExceeded then
        begin
          Result.Status := prsOutputLimit;
          Result.ErrorText := 'process output exceeded the configured limit';
        end
        else
        begin
          Result.Status := prsCompleted;
          Result.ExitCode := P.ExitStatus;
          Result.ErrorText := '';
        end;
      end;
    except
      on E: Exception do
      begin
        Result.Status := prsIOError;
        Result.ErrorText := 'process I/O raised ' + E.ClassName + ': ' +
          E.Message;
        try
          if P.Running then P.Terminate(1);
        except
          // Preserve the first typed I/O failure.  The process destructor is
          // still reached, and no callback is invoked during this cleanup.
        end;
        try
          Result.StdOutText := StreamText(StdOutData);
          Result.StdErrText := StreamText(StdErrData);
        except
          Result.StdOutText := '';
          Result.StdErrText := '';
        end;
      end;
    end;
  finally
    StdErrData.Free;
    StdOutData.Free;
    P.Free;
  end;
end;

end.
