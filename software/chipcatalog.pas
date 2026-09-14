unit chipcatalog;

// Deterministic profile selection, independent of menu captions and LCL.
// Legacy aliases are accepted only when they resolve to one profile. Catalog
// priority is explicit in Documents; ambiguity never falls through to another.

{$mode objfpc}{$H+}

interface

uses SysUtils, DOM;

function ChipSelectionKey(Node: TDOMNode): string;
function ResolveChipSelection(const Documents: array of TXMLDocument;
  const Selection: string; out Document: TXMLDocument; out Chip: TDOMNode;
  out ErrorText: string): boolean;

implementation

function Attribute(Node: TDOMNode; const Name: string): string;
var
  A: TDOMNode;
begin
  Result := '';
  if (Node = nil) or (Node.Attributes = nil) then Exit;
  A := Node.Attributes.GetNamedItem(UTF8Decode(Name));
  if A <> nil then Result := UTF8Encode(A.NodeValue);
end;

function ChipSelectionKey(Node: TDOMNode): string;
var
  ID: string;
begin
  Result := UTF8Encode(Node.NodeName);
  ID := UpperCase(Attribute(Node, 'id'));
  if (ID <> '') and (ID <> '0') then Result := Result + '@' + ID;
end;

function ResolveChipSelection(const Documents: array of TXMLDocument;
  const Selection: string; out Document: TXMLDocument; out Chip: TDOMNode;
  out ErrorText: string): boolean;
var
  I, Matches: integer;
  Choices: string;

  procedure Visit(Node: TDOMNode);
  var
    Child: TDOMNode;
    Name, Alias, ID: string;
    Match: boolean;
  begin
    if Node = nil then Exit;
    if Attribute(Node, 'size') <> '' then
    begin
      Name := UTF8Encode(Node.NodeName);
      Alias := Attribute(Node, 'alias');
      ID := UpperCase(Attribute(Node, 'id'));
      Match := SameText(Selection, Name) or SameText(Selection, ChipSelectionKey(Node));
      if Alias <> '' then
        Match := Match or SameText(Selection, Alias) or
          ((ID <> '') and SameText(Selection, Alias + '@' + ID));
      if Match then
      begin
        Inc(Matches);
        Chip := Node;
        if Choices <> '' then Choices := Choices + ', ';
        Choices := Choices + Name;
      end;
    end;
    Child := Node.FirstChild;
    while Child <> nil do
    begin
      Visit(Child);
      Child := Child.NextSibling;
    end;
  end;

begin
  Result := False;
  Document := nil;
  Chip := nil;
  ErrorText := '';
  if Trim(Selection) = '' then Exit;
  for I := 0 to High(Documents) do
  begin
    if Documents[I] = nil then Continue;
    Matches := 0;
    Choices := '';
    Visit(Documents[I].DocumentElement);
    if Matches > 1 then
    begin
      Chip := nil;
      ErrorText := 'Choose the chip variant that matches its ID: ' + Choices;
      Exit;
    end;
    if Matches = 1 then
    begin
      Document := Documents[I];
      Exit(True);
    end;
  end;
  ErrorText := 'No chip profile matches ' + Selection;
end;

end.
