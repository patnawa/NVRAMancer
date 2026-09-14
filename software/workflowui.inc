// Desktop presentation and explicit commit routing. The planner, immutable job,
// recovery reconstruction, and execution remain in units without LCL dependencies.

function TMainForm.CurrentWriteContext: string;
begin
  Result := IntToStr(Ord(NVRAMancer.Current_HW)) + '|' + CurrentICParam.Name +
    '|' + CurrentICParam.ID + '|' + CurrentICParam.Vcc + '|' +
    IntToStr(Ord(RadioSPI.Checked)) + IntToStr(Ord(RadioI2C.Checked)) +
    IntToStr(Ord(RadioMW.Checked)) + '|' + IntToStr(ComboSPICMD.ItemIndex) +
    '|' + ComboChipSize.Text + '|' + ComboPageSize.Text + '|' +
    StartAddressEdit.Text + '|' + IntToStr(ComboAddrType.ItemIndex) + '|' +
    ComboMWBitLen.Text + '|' + IntToStr(SetSPISpeed(0)) + '|' +
    IntToStr(SelectedCH347Vcc) + '|' + IntToStr(BufferRevision) + '|' +
    IntToStr(MPHexEditorEx.DataSize) + '|' + IntToStr(Ord(MenuFastRead.Checked)) +
    IntToStr(Ord(MenuSendAB.Checked)) + IntToStr(Ord(MenuResetChip.Checked)) +
    '|' + IntToStr(Ord(CheckBox_I2C_A0.Checked)) +
    IntToStr(Ord(CheckBox_I2C_A1.Checked)) + IntToStr(Ord(CheckBox_I2C_A2.Checked)) +
    '|' + IntToStr(Ord(SafeModeActive)) + '|' +
    IntToStr(Ord(ProdSettings.SNEnabled)) + '|' +
    IntToStr(ProdSettings.SNValue) + '|' + IntToStr(Ord(ProdSettings.SNMode)) +
    '|' + IntToStr(ProdSettings.SNAddress) + '|' +
    IntToStr(ProdSettings.SNLength) + '|' +
    IntToStr(Ord(ProdSettings.SNBigEndian)) + '|' +
    ProdSettings.JobFile + '|' + StrictProductionProfileHash + '|' +
    StrictProductionImageHash + '|' + RecoveryRequestedPath;
end;

function TMainForm.PresentDirectWrite(const Description: string): boolean;
var
  Stream: TMemoryStream;
  Data: TBytes;
  Err: string;
begin
  Result := False;
  if OperationRunning then Exit;
  if MPHexEditorEx.DataSize = 0 then
  begin
    ShowInlineNotice('Open an image before preparing a write.');
    Exit;
  end;
  Stream := TMemoryStream.Create;
  try
    MPHexEditorEx.SaveToStream(Stream);
    SetLength(Data, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if not WriteInputIdentity(nil, Data, CurrentWriteContext, InlinePlanIdentity, Err) then
  begin
    ShowInlineNotice('Cannot prepare the image: ' + Err);
    Exit;
  end;
  if WriteGate = nil then WriteGate := TInlineWriteGate.Create;
  Result := WriteGate.Present(CurrentWriteContext, InlinePlanIdentity,
    not SmartWritePlanOnly);
  InlinePlanText := Description + LineEnding + 'Chip: ' + CurrentICParam.Name +
    LineEnding + 'Image: ' + IntToStr(Length(Data)) + ' bytes. Capacity: ' +
    ComboChipSize.Text + ' bytes.';
  if Result then InlineNotice := 'Writing. Backup and verification run automatically.'
  else InlineNotice := 'Review the operation below, then press Write.';
  UpdateInlineWrite;
end;

procedure TMainForm.CreateInlineWritePanel;

  procedure MakeAction(out Button: TButton; const Text: string; Width96: integer);
  begin
    Button := TButton.Create(Self);
    Button.Parent := FWriteActions;
    Button.Caption := Text;
    Button.Align := alLeft;
    Button.Width := Scale96ToForm(Width96);
    Button.OnClick := @InlineWriteClick;
  end;

begin
  WriteGate := TInlineWriteGate.Create;
  FWritePanel := TPanel.Create(Self);
  FWritePanel.Parent := Self;
  FWritePanel.Name := 'WritePlanPanel';
  FWritePanel.Caption := '';
  FWritePanel.Align := alBottom;
  FWritePanel.Height := Scale96ToForm(206);
  FWritePanel.BevelOuter := bvNone;
  FWritePanel.BorderWidth := Scale96ToForm(8);
  FWritePanel.Visible := False;

  FRecoveryRow := TPanel.Create(Self);
  FRecoveryRow.Parent := FWritePanel;
  FRecoveryRow.Caption := '';
  FRecoveryRow.BevelOuter := bvNone;
  FRecoveryRow.Align := alBottom;
  FRecoveryRow.Height := Scale96ToForm(34);
  FRecoveryPrepare := TButton.Create(Self);
  FRecoveryPrepare.Name := 'RecoverInterruptedWrite';
  FRecoveryPrepare.Parent := FRecoveryRow;
  FRecoveryPrepare.Caption := 'Prepare interrupted write';
  FRecoveryPrepare.Align := alRight;
  FRecoveryPrepare.Width := Scale96ToForm(210);
  FRecoveryPrepare.OnClick := @RecoveryPrepareClick;
  FRecoveryList := TComboBox.Create(Self);
  FRecoveryList.Name := 'InterruptedWrites';
  FRecoveryList.Parent := FRecoveryRow;
  FRecoveryList.Style := csDropDownList;
  FRecoveryList.Align := alClient;
  FRecoveryList.ShowHint := True;
  FRecoveryList.Hint := 'Unfinished writes. Preparation checks the original backup, image, and connected chip.';

  FProfileRow := TPanel.Create(Self);
  FProfileRow.Parent := FWritePanel;
  FProfileRow.Caption := '';
  FProfileRow.BevelOuter := bvNone;
  FProfileRow.Align := alBottom;
  FProfileRow.Height := Scale96ToForm(34);
  FUseProfile := TButton.Create(Self);
  FUseProfile.Name := 'UseMatchingChipProfile';
  FUseProfile.Parent := FProfileRow;
  FUseProfile.Caption := 'Use chip profile';
  FUseProfile.Align := alRight;
  FUseProfile.Width := Scale96ToForm(210);
  FUseProfile.OnClick := @UseProfileClick;
  FProfileList := TComboBox.Create(Self);
  FProfileList.Name := 'MatchingChipProfiles';
  FProfileList.Parent := FProfileRow;
  FProfileList.Style := csDropDownList;
  FProfileList.Align := alClient;
  FProfileList.AccessibleName := 'Matching chip profiles';

  FWriteActions := TPanel.Create(Self);
  FWriteActions.Parent := FWritePanel;
  FWriteActions.Caption := '';
  FWriteActions.BevelOuter := bvNone;
  FWriteActions.Align := alBottom;
  FWriteActions.Height := Scale96ToForm(34);
  MakeAction(FWriteCommit, 'Write', 136);
  FWriteCommit.Name := 'CommitPreparedWrite';
  FWriteCommit.Font.Style := [fsBold];
  MakeAction(FWritePrepare, 'Prepare again', 150);
  MakeAction(FOpenBackups, 'Open backups', 140);
  MakeAction(FConnectionHelp, 'Connection help', 156);

  FWriteSummary := TMemo.Create(Self);
  FWriteSummary.Name := 'WritePlanSummary';
  FWriteSummary.Parent := FWritePanel;
  FWriteSummary.Align := alClient;
  FWriteSummary.ReadOnly := True;
  FWriteSummary.ScrollBars := ssVertical;
  FWriteSummary.WordWrap := True;
  FWriteSummary.AccessibleName := 'Write plan and operation result';
end;

procedure TMainForm.UpdateInlineWrite;
var
  Ready: boolean;
  DisplayText: string;
begin
  if FWritePanel = nil then Exit;
  Ready := (WriteGate <> nil) and WriteGate.ReadyFor(CurrentWriteContext);
  DisplayText := InlineNotice;
  if LastOp.Started and LastOp.Failed and (not OperationRunning) then
    DisplayText := LastOp.ErrorText + LineEnding + DisplayText;
  if InlinePlanText <> '' then
  begin
    if (not Ready) and (not OperationRunning) then
      DisplayText := DisplayText + LineEnding + 'Prepare again after changing the image or setup.';
    DisplayText := DisplayText + LineEnding + InlinePlanText;
  end;
  if FWriteSummary.Text <> DisplayText then FWriteSummary.Text := DisplayText;
  FWriteCommit.Enabled := Ready and ProgrammerPresent and
    (not SafeModeActive) and (not OperationRunning);
  FWritePrepare.Enabled := ProgrammerPresent and (not OperationRunning) and
    (MPHexEditorEx.DataSize > 0);
  FOpenBackups.Enabled := not OperationRunning;
  FConnectionHelp.Enabled := not OperationRunning;
  FRecoveryPrepare.Enabled := ProgrammerPresent and (not OperationRunning) and
    (FRecoveryList.Items.Count > 0);
  FRecoveryRow.Visible := FRecoveryList.Items.Count > 0;
  FProfileRow.Visible := FProfileList.Items.Count > 0;
  FUseProfile.Enabled := (FProfileList.ItemIndex >= 0) and (not OperationRunning);
  FProfileList.Enabled := not OperationRunning;
  FWritePanel.Height := Scale96ToForm(172 + 34 * Ord(FRecoveryRow.Visible) +
    34 * Ord(FProfileRow.Visible));
  FWritePanel.Visible := (Trim(DisplayText) <> '') or FRecoveryRow.Visible or
    FProfileRow.Visible;
  if MenuDarkTheme.Checked then
  begin
    FWriteSummary.Color := DARK_SURFACE;
    FWriteSummary.Font.Color := DARK_TEXT;
  end
  else
  begin
    FWriteSummary.Color := clWindow;
    FWriteSummary.Font.Color := clWindowText;
  end;
end;

procedure TMainForm.InlineWriteClick(Sender: TObject);
var
  DriverDir: string;
begin
  if OperationRunning then Exit;
  FAutoPreparePending := False;
  if Sender = FOpenBackups then
  begin
    if ForceDirectories(WorkBackupDirectory) then
      OpenDocument(WorkBackupDirectory);
    Exit;
  end;
  if Sender = FConnectionHelp then
  begin
    DriverDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'drivers';
    if not DirectoryExists(DriverDir) then DriverDir := ExpandFileName('drivers');
    ShowInlineNotice('Select the programmer in Hardware, connect its USB cable, ' +
      'then scan again. Match the driver to that programmer. Driver files: ' +
      DriverDir + '. Connection Doctor is available in Options for details.');
    if DirectoryExists(DriverDir) then OpenDocument(DriverDir);
    Exit;
  end;
  CommitInlineWrite := Sender = FWriteCommit;
  try
    if CommitInlineWrite then ButtonWriteClick(Sender)
    else MenuSmartWritePreviewClick(Sender);
  finally
    CommitInlineWrite := False;
    UpdateWorkflowState;
  end;
end;

procedure TMainForm.RefreshRecoveryList;
var
  Paths: TStringList;
  I: integer;
  Selected: string;

  procedure Scan(const Directory: string);
  var
    Found: TSearchRec;
    Name: string;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.journal',
      faAnyFile, Found) <> 0 then Exit;
    try
      repeat
        if (Found.Attr and faDirectory) <> 0 then Continue;
        Name := ExpandFileName(IncludeTrailingPathDelimiter(Directory) + Found.Name);
        if Paths.IndexOf(Name) < 0 then Paths.Add(Name);
      until FindNext(Found) <> 0;
    finally
      FindClose(Found);
    end;
  end;

begin
  if FRecoveryList = nil then Exit;
  Selected := FRecoveryList.Text;
  Paths := TStringList.Create;
  try
    Scan(WorkBackupDirectory);
    Scan(ExpandFileName('backup'));
    Scan(ExtractFilePath(ParamStr(0)) + 'backup');
    Paths.Sort;
    FRecoveryList.Items.BeginUpdate;
    try
      FRecoveryList.Items.Clear;
      for I := Paths.Count - 1 downto 0 do FRecoveryList.Items.Add(Paths[I]);
      FRecoveryList.ItemIndex := FRecoveryList.Items.IndexOf(Selected);
      if (FRecoveryList.ItemIndex < 0) and (Paths.Count > 0) then
        FRecoveryList.ItemIndex := 0;
    finally
      FRecoveryList.Items.EndUpdate;
    end;
  finally
    Paths.Free;
  end;
  UpdateInlineWrite;
end;

procedure TMainForm.RecoveryPrepareClick(Sender: TObject);
var
  Journal: TWriteJournal;
  Found: boolean;
  Data: TBytes;
  Err, Path: string;
  Stream: TMemoryStream;
begin
  if OperationRunning or (FRecoveryList.ItemIndex < 0) then Exit;
  Path := FRecoveryList.Text;
  if not LoadJournal(Path, Journal, Found, Err) or not Found then
  begin
    ShowInlineNotice('Cannot read recovery: ' + Err);
    Exit;
  end;
  if (Journal.Header.ImagePath = '') or (Journal.Header.GeometryHash = '') then
  begin
    ShowInlineNotice('This older journal has no saved recovery image. Open its ' +
      'original backup to restore it: ' + Journal.Header.BackupPath);
    Exit;
  end;
  if ProdSettings.SNEnabled or StrictProductionMode then
  begin
    ShowInlineNotice('Recovery uses the original saved serial and image. ' +
      'Turn off new serial allocation before preparing recovery.');
    Exit;
  end;
  if not ReadRecoveryBytes(Journal.Header.ImagePath, Journal.Header.Length,
    Data, Err) then
  begin
    ShowInlineNotice('Recovery image unavailable: ' + Err);
    Exit;
  end;
  if not SelectChipAny(Journal.Header.ChipName + '@' + Journal.Header.ChipJedecID) then
  begin
    ShowInlineNotice('Select the original chip profile for ' +
      Journal.Header.ChipName + ' / ' + Journal.Header.ChipJedecID + '.');
    Exit;
  end;
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    MPHexEditorEx.LoadFromStream(Stream);
  finally
    Stream.Free;
  end;
  NoteBufferFromFile(Journal.Header.ImagePath);
  StartAddressEdit.Text := IntToHex(Journal.Header.Address, 6);
  RecoveryRequestedPath := Path;
  FAutoPreparePending := False;
  MenuSmartWritePreviewClick(Sender);
end;

procedure TMainForm.PresentProfileChoices(Choices: TStrings);
begin
  if FProfileList = nil then Exit;
  FProfileList.Items.Assign(Choices);
  if Choices.Count > 0 then FProfileList.ItemIndex := 0;
  ShowInlineNotice('Several profiles share this chip ID. Match the marking on ' +
    'the chip to a profile below, then select Use chip profile.');
end;

procedure TMainForm.UseProfileClick(Sender: TObject);
var
  Selection: string;
  At: integer;
begin
  if OperationRunning or (FProfileList.ItemIndex < 0) then Exit;
  Selection := FProfileList.Text;
  At := Pos(' (', Selection);
  if At > 0 then Selection := Copy(Selection, 1, At - 1);
  if not SelectChipAny(Selection) then
  begin
    ShowInlineNotice('Cannot load this chip profile. Select another matching profile.');
    Exit;
  end;
  ChipIdentityConfirmed := (LastID9F <> '') and
    SameText(CurrentICParam.ID, LastID9F);
  FProfileList.Items.Clear;
  FAutoPreparePending := MPHexEditorEx.DataSize > 0;
  ShowInlineNotice('Chip profile selected: ' + CurrentICParam.Name);
  UpdateWorkflowState;
end;

function TMainForm.LoadImageFile(const FileName: string): boolean;
var
  Stream: TMemoryStream;
  BlankByte: byte;
  Err: string;
begin
  Result := False;
  if WriteGate <> nil then WriteGate.Clear;
  InlinePlanText := '';
  FAutoPreparePending := False;
  Stream := TMemoryStream.Create;
  try
    try
      if DetectFormat(FileName) = ffBinary then
        Stream.LoadFromFile(FileName)
      else
      begin
        BlankByte := $FF;
        if RadioSPI.Checked and (ComboSPICMD.ItemIndex = SPI_CMD_KB) then
          BlankByte := $00;
        if not LoadFirmware(FileName, Stream, UIChipSize, BlankByte, Err) then
        begin
          ShowInlineNotice('Cannot open this image: ' + Err);
          Exit;
        end;
        if Err <> '' then LogPrint(Err);
      end;
      Stream.Position := 0;
      MPHexEditorEx.LoadFromStream(Stream);
      StatusBar.Panels.Items[2].Text := FileName;
      NoteBufferFromFile(FileName);
      LogPrint(STR_FILE_LOADED + ExtractFileName(FileName) + ' (' +
        IntToStr(Stream.Size) + ' bytes)');
      Result := True;
    except
      on E: Exception do
        ShowInlineNotice('Cannot open this image: ' + E.Message);
    end;
  finally
    Stream.Free;
  end;
end;
