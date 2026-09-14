program chipcatalog_tests;

{$mode objfpc}{$H+}

uses Classes, SysUtils, DOM, XMLRead, chipcatalog;

var
  Doc, ResolvedDoc: TXMLDocument;
  Node: TDOMNode;
  Input: TStringStream;
  Err: string;
  Checks, Failures: integer;

procedure Check(Value: boolean; const Description: string);
begin
  Inc(Checks);
  if not Value then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Description);
  end;
end;

begin
  Doc := nil;
  Input := TStringStream.Create('<chiplist><SPI><WINBOND>' +
    '<W25Q256JV-EF4019 alias="W25Q256JV" id="EF4019" size="33554432"/>' +
    '<W25Q256JV-EF7019 alias="W25Q256JV" id="EF7019" size="33554432"/>' +
    '<UNIQUE id="ABCDEF" size="1024"/>' +
    '</WINBOND></SPI></chiplist>');
  try
    ReadXMLFile(Doc, Input);
    Check(not ResolveChipSelection([Doc], 'W25Q256JV', ResolvedDoc, Node, Err),
      'ambiguous legacy model names are refused');
    Check((Node = nil) and (Pos('EF4019', Err) > 0) and (Pos('EF7019', Err) > 0),
      'refusal names both actionable choices');
    Check(ResolveChipSelection([Doc], 'W25Q256JV@EF7019', ResolvedDoc, Node, Err),
      'legacy name plus live ID identifies the exact variant');
    Check(ChipSelectionKey(Node) = 'W25Q256JV-EF7019@EF7019',
      'selected key retains the exact JEDEC identity');
    Check(ResolveChipSelection([Doc], 'w25q256jv-ef4019', ResolvedDoc, Node, Err),
      'canonical model selection is case insensitive');
    Check(ResolveChipSelection([nil, Doc], 'UNIQUE', ResolvedDoc, Node, Err),
      'unambiguous legacy selections keep working');
    Check(not ResolveChipSelection([Doc], 'W25Q256JV@BADBAD', ResolvedDoc, Node, Err),
      'an unrecognized identity cannot fall back to a similarly named part');
  finally
    Doc.Free;
    Input.Free;
  end;
  WriteLn(Checks, ' assertions, ', Failures, ' failures');
  if Failures > 0 then Halt(1);
  WriteLn('ALL PASSED');
end.
