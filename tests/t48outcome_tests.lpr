program t48outcome_tests;

// The bridge may grow finer-grained internal errors, but the process exit
// contract stays small and operator-facing.  Pin every current bridge error
// here so a new value can never become success or a generic exit by accident.

{$mode objfpc}{$H+}

uses
  SysUtils, t48bridge, clicontract, t48outcome;

var
  Assertions: integer = 0;
  Failures: integer = 0;

procedure CheckMapping(const Name: string; Error: TT48BridgeError;
  Expected: TCLIOutcome);
var
  Actual: TCLIOutcome;
begin
  Inc(Assertions);
  Actual := OutcomeFromT48BridgeError(Error);
  if Actual = Expected then Exit;
  Inc(Failures);
  WriteLn('FAIL: ', Name, ' (expected ', CLIOutcomeName(Expected),
    ', got ', CLIOutcomeName(Actual), ')');
end;

procedure TestMappings;
var
  Error: TT48BridgeError;
begin
  CheckMapping('no error', tbeNone, coOK);

  CheckMapping('invalid device', tbeInvalidDeviceName, coUsage);
  CheckMapping('unsupported tool version', tbeUnsupportedToolVersion,
    coUsage);
  CheckMapping('refused command', tbeCommandRefused, coUsage);
  CheckMapping('unsupported device', tbeDeviceNotSupported, coUsage);

  CheckMapping('tool executable', tbeToolUnavailable, coFileError);
  CheckMapping('missing read output', tbeReadOutputMissing, coFileError);
  CheckMapping('stale read output', tbeReadOutputStale, coFileError);
  CheckMapping('read output I/O', tbeReadOutputIO, coFileError);
  CheckMapping('temporary cleanup', tbeTempCleanupFailed, coFileError);
  CheckMapping('missing verify input', tbeVerifyInputMissing, coFileError);
  CheckMapping('verify input I/O', tbeVerifyInputIO, coFileError);

  CheckMapping('invalid expected size', tbeInvalidSize,
    coFileSizeMismatch);
  CheckMapping('read output size', tbeReadOutputSizeMismatch,
    coFileSizeMismatch);
  CheckMapping('verify input size', tbeVerifyInputSizeMismatch,
    coFileSizeMismatch);

  CheckMapping('no live programmer', tbeProgrammerNotFound,
    coNoProgrammer);
  CheckMapping('wrong programmer model', tbeWrongProgrammer,
    coNoProgrammer);
  CheckMapping('device mismatch', tbeDeviceMismatch, coChipMismatch);
  CheckMapping('chip ID mismatch', tbeChipIDMismatch, coChipMismatch);
  CheckMapping('verification mismatch', tbeVerificationMismatch,
    coVerifyFailed);
  CheckMapping('cancelled', tbeCancelled, coCancelled);

  CheckMapping('timeout', tbeTimeout, coUnstable);
  CheckMapping('busy adapter', tbeBusy, coUnstable);
  CheckMapping('runner failure', tbeRunnerFailure, coUnstable);
  CheckMapping('process output limit', tbeProcessOutputLimit, coUnstable);
  CheckMapping('tool failure', tbeToolFailed, coUnstable);
  CheckMapping('malformed tool output', tbeMalformedOutput, coUnstable);
  CheckMapping('malformed device info', tbeMalformedDeviceInfo,
    coUnstable);

  for Error := Low(TT48BridgeError) to High(TT48BridgeError) do
    if Error <> tbeNone then
    begin
      Inc(Assertions);
      if OutcomeFromT48BridgeError(Error) <> coOK then Continue;
      Inc(Failures);
      WriteLn('FAIL: a bridge failure mapped to success (ordinal ',
        Ord(Error), ')');
    end;
end;

begin
  TestMappings;
  WriteLn(Assertions, ' assertions, ', Failures, ' failures');
  if Failures <> 0 then Halt(1);
  WriteLn('ALL PASSED');
end.
