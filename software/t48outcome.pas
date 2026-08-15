unit t48outcome;

// Maps the optional T48 bridge's implementation-level failures onto the
// stable reasons exposed by the command line.  This adapter stays separate
// from both front ends: the bridge remains usable without CLI policy, while
// main can publish a typed outcome without depending on cli.pas.

{$mode objfpc}{$H+}

interface

uses
  t48bridge, clicontract;

function OutcomeFromT48BridgeError(Error: TT48BridgeError): TCLIOutcome;

implementation

function OutcomeFromT48BridgeError(Error: TT48BridgeError): TCLIOutcome;
begin
  case Error of
    tbeNone:
      Result := coOK;

    // These describe an unsupported request or configuration, before a live
    // chip result exists.
    tbeInvalidDeviceName, tbeUnsupportedToolVersion, tbeCommandRefused,
    tbeDeviceNotSupported:
      Result := coUsage;

    // The tool executable and its private input/output files are all local
    // files.  The caller should repair that installation or filesystem, not
    // reseat the target.
    tbeToolUnavailable, tbeReadOutputMissing, tbeReadOutputStale,
    tbeReadOutputIO, tbeTempCleanupFailed, tbeVerifyInputMissing,
    tbeVerifyInputIO:
      Result := coFileError;

    tbeInvalidSize, tbeReadOutputSizeMismatch,
    tbeVerifyInputSizeMismatch:
      Result := coFileSizeMismatch;

    // A connected programmer of another model cannot satisfy a T48 job.  The
    // operator action is the same as when no suitable programmer is present.
    tbeProgrammerNotFound, tbeWrongProgrammer:
      Result := coNoProgrammer;

    tbeDeviceMismatch, tbeChipIDMismatch:
      Result := coChipMismatch;

    tbeVerificationMismatch:
      Result := coVerifyFailed;

    tbeCancelled:
      Result := coCancelled;

    // The remaining failures say that the bridge/tool exchange cannot be
    // trusted.  They deliberately share the existing stop-and-check outcome
    // rather than exposing process-runner internals as a public API.
    tbeTimeout, tbeBusy, tbeRunnerFailure, tbeProcessOutputLimit,
    tbeToolFailed, tbeMalformedOutput, tbeMalformedDeviceInfo:
      Result := coUnstable;
  else
    Result := coFailed;
  end;
end;

end.
