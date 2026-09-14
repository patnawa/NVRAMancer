unit uilanguage;

{$mode objfpc}{$H+}

interface

// English ships inside the executable. Optional catalogs are resolved beside
// the executable so shortcuts do not depend on their working directory.
function LanguageDirectory: string;
procedure ApplyUILanguage(var Language: string);

implementation

uses
  Classes, SysUtils, LazFileUtils, LResources, LCLTranslator, Translations;

function LanguageDirectory: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'lang';
  if not DirectoryExistsUTF8(Result) then
    Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'lang';
  Result := IncludeTrailingPathDelimiter(Result);
end;

procedure ApplyUILanguage(var Language: string);
var
  Catalog: TPOFile;
  Stream: TLazarusResourceStream;
  FileName: string;
  Translator: TPOTranslator;
begin
  Catalog := nil;
  if Language = '' then Language := 'en';
  if Language <> 'en' then
  begin
    FileName := LanguageDirectory + ExtractFileName(Language) + '.po';
    if FileExistsUTF8(FileName) then
      try
        Catalog := TPOFile.Create(FileName, True);
      except
        // A missing or unreadable optional catalog must not interrupt startup.
        Catalog := nil;
      end;
  end;
  if Catalog = nil then
  begin
    Language := 'en';
    Stream := TLazarusResourceStream.Create('en', nil);
    try
      Catalog := TPOFile.Create(Stream, True);
    finally
      Stream.Free;
    end;
  end;
  try
    Translations.TranslateResourceStrings(Catalog);
    Translator := TPOTranslator.Create(Catalog);
    Catalog := nil; // the translator owns the catalog
    LRSTranslator.Free;
    LRSTranslator := Translator;
  finally
    Catalog.Free;
  end;
end;

initialization
  // Regenerate with: lazres software/englishcatalog.lrs software/lang/en.po
  {$I englishcatalog.lrs}

end.
