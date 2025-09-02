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

// Считаем MD5 и выводим на экран
procedure CalculateMD5(const FileName: string);
var
  FileContent: TFileStream;
  ContentAsBytes: TArray<Byte>;
  ContentAsString: RawByteString;
begin
  if not FileExists(FileName) then
  begin
    Writeln('Файл не найден.');
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

// Генерация списка простых чисел с помощью решета Эратосфена
//до квадратного корня от limit (очень ускоряет поиск простых чисел)
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

// Создание рабочего поля
constructor TFieldOfNumbers.Create(MinRange, MaxRange: Integer);
var
  i: Integer;
begin
  inherited Create;
  FAvailableJobs := TList<Integer>.Create();
  FLock := TCriticalSection.Create();
  FMinRange := MinRange;
  FMaxRange := MaxRange;
  // Заполняем список в обратном порядке
  //(потом будем забирать отсюда числа и удалять снизу, чтобы список не перестраивался и не терял на это ресурсы)
  for i := MaxRange downto MinRange do
    FAvailableJobs.Add(i);
end;

// Удаление рабочего поля
destructor TFieldOfNumbers.Destroy;
begin
  FAvailableJobs.Free;
  FLock.Free;
  inherited Destroy;
end;

// Взятие задания
function TFieldOfNumbers.TakeJob(out Job: Integer): Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if FAvailableJobs.Count > 0 then
    begin
      Job := FAvailableJobs.Last; // Берём последнее число
      FAvailableJobs.Delete(FAvailableJobs.Count - 1);
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

// Конструктор потока для записи в файл
constructor TFileWriterThread.Create;
begin
  inherited Create(True); // Создаем поток приостановленным
  FreeOnTerminate := False; // Не уничтожаем поток автоматически
  FBuffer := TList<Integer>.Create();
  FLock := TCriticalSection.Create();
  Resume; // Запускаем поток
end;

// Процедура записи результатов в файл
procedure TFileWriterThread.WriteRecordsToFile(const FileName: string);
var
  f: TextFile;
  Prime: Integer;
begin
  try
    AssignFile(f, FileName);
    Rewrite(f);
    try
      // Записываем все числа из буфера в файл через пробел
      for Prime in FBuffer do
        Write(f, Format('%d ', [Prime]));
    finally
      CloseFile(f);
    end;
  except
    on E: Exception do
      Writeln('Ошибка записи в файл ' + FileName + ': ' + E.Message);
  end;
end;

// Основная процедура потока для записи в файл
// (по условию задания, файл должен пополняться сразу при нахождении следующего числа)
// минусы такой записи - нагрузка на диск
// Если бы не требование задания, то можно было бы объединить буферы всех потоков в конце и записать файл.
procedure TFileWriterThread.Execute;
const
  OldCount: Integer = 0;
begin
  while not Terminated do
  begin
    if (FBuffer.Count > 0) and (FBuffer.Count > OldCount) then
    begin
      // Сортируем буфер перед записью
      FBuffer.Sort;
      WriteRecordsToFile('Result.txt');
      OldCount := FBuffer.Count;
    end
    else
      Sleep(100); // Короткий сон, если нечего писать
  end;
end;

// Добавление записи в буфер
procedure TFileWriterThread.AddRecord(Rec: Integer);
begin
  FLock.Enter;
  try
    FBuffer.Add(Rec); // Просто добавляем число в конец буфера
  finally
    FLock.Leave;
  end;
end;

// Конструктор потока нахождения простого числа
constructor TPrimeFinderThread.Create(ThreadNum: Integer; FieldOfNumbers: TFieldOfNumbers; WriterThread: TFileWriterThread; PrecompPrimes: TArray<Integer>);
begin
  inherited Create(True); // Создаем поток приостановленным
  FreeOnTerminate := False; // Не уничтожаем поток автоматически
  FThreadNum := ThreadNum;
  FFieldOfNumbers := FieldOfNumbers;
  FWriterThread := WriterThread;
  FFoundPrimes := TList<Integer>.Create(); // Создаем список для найденных простых чисел
  FPrecomputedPrimes := PrecompPrimes;
  Resume; // Запускаем поток
end;

// Определение простого числа
function TPrimeFinderThread.IsPrime(n: Integer): Boolean;
var
  prime: Integer;
begin
  Result := True;
  if n = 2 then Exit(True); // 2 — простое число
  if (n mod 2) = 0 then Exit(False); // Четные числа (кроме 2) не простые
  for prime in FPrecomputedPrimes do
  begin
    if (prime * prime) > n then Break; // Если квадрат текущего простого числа больше n, прекращаем проверку
    if (n mod prime) = 0 then Exit(False); // Нашли делитель, значит число не простое
  end;
end;

// Основная процедура обычного потока
procedure TPrimeFinderThread.Execute;
var
  Job: Integer;
begin
  while True do
  begin
    if FFieldOfNumbers.TakeJob(Job) then
      ProcessJob(Job) // Выполняем проверку на простоту
    else
      Break; // Завершаем поток, если чисел больше нет
  end;

  // Сохраняем личные результаты потока
  WritePersonalResults(Format('Thread%d.txt', [FThreadNum]));
end;

// Обработка задания
procedure TPrimeFinderThread.ProcessJob(Job: Integer);
begin
  if IsPrime(Job) then
  begin
    FWriterThread.AddRecord(Job); // Передали найденное простое число записывающему потоку
    FFoundPrimes.Add(Job); // Добавляем в личный список найденных простых чисел
  end;
end;

// Запись личных результатов потока в файл
procedure TPrimeFinderThread.WritePersonalResults(const FileName: string);
var
  f: TextFile;
  Prime: Integer;
begin
  try
    AssignFile(f, FileName);
    Rewrite(f); // Открываем файл для перезаписи
    try
      // Записываем все найденные числа через пробел
      for Prime in FFoundPrimes do
        Write(f, Format('%d ', [Prime]));
    finally
      CloseFile(f);
    end;
  except
    on E: Exception do
      Writeln('Ошибка записи в файл ' + FileName + ': ' + E.Message);
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
    // Генерируем список простых чисел до корня из MAX_NUMBER
    precomputedPrimes := GeneratePrimes(Round(Sqrt(MAX_NUMBER)));

    FieldOfNumbers := TFieldOfNumbers.Create(2, MAX_NUMBER); // Создаем поле чисел
    WriterThread := TFileWriterThread.Create(); // Создаем поток записи в файл
    try
      // Создаем два потока поиска простых чисел
      SetLength(Threads, 2);
      Threads[0] := TPrimeFinderThread.Create(1, FieldOfNumbers, WriterThread, PrecomputedPrimes); // Первый поток
      Threads[1] := TPrimeFinderThread.Create(2, FieldOfNumbers, WriterThread, PrecomputedPrimes); // Второй поток

      // Ждем завершения потоков
      for Thr in Threads do
        Thr.WaitFor;

      // Ждём завершения потока записи
      WriterThread.Terminate;
      WriterThread.WaitFor;

      // Освобождаем потоки
      WriterThread.Free;
      for Thr in Threads do Thr.Free;

    finally
      FieldOfNumbers.Free; // Освобождаем рабочую память
    end;
    CalculateMD5('Result.txt');
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
