program ftdinoise_tests;

{$mode objfpc}{$H+}

uses
  SysUtils, main, D2XXUnit;

var
  Status: FT_Result;
  Output: string;
begin
  FT_Enable_Error_Report := True;
  ResetCapturedLog;
  Status := Open_USB_Device;
  Output := CapturedLog;

  if Status <> FT_DEVICE_NOT_FOUND then
  begin
    WriteLn('FAIL: absent FTDI device returned status ', Status);
    Halt(1);
  end;
  if Output <> '' then
  begin
    WriteLn('FAIL: idle no-device probe logged: ', Output);
    Halt(1);
  end;

  WriteLn('ALL PASSED');
end.
