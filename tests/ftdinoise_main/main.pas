unit main;

{$mode objfpc}{$H+}

interface

procedure LogPrint(Text: string);
procedure ResetCapturedLog;
function CapturedLog: string;

implementation

var
  LogText: string = '';

procedure LogPrint(Text: string);
begin
  if LogText <> '' then LogText := LogText + LineEnding;
  LogText := LogText + Text;
end;

procedure ResetCapturedLog;
begin
  LogText := '';
end;

function CapturedLog: string;
begin
  Result := LogText;
end;

end.
