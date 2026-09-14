program workspacemodel_tests;

// The task-first Repair and Production surfaces are projections of state,
// not alternate safety paths.  This suite keeps that projection deterministic
// and LCL-free so a wording/layout refactor cannot silently offer the wrong
// operation, hide a blocked operation, or duplicate an action.

{$mode objfpc}{$H+}

uses
  SysUtils, workspacemodel;

var
  Failures, Assertions: integer;

procedure Check(const Name: string; Condition: boolean);
begin
  Inc(Assertions);
  if not Condition then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
  end;
end;

procedure CheckText(const Name, Expected, Actual: string);
begin
  Check(Name + ' (expected "' + Expected + '", got "' + Actual + '")',
    Actual = Expected);
end;

procedure CheckContains(const Name, Needle, Actual: string);
begin
  Check(Name + ' (missing "' + Needle + '")', Pos(Needle, Actual) > 0);
end;

procedure CheckCommand(const Name: string; const Command: TWorkspaceCommand;
  ExpectedAction: TWorkspaceAction; ExpectedEnabled: boolean;
  const ExpectedCaption: string);
begin
  Check(Name + ' action', Command.Action = ExpectedAction);
  Check(Name + ' enabled state', Command.Enabled = ExpectedEnabled);
  CheckText(Name + ' caption', ExpectedCaption, Command.Caption);
end;

procedure CheckEmptyCommand(const Name: string;
  const Command: TWorkspaceCommand);
begin
  CheckCommand(Name, Command, waNone, False, '');
end;

procedure CheckNoDuplicateActions(const Name: string;
  const Presentation: TWorkspacePresentation);
begin
  Check(Name + ' primary and secondary differ',
    (Presentation.Primary.Action = waNone) or
    (Presentation.Secondary.Action = waNone) or
    (Presentation.Primary.Action <> Presentation.Secondary.Action));
  Check(Name + ' primary and tertiary differ',
    (Presentation.Primary.Action = waNone) or
    (Presentation.Tertiary.Action = waNone) or
    (Presentation.Primary.Action <> Presentation.Tertiary.Action));
  Check(Name + ' secondary and tertiary differ',
    (Presentation.Secondary.Action = waNone) or
    (Presentation.Tertiary.Action = waNone) or
    (Presentation.Secondary.Action <> Presentation.Tertiary.Action));
end;

function ConnectedRepair: TRepairContext;
begin
  Result := Default(TRepairContext);
  Result.ProgrammerPresent := True;
end;

function ConfirmedRepair: TRepairContext;
begin
  Result := ConnectedRepair;
  Result.SPISelected := True;
  Result.ChipSelected := True;
  Result.IdentityProven := True;
end;

procedure TestModeLabels;
begin
  CheckText('repair mode name', 'Repair', WorkspaceModeName(wmRepair));
  CheckText('bench mode name', 'Bench', WorkspaceModeName(wmBench));
  CheckText('production mode name', 'Production',
    WorkspaceModeName(wmProduction));

  CheckContains('repair description names guided work', 'Guided',
    WorkspaceModeDescription(wmRepair));
  CheckContains('bench description names inspection', 'Inspect',
    WorkspaceModeDescription(wmBench));
  CheckContains('production description names traceability', 'traceable',
    WorkspaceModeDescription(wmProduction));
end;

procedure TestRepairRunningTakesPriority;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConfirmedRepair;
  Context.OperationRunning := True;
  Context.HasBuffer := True;
  Context.BufferFromChip := True;
  Context.StateDetail := 'Read 32 KiB of 64 KiB.';
  Presentation := BuildRepairPresentation(Context);

  CheckText('running repair eyebrow', 'OPERATION RUNNING',
    Presentation.Eyebrow);
  CheckContains('running repair carries live state', Context.StateDetail,
    Presentation.Detail);
  CheckEmptyCommand('running repair primary', Presentation.Primary);
  CheckCommand('running repair stop', Presentation.Secondary,
    waCancelOperation, True, 'Request safe stop');
  CheckEmptyCommand('running repair tertiary', Presentation.Tertiary);
  CheckNoDuplicateActions('running repair', Presentation);
end;

procedure TestRepairConnectStep;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TRepairContext);
  Context.StateDetail := 'No supported programmer is open.';
  Presentation := BuildRepairPresentation(Context);

  CheckContains('connect step is first', 'STEP 1 OF 4',
    Presentation.Eyebrow);
  CheckContains('connect step explains the state', Context.StateDetail,
    Presentation.Detail);
  CheckCommand('connect primary', Presentation.Primary,
    waScanProgrammer, True, 'Scan for programmer');
  CheckCommand('offline file work stays available', Presentation.Secondary,
    waOpenImage, True, 'Open firmware image...');
  CheckCommand('connect bench escape hatch', Presentation.Tertiary,
    waOpenBench, True, 'Open technical workspace');
  CheckNoDuplicateActions('connect step', Presentation);
end;

procedure TestRepairIdentification;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConnectedRepair;
  Context.SPISelected := True;
  Context.CanDetect := False;
  Presentation := BuildRepairPresentation(Context);

  CheckContains('SPI identification is step two', 'STEP 2 OF 4',
    Presentation.Eyebrow);
  CheckCommand('blocked detection stays visible', Presentation.Primary,
    waDetectChip, False, 'Detect chip now');
  CheckCommand('SPI identification manual fallback', Presentation.Secondary,
    waChooseChip, True, 'Choose chip manually');
  CheckCommand('SPI identification bench escape hatch',
    Presentation.Tertiary, waOpenBench, True, 'Open technical workspace');
  CheckNoDuplicateActions('SPI identification', Presentation);

  Context.CanDetect := True;
  Presentation := BuildRepairPresentation(Context);
  Check('detection becomes enabled without changing intent',
    Presentation.Primary.Enabled and
    (Presentation.Primary.Action = waDetectChip));

  Context.LiveIdentityRead := True;
  Context.LiveIdentityText := 'EF4017';
  Presentation := BuildRepairPresentation(Context);
  CheckContains('live ID without a profile selects the matching step',
    'SELECT PROFILE', Presentation.Eyebrow);
  CheckContains('matching step keeps the observed ID visible',
    Context.LiveIdentityText, Presentation.Detail);
  CheckCommand('matching step chooses the exact profile',
    Presentation.Primary, waChooseChip, True,
    'Choose matching chip profile...');
  CheckCommand('matching step can repeat the live read',
    Presentation.Secondary, waDetectChip, True, 'Read chip ID again');
  CheckNoDuplicateActions('live ID matching', Presentation);

  Context.LiveIdentityRead := False;
  Context.LiveIdentityText := '';

  Context.SPISelected := False;
  Presentation := BuildRepairPresentation(Context);
  CheckContains('non-SPI identification explains the missing live ID',
    'no standard live ID command', Presentation.Detail);
  CheckCommand('non-SPI identification chooses a catalogue part',
    Presentation.Primary, waChooseChip, True,
    'Choose chip from catalogue');
  CheckNoDuplicateActions('non-SPI identification', Presentation);
end;

procedure TestRepairConfirmation;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConnectedRepair;
  Context.SPISelected := True;
  Context.ChipSelected := True;
  Context.CanDetect := False;
  Presentation := BuildRepairPresentation(Context);

  CheckContains('selected SPI chip still needs confirmation', 'CONFIRM',
    Presentation.Eyebrow);
  CheckCommand('blocked live confirmation stays visible',
    Presentation.Primary, waDetectChip, False,
    'Confirm with live chip ID');
  CheckCommand('confirmation can change the profile', Presentation.Secondary,
    waChooseChip, True, 'Choose a different chip');
  CheckNoDuplicateActions('SPI confirmation', Presentation);

  Context.SPISelected := False;
  Context.CanRead := True;
  Presentation := BuildRepairPresentation(Context);
  CheckCommand('non-SPI confirmation reads the selected part',
    Presentation.Primary, waReadChip, True, 'Read chip');
  CheckNoDuplicateActions('non-SPI confirmation', Presentation);
end;

procedure TestRepairTaskChoice;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConfirmedRepair;
  Context.CanRead := False;
  Presentation := BuildRepairPresentation(Context);

  CheckContains('confirmed empty session chooses a task', 'CHOOSE TASK',
    Presentation.Eyebrow);
  CheckCommand('blocked read stays visible', Presentation.Primary,
    waReadChip, False, 'Read chip');
  CheckCommand('an image can be opened instead', Presentation.Secondary,
    waOpenImage, True, 'Open firmware image...');
  CheckCommand('task choice keeps Bench available', Presentation.Tertiary,
    waOpenBench, True, 'Open technical workspace');
  CheckNoDuplicateActions('repair task choice', Presentation);
end;

procedure TestRepairPreservesAReadFirst;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConfirmedRepair;
  Context.HasBuffer := True;
  Context.BufferFromChip := True;
  Presentation := BuildRepairPresentation(Context);

  CheckContains('a read enters the preserve step', 'PRESERVE',
    Presentation.Eyebrow);
  CheckContains('preserve step explains saving is non-destructive',
    'does not change the chip', Presentation.Detail);
  CheckCommand('preserve primary', Presentation.Primary,
    waSaveBuffer, True, 'Save backup copy...');
  CheckCommand('preserve replacement path', Presentation.Secondary,
    waOpenImage, True, 'Open replacement image...');
  CheckCommand('preserve inspection path', Presentation.Tertiary,
    waInspectBuffer, True, 'Inspect the read');
  CheckNoDuplicateActions('repair preserve step', Presentation);
end;

procedure TestRepairReviewsReplacementImage;
var
  Context: TRepairContext;
  Presentation: TWorkspacePresentation;
begin
  Context := ConfirmedRepair;
  Context.HasBuffer := True;
  Context.BufferFromFileOrEdit := True;
  Context.SmartWriteAvailable := False;
  Context.SmartWritePreviewAvailable := True;
  Context.CanVerify := False;
  Context.SmartWriteReason := 'the image is larger than the chip';
  Context.StateDetail := 'Rail measured: not measurable.';
  Presentation := BuildRepairPresentation(Context);

  CheckContains('replacement image enters review', 'REVIEW',
    Presentation.Eyebrow);
  CheckContains('review carries electrical state', Context.StateDetail,
    Presentation.Detail);
  CheckContains('review exposes the Smart Write refusal',
    'Blocked: ' + Context.SmartWriteReason, Presentation.Detail);
  CheckCommand('blocked Smart Write stays visible', Presentation.Primary,
    waReviewSmartWrite, False, 'Review Smart Write plan...');
  CheckCommand('preview remains independently available',
    Presentation.Secondary, waPreviewSmartWrite, True, 'Preview only');
  CheckCommand('blocked verify stays visible', Presentation.Tertiary,
    waVerify, False, 'Verify chip against image');
  CheckNoDuplicateActions('repair review step', Presentation);

  Context.SmartWriteAvailable := True;
  Context.CanVerify := True;
  Context.SmartWriteReason := '';
  Presentation := BuildRepairPresentation(Context);
  Check('Smart Write becomes enabled', Presentation.Primary.Enabled);
  Check('verify becomes enabled', Presentation.Tertiary.Enabled);
  Check('no empty refusal label is rendered',
    Pos('Blocked:', Presentation.Detail) = 0);
end;

procedure TestProductionRunningTakesPriority;
var
  Context: TProductionContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TProductionContext);
  Context.OperationRunning := True;
  Context.HasBuffer := True;
  Context.BatchEnabled := True;
  Context.JobRejected := True;
  Presentation := BuildProductionPresentation(Context);

  CheckContains('production running state wins', 'UNIT RUNNING',
    Presentation.Eyebrow);
  CheckContains('production running state protects the fixture',
    'Do not remove', Presentation.Title);
  CheckEmptyCommand('production running primary', Presentation.Primary);
  CheckCommand('production running stop', Presentation.Secondary,
    waCancelOperation, True, 'Stop current unit safely');
  CheckEmptyCommand('production running tertiary', Presentation.Tertiary);
  CheckNoDuplicateActions('production running', Presentation);
end;

procedure TestProductionRejectedJob;
var
  Context: TProductionContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TProductionContext);
  Context.JobRejected := True;
  Context.JobDetail := 'Signature did not match the configured key.';
  Presentation := BuildProductionPresentation(Context);

  CheckContains('rejected job is a refusal', 'CONFIGURATION REFUSED',
    Presentation.Eyebrow);
  CheckText('rejected job keeps the exact reason', Context.JobDetail,
    Presentation.Detail);
  CheckCommand('rejected job opens settings', Presentation.Primary,
    waConfigureProduction, True, 'Review production settings...');
  CheckEmptyCommand('rejected job secondary', Presentation.Secondary);
  CheckCommand('rejected job may be inspected safely',
    Presentation.Tertiary, waOpenBench, True, 'Inspect image in Bench');
  CheckNoDuplicateActions('rejected production job', Presentation);
end;

procedure TestProductionPreparation;
var
  Context: TProductionContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TProductionContext);
  Context.JobDetail := 'Operator and evidence path are not configured.';
  Presentation := BuildProductionPresentation(Context);

  CheckContains('empty production workspace prepares an image', 'PREPARE',
    Presentation.Eyebrow);
  CheckContains('production preparation carries job state',
    Context.JobDetail, Presentation.Detail);
  CheckCommand('production preparation opens an image',
    Presentation.Primary, waOpenImage, True, 'Open production image...');
  CheckCommand('production preparation opens configuration',
    Presentation.Secondary, waConfigureProduction, True,
    'Configure batch...');
  CheckCommand('production preparation keeps Bench available',
    Presentation.Tertiary, waOpenBench, True, 'Inspect in Bench');
  CheckNoDuplicateActions('production preparation', Presentation);
end;

procedure TestProductionConfiguration;
var
  Context: TProductionContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TProductionContext);
  Context.HasBuffer := True;
  Context.JobDetail := 'Image loaded; batch is disabled.';
  Presentation := BuildProductionPresentation(Context);

  CheckContains('loaded image needs batch configuration', 'CONFIGURE',
    Presentation.Eyebrow);
  CheckContains('batch configuration carries job state', Context.JobDetail,
    Presentation.Detail);
  CheckCommand('batch configuration primary', Presentation.Primary,
    waConfigureProduction, True, 'Configure production batch...');
  CheckCommand('batch configuration can replace the image',
    Presentation.Secondary, waOpenImage, True, 'Replace image...');
  CheckCommand('batch configuration can inspect the image',
    Presentation.Tertiary, waOpenBench, True, 'Inspect image in Bench');
  CheckNoDuplicateActions('production configuration', Presentation);
end;

procedure TestProductionConfigured;
var
  Context: TProductionContext;
  Presentation: TWorkspacePresentation;
begin
  Context := Default(TProductionContext);
  Context.HasBuffer := True;
  Context.BatchEnabled := True;
  Context.JobLoaded := True;
  Context.JobDetail := '10 units; operator PAT; evidence log ready.';
  Presentation := BuildProductionPresentation(Context);

  CheckContains('configured production workspace is explicit', 'CONFIGURED',
    Presentation.Eyebrow);
  CheckContains('configured production keeps checks pending',
    'checks pending', Presentation.Title);
  CheckContains('configured production workspace carries the configuration',
    Context.JobDetail, Presentation.Detail);
  CheckCommand('ready production primary', Presentation.Primary,
    waRunProduction, True, 'Run production batch...');
  CheckCommand('ready production can review configuration',
    Presentation.Secondary, waConfigureProduction, True,
    'Review configuration...');
  CheckCommand('ready production can inspect the image',
    Presentation.Tertiary, waOpenBench, True, 'Inspect image in Bench');
  CheckNoDuplicateActions('production ready', Presentation);
end;

begin
  TestModeLabels;
  TestRepairRunningTakesPriority;
  TestRepairConnectStep;
  TestRepairIdentification;
  TestRepairConfirmation;
  TestRepairTaskChoice;
  TestRepairPreservesAReadFirst;
  TestRepairReviewsReplacementImage;
  TestProductionRunningTakesPriority;
  TestProductionRejectedJob;
  TestProductionPreparation;
  TestProductionConfiguration;
  TestProductionConfigured;
  WriteLn(Assertions, ' assertions, ', Failures, ' failures');
  if Failures <> 0 then Halt(1);
  WriteLn('ALL PASSED');
end.
