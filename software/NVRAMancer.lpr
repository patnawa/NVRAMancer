program NVRAMancer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Interfaces, // บรรทัดนี้ดึง widgetset ของ LCL เข้ามา
  Forms, main, i2c, microwire,
  spi95, search, sregedit, findchip, ScriptEdit, spi25, cli;

{$R *.res}

var
  CLIStatus: integer;

begin
  LoadXML;
  Translate(SettingsFile);
  RequireDerivedFormResource := True;
  Application.Scaled:=True;
  Application.Initialize;

  //โหมดบรรทัดคำสั่งยังสร้างหน้าต่างเหมือนเดิม เพราะงานทั้งหมดอยู่บนนั้น
  //เพียงแต่ไม่แสดงให้เห็น วิธีนี้ทำให้ไม่ต้องมีโค้ดสองชุดที่ต้องดูแลให้ตรงกัน
  if cli.WantsCLI then
  begin
    Application.ShowMainForm := False;
    //Set this before FormCreate.  Startup hardware scanning belongs to the
    //interactive application; a rejected CLI request must reach RunCLI's
    //outer admission checks before any programmer or external tool is opened.
    CLIMode := True;
  end;

  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TSearchForm, SearchForm);
  Application.CreateForm(TsregeditForm, sregeditForm);
  Application.CreateForm(TChipSearchForm, ChipSearchForm);
  Application.CreateForm(TScriptEditForm, ScriptEditForm);

  if cli.WantsCLI then
  begin
    CLIStatus := cli.RunCLI;
    Halt(CLIStatus);
  end;

  Application.Run;
end.
