unit recoveryworkflow;

// Durable recovery inputs and reconstruction. A journal is history, never
// authority to skip physical checks. Rebuild the desired whole chip from the
// original backup plus patch, then compare it with a fresh trusted live read.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, operationmodel, norplanner, writeworkflow, writejournal;

function SaveRecoveryInputs(const BackupPath: string;
  const Job: TPreparedNORWrite; const Version: string;
  out JournalPath, ErrorText: string): boolean;
function PrepareRecovery(const JournalPath: string;
  const LiveRequest: TOperationRequest; const Geometry: TNORGeometry;
  const LiveSnapshot: TBytes; const Context: string;
  out Job: TPreparedNORWrite; out Header: TJournalHeader;
  out ErrorText: string): boolean;
function ReadRecoveryBytes(const FileName: string; ExpectedSize: QWord;
  out Data: TBytes; out ErrorText: string): boolean;

function WriteInputIdentity(const Snapshot, Patch: TBytes; const Binding: string;
  out Identity, ErrorText: string): boolean;

implementation

uses
  DateUtils, prodcrypto, prodevidence;

function HashBytes(const Data: TBytes; out Hash, ErrorText: string): boolean;
var
  Digest: TSHA256Digest;
begin
  Hash := '';
  Result := SHA256Bytes(Data, Digest, ErrorText);
  if Result then Hash := LowerCase(DigestToHex(Digest));
end;

function WriteInputIdentity(const Snapshot, Patch: TBytes; const Binding: string;
  out Identity, ErrorText: string): boolean;
var
  BeforeHash, ImageHash: string;
begin
  Identity := '';
  Result := HashBytes(Snapshot, BeforeHash, ErrorText) and
    HashBytes(Patch, ImageHash, ErrorText);
  if Result then Identity := BeforeHash + ':' + ImageHash + ':' + Binding;
end;

function GeometryHash(const Geometry: TNORGeometry;
  out Hash, ErrorText: string): boolean;
var
  Text: RawByteString;
  Bytes: TBytes;
begin
  Text := NORGeometryIdentity(Geometry);
  SetLength(Bytes, Length(Text));
  if Length(Text) > 0 then Move(Text[1], Bytes[0], Length(Text));
  Result := HashBytes(Bytes, Hash, ErrorText);
end;

function ReadRecoveryBytes(const FileName: string; ExpectedSize: QWord;
  out Data: TBytes; out ErrorText: string): boolean;
var
  Stream: TFileStream;
begin
  Data := nil;
  ErrorText := '';
  Result := False;
  if (ExpectedSize = 0) or (ExpectedSize > QWord(High(SizeInt))) then
  begin
    ErrorText := 'the recovery image size is not usable in this build';
    Exit;
  end;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      if QWord(Stream.Size) <> ExpectedSize then
      begin
        ErrorText := 'the recovery file size changed: ' + FileName;
        Exit;
      end;
      SetLength(Data, SizeInt(ExpectedSize));
      Stream.ReadBuffer(Data[0], Length(Data));
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on E: Exception do ErrorText := E.Message;
  end;
end;

function SaveRecoveryInputs(const BackupPath: string;
  const Job: TPreparedNORWrite; const Version: string;
  out JournalPath, ErrorText: string): boolean;
var
  Header: TJournalHeader;
  Backup, Patch: TBytes;
  Digest: string;
begin
  Result := False;
  JournalPath := ExpandFileName(BackupPath) + '.journal';
  ErrorText := '';
  if Job = nil then
  begin
    ErrorText := 'no prepared job exists';
    Exit;
  end;
  if FileExists(JournalPath) or FileExists(JournalPath + '.image') then
  begin
    ErrorText := 'an existing recovery bundle must not be replaced';
    Exit;
  end;
  Header := Default(TJournalHeader);
  Header.ProgramVersion := Version;
  Header.StartedUtc := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
  Header.ChipName := Job.Request.Chip.Name;
  Header.ChipJedecID := Job.Request.Chip.JedecID;
  Header.ChipUID := Job.Request.Chip.UniqueID;
  Header.ChipCapacity := Job.Request.Chip.Capacity;
  Header.Address := Job.Request.Target.Address;
  Header.Length := Job.Request.Target.Length;
  Header.BackupPath := ExpandFileName(BackupPath);
  Header.ImagePath := JournalPath + '.image';
  if not ReadRecoveryBytes(Header.BackupPath, Header.ChipCapacity,
    Backup, ErrorText) then Exit;
  if not HashBytes(Backup, Header.BackupSha256, ErrorText) then Exit;
  if not HashBytes(Job.Snapshot, Digest, ErrorText) then Exit;
  if Digest <> Header.BackupSha256 then
  begin
    ErrorText := 'the backup does not contain the prepared original snapshot';
    Exit;
  end;
  Patch := Job.Patch;
  if not HashBytes(Patch, Header.ImageSha256, ErrorText) then Exit;
  if not GeometryHash(Job.Geometry, Header.GeometryHash, ErrorText) then Exit;
  if not AtomicWriteDurable(Header.ImagePath, Patch, False, ErrorText) then Exit;
  Result := BeginJournal(JournalPath, Header, ErrorText);
end;

function PrepareRecovery(const JournalPath: string;
  const LiveRequest: TOperationRequest; const Geometry: TNORGeometry;
  const LiveSnapshot: TBytes; const Context: string;
  out Job: TPreparedNORWrite; out Header: TJournalHeader;
  out ErrorText: string): boolean;
var
  Journal: TWriteJournal;
  Found: boolean;
  Backup, Patch, Desired: TBytes;
  Hash: string;
  Request: TOperationRequest;
begin
  Result := False;
  Job := nil;
  Header := Default(TJournalHeader);
  if not LoadJournal(JournalPath, Journal, Found, ErrorText) then Exit;
  if not Found then
  begin
    ErrorText := 'the interrupted job journal was not found';
    Exit;
  end;
  Header := Journal.Header;
  if (Header.GeometryHash = '') or (Header.ImagePath = '') then
  begin
    ErrorText := 'this older journal has no bound geometry or saved image; ' +
      'open its original backup to restore the chip';
    Exit;
  end;
  if not SameText(Header.ChipJedecID, LiveRequest.Chip.JedecID) or
     (Header.ChipCapacity <> LiveRequest.Chip.Capacity) or
     (Header.ChipCapacity <> Geometry.ChipSize) or
     (QWord(Length(LiveSnapshot)) <> Geometry.ChipSize) or
     ((Header.ChipUID <> '') and
      not SameText(Header.ChipUID, LiveRequest.Chip.UniqueID)) then
  begin
    ErrorText := 'the connected chip does not match the interrupted job';
    Exit;
  end;
  if not GeometryHash(Geometry, Hash, ErrorText) then Exit;
  if Hash <> Header.GeometryHash then
  begin
    ErrorText := 'the chip geometry or erase commands changed';
    Exit;
  end;
  if (Header.Address >= Geometry.ChipSize) or
     (Header.Length > Geometry.ChipSize - Header.Address) then
  begin
    ErrorText := 'the recorded image range is outside this chip';
    Exit;
  end;
  if not ReadRecoveryBytes(Header.BackupPath, Geometry.ChipSize,
    Backup, ErrorText) then Exit;
  if not HashBytes(Backup, Hash, ErrorText) then Exit;
  if Hash <> Header.BackupSha256 then
  begin
    ErrorText := 'the original recovery backup changed';
    Exit;
  end;
  if not ReadRecoveryBytes(Header.ImagePath, Header.Length,
    Patch, ErrorText) then Exit;
  if not HashBytes(Patch, Hash, ErrorText) then Exit;
  if Hash <> Header.ImageSha256 then
  begin
    ErrorText := 'the accepted recovery image changed';
    Exit;
  end;
  Desired := Copy(Backup);
  Move(Patch[0], Desired[SizeInt(Header.Address)], Length(Patch));
  Request := LiveRequest;
  Request.Target.Address := 0;
  Request.Target.Length := Geometry.ChipSize;
  if not HashBytes(Desired, Request.ImageHash, ErrorText) then Exit;
  Request.Policy.RequireTrustedBackup := True;
  Request.Policy.RequireFullVerify := True;
  Request.Policy.PreserveOutsideRange := True;
  Result := TPreparedNORWrite.Prepare(Request, Geometry, LiveSnapshot,
    Desired, Context, Job, ErrorText);
end;

end.
