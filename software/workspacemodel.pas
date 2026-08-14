unit workspacemodel;

// Presentation-only state for the main window workspaces.
//
// This unit deliberately has no LCL or hardware dependencies.  It decides
// which intent the task surface should offer, while main.pas keeps routing
// those intents through the existing operation handlers and safety gates.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, msgstr;

type
  TWorkspaceMode = (wmRepair, wmBench, wmProduction);

  TWorkspaceAction = (
    waNone,
    waScanProgrammer,
    waDetectChip,
    waChooseChip,
    waReadChip,
    waSaveBuffer,
    waOpenImage,
    waReviewSmartWrite,
    waPreviewSmartWrite,
    waVerify,
    waInspectBuffer,
    waOpenBench,
    waConfigureProduction,
    waRunProduction,
    waCancelOperation
  );

  TWorkspaceCommand = record
    Action: TWorkspaceAction;
    Caption: string;
    Enabled: boolean;
  end;

  TWorkspacePresentation = record
    Eyebrow: string;
    Title: string;
    Detail: string;
    Primary: TWorkspaceCommand;
    Secondary: TWorkspaceCommand;
    Tertiary: TWorkspaceCommand;
  end;

  TRepairContext = record
    OperationRunning: boolean;
    ProgrammerPresent: boolean;
    SPISelected: boolean;
    ChipSelected: boolean;
    LiveIdentityRead: boolean;
    LiveIdentityText: string;
    IdentityProven: boolean;
    HasBuffer: boolean;
    BufferFromChip: boolean;
    BufferFromFileOrEdit: boolean;
    CanDetect: boolean;
    CanRead: boolean;
    CanVerify: boolean;
    SmartWriteAvailable: boolean;
    SmartWritePreviewAvailable: boolean;
    SmartWriteReason: string;
    StateDetail: string;
  end;

  TProductionContext = record
    OperationRunning: boolean;
    HasBuffer: boolean;
    BatchEnabled: boolean;
    JobLoaded: boolean;
    JobRejected: boolean;
    JobDetail: string;
  end;

function WorkspaceModeName(Mode: TWorkspaceMode): string;
function WorkspaceModeDescription(Mode: TWorkspaceMode): string;
function BuildRepairPresentation(
  const Context: TRepairContext): TWorkspacePresentation;
function BuildProductionPresentation(
  const Context: TProductionContext): TWorkspacePresentation;

implementation

procedure SetCommand(out Command: TWorkspaceCommand;
  Action: TWorkspaceAction; const Caption: string; Enabled: boolean = True);
begin
  Command.Action := Action;
  Command.Caption := Caption;
  Command.Enabled := Enabled and (Action <> waNone);
end;

procedure ClearPresentation(out Presentation: TWorkspacePresentation);
begin
  Presentation.Eyebrow := '';
  Presentation.Title := '';
  Presentation.Detail := '';
  SetCommand(Presentation.Primary, waNone, '', False);
  SetCommand(Presentation.Secondary, waNone, '', False);
  SetCommand(Presentation.Tertiary, waNone, '', False);
end;

procedure AppendStateDetail(var Detail: string; const StateDetail: string);
begin
  if Trim(StateDetail) = '' then Exit;
  if Detail <> '' then Detail := Detail + LineEnding + LineEnding;
  Detail := Detail + StateDetail;
end;

function WorkspaceModeName(Mode: TWorkspaceMode): string;
begin
  case Mode of
    wmRepair: Result := STR_WORKSPACE_REPAIR;
    wmBench: Result := STR_WORKSPACE_BENCH;
    wmProduction: Result := STR_WORKSPACE_PRODUCTION;
  end;
end;

function WorkspaceModeDescription(Mode: TWorkspaceMode): string;
begin
  case Mode of
    wmRepair:
      Result := STR_WORKSPACE_REPAIR_DESC;
    wmBench:
      Result := STR_WORKSPACE_BENCH_DESC;
    wmProduction:
      Result := STR_WORKSPACE_PRODUCTION_DESC;
  end;
end;

function BuildRepairPresentation(
  const Context: TRepairContext): TWorkspacePresentation;
begin
  ClearPresentation(Result);

  if Context.OperationRunning then
  begin
    Result.Eyebrow := STR_WORKSPACE_OPERATION_RUNNING;
    Result.Title := STR_WORKSPACE_OPERATION_RUNNING_TITLE;
    Result.Detail := STR_WORKSPACE_OPERATION_RUNNING_DETAIL;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    SetCommand(Result.Secondary, waCancelOperation,
      STR_WORKSPACE_ACTION_SAFE_STOP);
    Exit;
  end;

  if not Context.ProgrammerPresent then
  begin
    Result.Eyebrow := STR_WORKSPACE_REPAIR_CONNECT;
    Result.Title := STR_WORKSPACE_REPAIR_CONNECT_TITLE;
    Result.Detail := STR_WORKSPACE_REPAIR_CONNECT_DETAIL;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    SetCommand(Result.Primary, waScanProgrammer,
      STR_WORKSPACE_ACTION_SCAN_PROGRAMMER);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_OPEN_TECHNICAL);
    Exit;
  end;

  if not Context.ChipSelected then
  begin
    if Context.LiveIdentityRead then
    begin
      Result.Eyebrow := STR_WORKSPACE_REPAIR_SELECT_PROFILE;
      Result.Title := STR_WORKSPACE_REPAIR_SELECT_PROFILE_TITLE;
      Result.Detail := Format(STR_WORKSPACE_REPAIR_SELECT_PROFILE_DETAIL,
        [Context.LiveIdentityText]);
      AppendStateDetail(Result.Detail, Context.StateDetail);
      SetCommand(Result.Primary, waChooseChip,
        STR_WORKSPACE_ACTION_CHOOSE_MATCHING);
      SetCommand(Result.Secondary, waDetectChip,
        STR_WORKSPACE_ACTION_READ_ID_AGAIN, Context.CanDetect);
      SetCommand(Result.Tertiary, waOpenBench,
        STR_WORKSPACE_ACTION_OPEN_TECHNICAL);
      Exit;
    end;

    Result.Eyebrow := STR_WORKSPACE_REPAIR_IDENTIFY;
    Result.Title := STR_WORKSPACE_REPAIR_IDENTIFY_TITLE;
    if Context.SPISelected then
      Result.Detail := STR_WORKSPACE_REPAIR_IDENTIFY_SPI
    else
      Result.Detail := STR_WORKSPACE_REPAIR_IDENTIFY_OTHER;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    if Context.SPISelected then
    begin
      SetCommand(Result.Primary, waDetectChip,
        STR_WORKSPACE_ACTION_DETECT_CHIP, Context.CanDetect);
      SetCommand(Result.Secondary, waChooseChip,
        STR_WORKSPACE_ACTION_CHOOSE_MANUALLY);
    end
    else
      SetCommand(Result.Primary, waChooseChip,
        STR_WORKSPACE_ACTION_CHOOSE_CATALOGUE);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_OPEN_TECHNICAL);
    Exit;
  end;

  if not Context.IdentityProven then
  begin
    Result.Eyebrow := STR_WORKSPACE_REPAIR_CONFIRM;
    Result.Title := STR_WORKSPACE_REPAIR_CONFIRM_TITLE;
    Result.Detail := STR_WORKSPACE_REPAIR_CONFIRM_DETAIL;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    if Context.SPISelected then
      SetCommand(Result.Primary, waDetectChip,
        STR_WORKSPACE_ACTION_CONFIRM_LIVE_ID, Context.CanDetect)
    else
      SetCommand(Result.Primary, waReadChip,
        STR_WORKSPACE_ACTION_READ_CHIP, Context.CanRead);
    SetCommand(Result.Secondary, waChooseChip,
      STR_WORKSPACE_ACTION_CHOOSE_DIFFERENT);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_OPEN_TECHNICAL);
    Exit;
  end;

  if not Context.HasBuffer then
  begin
    Result.Eyebrow := STR_WORKSPACE_REPAIR_CHOOSE_TASK;
    Result.Title := STR_WORKSPACE_REPAIR_CHOOSE_TITLE;
    Result.Detail := STR_WORKSPACE_REPAIR_CHOOSE_DETAIL;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    SetCommand(Result.Primary, waReadChip,
      STR_WORKSPACE_ACTION_READ_CHIP, Context.CanRead);
    SetCommand(Result.Secondary, waOpenImage,
      STR_WORKSPACE_ACTION_OPEN_FIRMWARE);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_OPEN_TECHNICAL);
    Exit;
  end;

  if Context.BufferFromChip then
  begin
    Result.Eyebrow := STR_WORKSPACE_REPAIR_PRESERVE;
    Result.Title := STR_WORKSPACE_REPAIR_PRESERVE_TITLE;
    Result.Detail := STR_WORKSPACE_REPAIR_PRESERVE_DETAIL;
    AppendStateDetail(Result.Detail, Context.StateDetail);
    SetCommand(Result.Primary, waSaveBuffer,
      STR_WORKSPACE_ACTION_SAVE_BACKUP);
    SetCommand(Result.Secondary, waOpenImage,
      STR_WORKSPACE_ACTION_OPEN_REPLACEMENT);
    SetCommand(Result.Tertiary, waInspectBuffer,
      STR_WORKSPACE_ACTION_INSPECT_READ);
    Exit;
  end;

  Result.Eyebrow := STR_WORKSPACE_REPAIR_REVIEW;
  Result.Title := STR_WORKSPACE_REPAIR_REVIEW_TITLE;
  Result.Detail := STR_WORKSPACE_REPAIR_REVIEW_DETAIL;
  AppendStateDetail(Result.Detail, Context.StateDetail);
  if (not Context.SmartWriteAvailable) and
     (Trim(Context.SmartWriteReason) <> '') then
    AppendStateDetail(Result.Detail, STR_WORKSPACE_BLOCKED_PREFIX +
      Context.SmartWriteReason);
  SetCommand(Result.Primary, waReviewSmartWrite,
    STR_WORKSPACE_ACTION_REVIEW_SMART, Context.SmartWriteAvailable);
  SetCommand(Result.Secondary, waPreviewSmartWrite,
    STR_WORKSPACE_ACTION_PREVIEW_ONLY, Context.SmartWritePreviewAvailable);
  SetCommand(Result.Tertiary, waVerify,
    STR_WORKSPACE_ACTION_VERIFY_IMAGE, Context.CanVerify);
end;

function BuildProductionPresentation(
  const Context: TProductionContext): TWorkspacePresentation;
begin
  ClearPresentation(Result);

  if Context.OperationRunning then
  begin
    Result.Eyebrow := STR_WORKSPACE_PROD_RUNNING;
    Result.Title := STR_WORKSPACE_PROD_RUNNING_TITLE;
    Result.Detail := STR_WORKSPACE_PROD_RUNNING_DETAIL;
    SetCommand(Result.Secondary, waCancelOperation,
      STR_WORKSPACE_ACTION_STOP_UNIT);
    Exit;
  end;

  if Context.JobRejected then
  begin
    Result.Eyebrow := STR_WORKSPACE_PROD_REFUSED;
    Result.Title := STR_WORKSPACE_PROD_REFUSED_TITLE;
    Result.Detail := Context.JobDetail;
    SetCommand(Result.Primary, waConfigureProduction,
      STR_WORKSPACE_ACTION_REVIEW_PROD);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_INSPECT_BENCH);
    Exit;
  end;

  if not Context.HasBuffer then
  begin
    Result.Eyebrow := STR_WORKSPACE_PROD_PREPARE;
    Result.Title := STR_WORKSPACE_PROD_PREPARE_TITLE;
    Result.Detail := STR_WORKSPACE_PROD_PREPARE_DETAIL;
    AppendStateDetail(Result.Detail, Context.JobDetail);
    SetCommand(Result.Primary, waOpenImage,
      STR_WORKSPACE_ACTION_OPEN_PROD_IMAGE);
    SetCommand(Result.Secondary, waConfigureProduction,
      STR_WORKSPACE_ACTION_CONFIGURE_BATCH);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_INSPECT_IN_BENCH);
    Exit;
  end;

  if not Context.BatchEnabled then
  begin
    Result.Eyebrow := STR_WORKSPACE_PROD_CONFIGURE;
    Result.Title := STR_WORKSPACE_PROD_CONFIGURE_TITLE;
    Result.Detail := STR_WORKSPACE_PROD_CONFIGURE_DETAIL;
    AppendStateDetail(Result.Detail, Context.JobDetail);
    SetCommand(Result.Primary, waConfigureProduction,
      STR_WORKSPACE_ACTION_CONFIGURE_PROD);
    SetCommand(Result.Secondary, waOpenImage,
      STR_WORKSPACE_ACTION_REPLACE_IMAGE);
    SetCommand(Result.Tertiary, waOpenBench,
      STR_WORKSPACE_ACTION_INSPECT_BENCH);
    Exit;
  end;

  Result.Eyebrow := STR_WORKSPACE_PROD_READY;
  Result.Title := STR_WORKSPACE_PROD_READY_TITLE;
  Result.Detail := STR_WORKSPACE_PROD_READY_DETAIL;
  AppendStateDetail(Result.Detail, Context.JobDetail);
  SetCommand(Result.Primary, waRunProduction,
    STR_WORKSPACE_ACTION_RUN_PROD);
  SetCommand(Result.Secondary, waConfigureProduction,
    STR_WORKSPACE_ACTION_REVIEW_CONFIG);
  SetCommand(Result.Tertiary, waOpenBench,
    STR_WORKSPACE_ACTION_INSPECT_BENCH);
end;

end.
