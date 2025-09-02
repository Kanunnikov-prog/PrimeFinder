program PrimeFinder;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  SyncObjs,
  Generics.Collections,
  IOUtils, System.Hash;

const
  MAX_NUMBER = 1000000;

type
  TFieldOfNumbers = class(TObject)
  private
    FAvailableJobs: TList<Integer>;
    FLock: TCriticalSection;
    FMinRange, FMaxRange: Integer;
  public
    constructor Create(MinRange, MaxRange: Integer);
    destructor Destroy; override;
    function TakeJob(out Job: Integer): Boolean;
    property MinRange: Integer read FMinRange write FMinRange;
    property MaxRange: Integer read FMaxRange write FMaxRange;
  end;

type
  TFileWriterThread = class(TThread)
  private
    FBuffer: TList<Integer>;
    FLock: TCriticalSection;
    procedure WriteRecordsToFile(const FileName: string);
  protected
    procedure Execute; override;
  public
    constructor Create;
    procedure AddRecord(Rec: Integer);
  end;

type
  TPrimeFinderThread = class(TThread)
  private
    FThreadNum: Integer;
    FFieldOfNumbers: TFieldOfNumbers;
    FWriterThread: TFileWriterThread;
    FFoundPrimes: TList<Integer>;
    FPrecomputedPrimes: TArray<Integer>;
    function IsPrime(n: Integer): Boolean;
    procedure ProcessJob(Job: Integer);
    procedure WritePersonalResults(const FileName: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ThreadNum: Integer; FieldOfNumbers: TFieldOfNumbers;
                       WriterThread: TFileWriterThread; PrecompPrimes: TArray<Integer>);
  end;

// ������� MD5 � ������� �� �����
procedure CalculateMD5(const FileName: string);
var
  FileContent: TFileStream;
  ContentAsBytes: TArray<Byte>;
  ContentAsString: RawByteString;
begin
  if not FileExists(FileName) then
  begin
    Writeln('���� �� ������.');
    Exit;
  end;

  FileContent := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(ContentAsBytes, FileContent.Size);
    FileContent.ReadBuffer(ContentAsBytes[0], FileContent.Size);

    ContentAsString := TEncoding.ANSI.GetString(ContentAsBytes);

    Writeln(Format('MD5 hash %s %s', [
      FileName,
      THashMD5.GetHashString(ContentAsString)]));
  finally
    FileContent.Free;
  end;
end;

// ��������� ������ ������� ����� � ������� ������ ����������
//�� ����������� ����� �� limit (����� �������� ����� ������� �����)
function GeneratePrimes(limit: Integer): TArray<Integer>;
var
  sieve: TArray<Boolean>;
  i, j: Integer;
begin
  SetLength(sieve, limit + 1);
  FillChar(sieve[0], SizeOf(Boolean) * Length(sieve), True);
  sieve[0] := False;
  sieve[1] := False;

  for i := 2 to Trunc(Sqrt(limit)) do
    if sieve[i] then
      for j := i * i to limit do
        if ((j mod i) = 0) then
          sieve[j] := False;

  SetLength(Result, 0);
  for i := 2 to limit do
    if sieve[i] then
    begin
      SetLength(Result, Length(Result)+1);
      Result[High(Result)] := i;
    end;
end;

// �������� �������� ����
constructor TFieldOfNumbers.Create(MinRange, MaxRange: Integer);
var
  i: Integer;
begin
  inherited Create;
  FAvailableJobs := TList<Integer>.Create();
  FLock := TCriticalSection.Create();
  FMinRange := MinRange;
  FMaxRange := MaxRange;
  // ��������� ������ � �������� �������
  //(����� ����� �������� ������ ����� � ������� �����, ����� ������ �� �������������� � �� ����� �� ��� �������)
  for i := MaxRange downto MinRange do
    FAvailableJobs.Add(i);
end;

// �������� �������� ����
destructor TFieldOfNumbers.Destroy;
begin
  FAvailableJobs.Free;
  FLock.Free;
  inherited Destroy;
end;

// ������ �������
function TFieldOfNumbers.TakeJob(out Job: Integer): Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if FAvailableJobs.Count > 0 then
    begin
      Job := FAvailableJobs.Last; // ���� ��������� �����
      FAvailableJobs.Delete(FAvailableJobs.Count - 1);
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

// ����������� ������ ��� ������ � ����
constructor TFileWriterThread.Create;
begin
  inherited Create(True); // ������� ����� ����������������
  FreeOnTerminate := False; // �� ���������� ����� �������������
  FBuffer := TList<Integer>.Create();
  FLock := TCriticalSection.Create();
  Resume; // ��������� �����
end;

// ��������� ������ ����������� � ����
procedure TFileWriterThread.WriteRecordsToFile(const FileName: string);
var
  f: TextFile;
  Prime: Integer;
begin
  try
    AssignFile(f, FileName);
    Rewrite(f);
    try
      // ���������� ��� ����� �� ������ � ���� ����� ������
      for Prime in FBuffer do
        Write(f, Format('%d ', [Prime]));
    finally
      CloseFile(f);
    end;
  except
    on E: Exception do
      Writeln('������ ������ � ���� ' + FileName + ': ' + E.Message);
  end;
end;

// �������� ��������� ������ ��� ������ � ����
// (�� ������� �������, ���� ������ ����������� ����� ��� ���������� ���������� �����)
// ������ ����� ������ - �������� �� ����
// ���� �� �� ���������� �������, �� ����� ���� �� ���������� ������ ���� ������� � ����� � �������� ����.
procedure TFileWriterThread.Execute;
const
  OldCount: Integer = 0;
begin
  while not Terminated do
  begin
    if (FBuffer.Count > 0) and (FBuffer.Count > OldCount) then
    begin
      // ��������� ����� ����� �������
      FBuffer.Sort;
      WriteRecordsToFile('Result.txt');
      OldCount := FBuffer.Count;
    end
    else
      Sleep(100); // �������� ���, ���� ������ ������
  end;
end;

// ���������� ������ � �����
procedure TFileWriterThread.AddRecord(Rec: Integer);
begin
  FLock.Enter;
  try
    FBuffer.Add(Rec); // ������ ��������� ����� � ����� ������
  finally
    FLock.Leave;
  end;
end;

// ����������� ������ ���������� �������� �����
constructor TPrimeFinderThread.Create(ThreadNum: Integer; FieldOfNumbers: TFieldOfNumbers; WriterThread: TFileWriterThread; PrecompPrimes: TArray<Integer>);
begin
  inherited Create(True); // ������� ����� ����������������
  FreeOnTerminate := False; // �� ���������� ����� �������������
  FThreadNum := ThreadNum;
  FFieldOfNumbers := FieldOfNumbers;
  FWriterThread := WriterThread;
  FFoundPrimes := TList<Integer>.Create(); // ������� ������ ��� ��������� ������� �����
  FPrecomputedPrimes := PrecompPrimes;
  Resume; // ��������� �����
end;

// ����������� �������� �����
function TPrimeFinderThread.IsPrime(n: Integer): Boolean;
var
  prime: Integer;
begin
  Result := True;
  if n = 2 then Exit(True); // 2 � ������� �����
  if (n mod 2) = 0 then Exit(False); // ������ ����� (����� 2) �� �������
  for prime in FPrecomputedPrimes do
  begin
    if (prime * prime) > n then Break; // ���� ������� �������� �������� ����� ������ n, ���������� ��������
    if (n mod prime) = 0 then Exit(False); // ����� ��������, ������ ����� �� �������
  end;
end;

// �������� ��������� �������� ������
procedure TPrimeFinderThread.Execute;
var
  Job: Integer;
begin
  while True do
  begin
    if FFieldOfNumbers.TakeJob(Job) then
      ProcessJob(Job) // ��������� �������� �� ��������
    else
      Break; // ��������� �����, ���� ����� ������ ���
  end;

  // ��������� ������ ���������� ������
  WritePersonalResults(Format('Thread%d.txt', [FThreadNum]));
end;

// ��������� �������
procedure TPrimeFinderThread.ProcessJob(Job: Integer);
begin
  if IsPrime(Job) then
  begin
    FWriterThread.AddRecord(Job); // �������� ��������� ������� ����� ������������� ������
    FFoundPrimes.Add(Job); // ��������� � ������ ������ ��������� ������� �����
  end;
end;

// ������ ������ ����������� ������ � ����
procedure TPrimeFinderThread.WritePersonalResults(const FileName: string);
var
  f: TextFile;
  Prime: Integer;
begin
  try
    AssignFile(f, FileName);
    Rewrite(f); // ��������� ���� ��� ����������
    try
      // ���������� ��� ��������� ����� ����� ������
      for Prime in FFoundPrimes do
        Write(f, Format('%d ', [Prime]));
    finally
      CloseFile(f);
    end;
  except
    on E: Exception do
      Writeln('������ ������ � ���� ' + FileName + ': ' + E.Message);
  end;
end;

var
  Thr: TTHread;
  FieldOfNumbers: TFieldOfNumbers;
  WriterThread: TFileWriterThread;
  Threads: array of TPrimeFinderThread;
  PrecomputedPrimes: TArray<Integer>;

begin
  try
    // ���������� ������ ������� ����� �� ����� �� MAX_NUMBER
    precomputedPrimes := GeneratePrimes(Round(Sqrt(MAX_NUMBER)));

    FieldOfNumbers := TFieldOfNumbers.Create(2, MAX_NUMBER); // ������� ���� �����
    WriterThread := TFileWriterThread.Create(); // ������� ����� ������ � ����
    try
      // ������� ��� ������ ������ ������� �����
      SetLength(Threads, 2);
      Threads[0] := TPrimeFinderThread.Create(1, FieldOfNumbers, WriterThread, PrecomputedPrimes); // ������ �����
      Threads[1] := TPrimeFinderThread.Create(2, FieldOfNumbers, WriterThread, PrecomputedPrimes); // ������ �����

      // ���� ���������� �������
      for Thr in Threads do
        Thr.WaitFor;

      // ��� ���������� ������ ������
      WriterThread.Terminate;
      WriterThread.WaitFor;

      // ����������� ������
      WriterThread.Free;
      for Thr in Threads do Thr.Free;

    finally
      FieldOfNumbers.Free; // ����������� ������� ������
    end;
    CalculateMD5('Result.txt');
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
