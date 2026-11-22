// OptomstroySvc — хост служб Windows для программ Optomstroy POS (API, фоновые задачи, резервное копирование).
//
// Собирается встроенным компилятором .NET Framework 4.x (C# 5) скриптом build-svchost.ps1, без сторонних библиотек.
//
// Контракт командной строки:
//   OptomstroySvc.exe --config <путь к .svc.json>             режим службы (запускает SCM)
//   OptomstroySvc.exe --console --config <путь к .svc.json>   на переднем плане; Ctrl+C — штатная остановка
//   OptomstroySvc.exe --check-config --config <путь>          только проверить файл настроек
//   OptomstroySvc.exe --version
//   OptomstroySvc.exe --service-test <stop|shutdown|preshutdown> --config <путь>
//       проверка без SCM: тот же класс службы (OnStart, наблюдение за процессом, OnStop/OnShutdown/PRESHUTDOWN),
//       остановка по Ctrl+C; только для тестов и репетиции, на сервере не используется
//
// Ключи JSON: name, executable, arguments (массив строк), workingDirectory, environment (объект, необязательный),
// logDirectory, logMaxBytes, logKeepFiles, stopTimeoutSeconds, shutdownViaStdin (bool);
// необязательные: inheritEnvironment (bool, по умолчанию true), jobMemoryLimitMB (целое), cpuRatePercent (1..100).
// Ключи, начинающиеся с "_", считаются комментариями и пропускаются.
//
// Поведение:
//   * дочерний процесс запускается без окна (CREATE_NO_WINDOW), приостановленным, сразу помещается в объект
//     задания (Job Object) с JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE и только потом продолжает работу — поэтому ни он,
//     ни его потомки не переживут хост, даже если хост будет убит;
//   * stdout/stderr пишутся байт-в-байт (UTF-8 от node.exe не перекодируется) в <name>.out.log / <name>.err.log
//     с ротацией по размеру на границе строки; события самого хоста — в <name>.svc.log;
//   * stdin дочернего процесса — канал, который хост держит открытым до остановки;
//   * остановка: при shutdownViaStdin=true хост закрывает stdin и ждёт stopTimeoutSeconds, затем (или сразу при
//     shutdownViaStdin=false) завершает всё дерево процессов через задание;
//   * неожиданный выход дочернего процесса: запись в журналы и завершение хоста с ненулевым кодом, чтобы SCM
//     применил действия восстановления (перезапуск).
//
// Коды выхода (режим --console и ошибки до запуска):
//   0 — штатная остановка; 1 — внутренняя ошибка; 2 — ошибка аргументов или файла настроек;
//   3 — не удалось запустить дочерний процесс; 4 — дочерний процесс завершился сам (неожиданно);
//   5 — дочерний процесс не завершился за stopTimeoutSeconds и был принудительно завершён;
//   6 — дочерний процесс завершился при остановке, но с ненулевым кодом.

using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

[assembly: AssemblyTitle("OptomstroySvc")]
[assembly: AssemblyProduct("Optomstroy POS")]
[assembly: AssemblyDescription("Optomstroy POS Windows service host")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: AssemblyInformationalVersion("1.1.0")]

namespace Optomstroy.ServiceHost
{
    internal static class ExitCodes
    {
        public const int Ok = 0;
        public const int Internal = 1;
        public const int Usage = 2;
        public const int StartFailed = 3;
        public const int UnexpectedExit = 4;
        public const int StopForced = 5;
        public const int StopNonZero = 6;
    }

    internal sealed class ConfigException : Exception
    {
        public ConfigException(string message) : base(message) { }
    }

    // Запуск службы не удался; причина уже записана в журналы. Code — код выхода хоста (ExitCodes).
    internal sealed class HostStartException : Exception
    {
        public readonly int Code;
        public HostStartException(int code) : base("запуск службы не удался, код " + code.ToString(CultureInfo.InvariantCulture)) { Code = code; }
    }

    // ---------------------------------------------------------------- JSON (строгий минимальный разбор)

    internal sealed class JsonParser
    {
        private readonly string s;
        private int i;

        private JsonParser(string text) { s = text; i = 0; }

        public static object Parse(string text)
        {
            if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
            JsonParser p = new JsonParser(text);
            p.SkipWs();
            object v = p.ParseValue();
            p.SkipWs();
            if (p.i != p.s.Length) p.Fail("лишние символы после конца JSON");
            return v;
        }

        private void Fail(string what)
        {
            int line = 1, col = 1;
            for (int k = 0; k < i && k < s.Length; k++)
            {
                if (s[k] == '\n') { line++; col = 1; } else col++;
            }
            throw new ConfigException(string.Format(CultureInfo.InvariantCulture,
                "ошибка JSON (строка {0}, позиция {1}): {2}", line, col, what));
        }

        private void SkipWs()
        {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
        }

        private object ParseValue()
        {
            if (i >= s.Length) Fail("неожиданный конец файла");
            char c = s[i];
            if (c == '{') return ParseObject();
            if (c == '[') return ParseArray();
            if (c == '"') return ParseString();
            if (c == '-' || (c >= '0' && c <= '9')) return ParseNumber();
            if (Match("true")) return true;
            if (Match("false")) return false;
            if (Match("null")) return null;
            Fail("ожидалось значение");
            return null;
        }

        private bool Match(string word)
        {
            if (string.CompareOrdinal(s, i, word, 0, word.Length) == 0)
            {
                i += word.Length;
                return true;
            }
            return false;
        }

        private Dictionary<string, object> ParseObject()
        {
            Dictionary<string, object> d = new Dictionary<string, object>(StringComparer.Ordinal);
            i++;
            SkipWs();
            if (i < s.Length && s[i] == '}') { i++; return d; }
            while (true)
            {
                SkipWs();
                if (i >= s.Length || s[i] != '"') Fail("ожидалось имя ключа в кавычках");
                string key = ParseString();
                if (d.ContainsKey(key)) Fail("ключ \"" + key + "\" повторяется");
                SkipWs();
                if (i >= s.Length || s[i] != ':') Fail("ожидалось ':'");
                i++;
                SkipWs();
                d[key] = ParseValue();
                SkipWs();
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return d; }
                Fail("ожидалось ',' или '}'");
            }
        }

        private List<object> ParseArray()
        {
            List<object> a = new List<object>();
            i++;
            SkipWs();
            if (i < s.Length && s[i] == ']') { i++; return a; }
            while (true)
            {
                SkipWs();
                a.Add(ParseValue());
                SkipWs();
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; return a; }
                Fail("ожидалось ',' или ']'");
            }
        }

        private string ParseString()
        {
            StringBuilder sb = new StringBuilder();
            i++;
            while (true)
            {
                if (i >= s.Length) Fail("незакрытая строка");
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c < ' ') { i--; Fail("управляющий символ внутри строки"); }
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) Fail("незакрытая строка");
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 > s.Length) Fail("неполная последовательность \\u");
                        int code;
                        if (!int.TryParse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                            Fail("неверная последовательность \\u");
                        sb.Append((char)code);
                        i += 4;
                        break;
                    default:
                        i--;
                        Fail("неизвестная escape-последовательность \\" + e);
                        break;
                }
            }
        }

        private decimal ParseNumber()
        {
            int start = i;
            if (s[i] == '-') i++;
            while (i < s.Length && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) i++;
            decimal d;
            if (!decimal.TryParse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out d))
            {
                i = start;
                Fail("неверное число");
            }
            return d;
        }
    }

    // ---------------------------------------------------------------- Настройки

    internal sealed class SvcConfig
    {
        public string ConfigPath;
        public string Name;
        public string Executable;
        public List<string> Arguments = new List<string>();
        public string WorkingDirectory;
        // значение null — удалить переменную из унаследованного окружения
        public SortedDictionary<string, string> Environment = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string LogDirectory;
        public long LogMaxBytes;
        public int LogKeepFiles;
        public int StopTimeoutSeconds;
        public bool ShutdownViaStdin;
        // false — дочернему процессу передаются только системные переменные из списка BaseEnvironment и "environment"
        public bool InheritEnvironment = true;
        public long JobMemoryLimitMB;   // 0 — без лимита
        public int CpuRatePercent;      // 0 — без лимита; доля всех процессоров машины

        private static readonly string[] Known = new string[] {
            "name", "executable", "arguments", "workingDirectory", "environment",
            "logDirectory", "logMaxBytes", "logKeepFiles", "stopTimeoutSeconds", "shutdownViaStdin",
            "inheritEnvironment", "jobMemoryLimitMB", "cpuRatePercent" };
        private static readonly string[] Required = new string[] {
            "name", "executable", "arguments", "workingDirectory",
            "logDirectory", "logMaxBytes", "logKeepFiles", "stopTimeoutSeconds", "shutdownViaStdin" };

        public static SvcConfig Load(string path)
        {
            if (string.IsNullOrEmpty(path)) throw new ConfigException("не указан путь к файлу настроек (--config)");
            string full;
            try { full = Path.GetFullPath(path); }
            catch (Exception ex) { throw new ConfigException("неверный путь к файлу настроек \"" + path + "\": " + ex.Message); }
            string text;
            try { text = File.ReadAllText(full, new UTF8Encoding(false, true)); }
            catch (Exception ex) { throw new ConfigException("не удалось прочитать файл настроек \"" + full + "\": " + ex.Message); }

            object root;
            try { root = JsonParser.Parse(text); }
            catch (ConfigException ex) { throw new ConfigException(full + ": " + ex.Message); }
            Dictionary<string, object> o = root as Dictionary<string, object>;
            if (o == null) throw new ConfigException(full + ": корень JSON должен быть объектом");

            List<string> problems = new List<string>();
            foreach (string k in o.Keys)
            {
                if (k.StartsWith("_", StringComparison.Ordinal)) continue;
                if (Array.IndexOf(Known, k) < 0) problems.Add("неизвестный ключ \"" + k + "\" (имена ключей чувствительны к регистру)");
            }
            foreach (string k in Required)
                if (!o.ContainsKey(k)) problems.Add("нет обязательного ключа \"" + k + "\"");
            // Остальные проверки продолжаются, чтобы сообщить обо всех ошибках сразу; отсутствующие ключи пропускаются.
            SvcConfig c = new SvcConfig();
            c.ConfigPath = full;
            c.Name = Str(o, "name", problems);
            if (c.Name != null && !IsSafeName(c.Name))
                problems.Add("\"name\" может содержать только латинские буквы, цифры, '.', '_', '-' (1..80 символов)");
            c.Executable = AbsPath(o, "executable", problems);
            if (c.Executable != null && !File.Exists(c.Executable)) problems.Add("\"executable\": файл не найден: " + c.Executable);
            c.WorkingDirectory = AbsPath(o, "workingDirectory", problems);
            if (c.WorkingDirectory != null && !Directory.Exists(c.WorkingDirectory)) problems.Add("\"workingDirectory\": папка не найдена: " + c.WorkingDirectory);
            c.LogDirectory = AbsPath(o, "logDirectory", problems);

            List<object> args = o.ContainsKey("arguments") ? o["arguments"] as List<object> : null;
            if (args == null) { if (o.ContainsKey("arguments")) problems.Add("\"arguments\" должен быть массивом строк"); }
            else
            {
                for (int n = 0; n < args.Count; n++)
                {
                    string a = args[n] as string;
                    if (a == null) problems.Add("\"arguments\"[" + n + "] должен быть строкой");
                    else if (a.IndexOf('\0') >= 0) problems.Add("\"arguments\"[" + n + "] содержит символ NUL");
                    else c.Arguments.Add(a);
                }
            }

            if (o.ContainsKey("environment") && o["environment"] != null)
            {
                Dictionary<string, object> env = o["environment"] as Dictionary<string, object>;
                if (env == null) problems.Add("\"environment\" должен быть объектом {\"ИМЯ\": \"значение\"}");
                else
                {
                    foreach (KeyValuePair<string, object> kv in env)
                    {
                        if (kv.Key.Length == 0 || kv.Key.IndexOf('=') >= 0 || kv.Key.IndexOf('\0') >= 0)
                        { problems.Add("\"environment\": недопустимое имя переменной \"" + kv.Key + "\""); continue; }
                        if (c.Environment.ContainsKey(kv.Key))
                        { problems.Add("\"environment\": переменная \"" + kv.Key + "\" указана дважды (без учёта регистра)"); continue; }
                        if (kv.Value == null) { c.Environment[kv.Key] = null; continue; }
                        string v = kv.Value as string;
                        if (v == null) problems.Add("\"environment\".\"" + kv.Key + "\" должен быть строкой или null");
                        else if (v.IndexOf('\0') >= 0) problems.Add("\"environment\".\"" + kv.Key + "\" содержит символ NUL");
                        else c.Environment[kv.Key] = v;
                    }
                }
            }

            c.LogMaxBytes = Int(o, "logMaxBytes", 1024, 1024L * 1024 * 1024, problems);
            c.LogKeepFiles = (int)Int(o, "logKeepFiles", 1, 100, problems);
            c.StopTimeoutSeconds = (int)Int(o, "stopTimeoutSeconds", 1, 3600, problems);
            object sv;
            if (o.TryGetValue("shutdownViaStdin", out sv) && !(sv is bool)) problems.Add("\"shutdownViaStdin\" должен быть true или false");
            else if (sv is bool) c.ShutdownViaStdin = (bool)sv;
            object ie;
            if (o.TryGetValue("inheritEnvironment", out ie) && !(ie is bool)) problems.Add("\"inheritEnvironment\" должен быть true или false");
            else if (ie is bool) c.InheritEnvironment = (bool)ie;
            if (o.ContainsKey("jobMemoryLimitMB")) c.JobMemoryLimitMB = Int(o, "jobMemoryLimitMB", 64, 1024L * 1024, problems);
            if (o.ContainsKey("cpuRatePercent")) c.CpuRatePercent = (int)Int(o, "cpuRatePercent", 1, 100, problems);

            if (problems.Count > 0) throw new ConfigException(full + ": " + string.Join("; ", problems.ToArray()));
            return c;
        }

        private static bool IsSafeName(string n)
        {
            if (n.Length < 1 || n.Length > 80) return false;
            foreach (char ch in n)
            {
                bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-';
                if (!ok) return false;
            }
            return true;
        }

        private static string Str(Dictionary<string, object> o, string key, List<string> problems)
        {
            object raw;
            if (!o.TryGetValue(key, out raw)) return null;
            string v = raw as string;
            if (v == null || v.Trim().Length == 0) { problems.Add("\"" + key + "\" должен быть непустой строкой"); return null; }
            return v;
        }

        private static string AbsPath(Dictionary<string, object> o, string key, List<string> problems)
        {
            string v = Str(o, key, problems);
            if (v == null) return null;
            // Требуем полный путь с буквой диска или UNC: у службы текущая папка — System32.
            bool abs = (v.Length >= 3 && char.IsLetter(v[0]) && v[1] == ':' && (v[2] == '\\' || v[2] == '/')) || v.StartsWith("\\\\", StringComparison.Ordinal);
            if (!abs) { problems.Add("\"" + key + "\" должен быть полным путём (например D:\\Optomstroy\\...): " + v); return null; }
            try { return Path.GetFullPath(v); }
            catch (Exception ex) { problems.Add("\"" + key + "\": неверный путь: " + ex.Message); return null; }
        }

        private static long Int(Dictionary<string, object> o, string key, long min, long max, List<string> problems)
        {
            object v;
            if (!o.TryGetValue(key, out v)) return min;
            if (!(v is decimal)) { problems.Add("\"" + key + "\" должен быть целым числом"); return min; }
            decimal d = (decimal)v;
            if (d != decimal.Truncate(d) || d < min || d > max)
            {
                problems.Add(string.Format(CultureInfo.InvariantCulture, "\"{0}\" должен быть целым числом от {1} до {2}", key, min, max));
                return min;
            }
            return (long)d;
        }
    }

    // ---------------------------------------------------------------- Журналы с ротацией по размеру

    internal sealed class RotatingLog : IDisposable
    {
        private readonly object sync = new object();
        private readonly string dir;
        private readonly string baseName;   // например OptomstroyApi.out
        private readonly long maxBytes;
        private readonly int keep;
        private FileStream fs;
        private long size;
        private bool atLineStart = true;
        private DateTime nextRotateAttemptUtc = DateTime.MinValue;
        public Action<string> OnWarning;

        public RotatingLog(string dir, string baseName, long maxBytes, int keep)
        {
            this.dir = dir;
            this.baseName = baseName;
            this.maxBytes = maxBytes;
            this.keep = keep;
            Open();
        }

        public string CurrentPath { get { return Path.Combine(dir, baseName + ".log"); } }

        private string RotatedPath(int n)
        {
            return Path.Combine(dir, baseName + "." + n.ToString(CultureInfo.InvariantCulture) + ".log");
        }

        private void Open()
        {
            fs = new FileStream(CurrentPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.None);
            size = fs.Length;
            atLineStart = true;
        }

        // Только для тестов: сколько раз подряд «не открыть» новый файл после ротации (переменная окружения хоста).
        private static int injectReopenFailures = ReadInjectCount();
        private const int ReopenRetrySeconds = 5;
        private DateTime nextReopenAttemptUtc = DateTime.MinValue;
        private long droppedBytes;
        private bool disposed;

        private static int ReadInjectCount()
        {
            int n;
            string v = System.Environment.GetEnvironmentVariable("OPTOMSTROYSVC_TEST_FAIL_REOPEN");
            return v != null && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n > 0 ? n : 0;
        }

        private void Warn(string msg)
        {
            Action<string> w = OnWarning;
            if (w != null) ThreadPool.QueueUserWorkItem(delegate { w(msg); });
        }

        // Файл не открыт (не удалось открыть после ротации): повторяем не чаще раза в ReopenRetrySeconds.
        private bool TryReopen()
        {
            if (disposed) return false;
            if (DateTime.UtcNow < nextReopenAttemptUtc) return false;
            try
            {
                Open();
            }
            catch (Exception ex)
            {
                nextReopenAttemptUtc = DateTime.UtcNow.AddSeconds(ReopenRetrySeconds);
                Warn("журнал " + CurrentPath + " по-прежнему не открывается (" + ex.Message + "), вывод теряется; повтор через " + ReopenRetrySeconds + " с");
                return false;
            }
            Warn("журнал " + CurrentPath + " снова открыт; потеряно байт вывода: " + droppedBytes.ToString(CultureInfo.InvariantCulture));
            droppedBytes = 0;
            return true;
        }

        // Пишет байты как есть. Ротация — только на границе строки (или если строка без конца вдвое превысила предел).
        public void Write(byte[] buf, int off, int len)
        {
            lock (sync)
            {
                if (fs == null && !TryReopen()) { if (!disposed) droppedBytes += len; return; }
                int end = off + len;
                int p = off;
                while (p < end)
                {
                    int nl = Array.IndexOf(buf, (byte)'\n', p, end - p);
                    int pieceEnd = nl < 0 ? end : nl + 1;
                    int pieceLen = pieceEnd - p;
                    bool overflow = size > 0 && size + pieceLen > maxBytes;
                    if ((overflow && atLineStart) || size >= maxBytes * 2) TryRotate();
                    if (fs == null) { droppedBytes += end - p; return; }
                    fs.Write(buf, p, pieceLen);
                    size += pieceLen;
                    atLineStart = buf[pieceEnd - 1] == (byte)'\n';
                    p = pieceEnd;
                }
                fs.Flush();
            }
        }

        public void WriteLine(string text)
        {
            byte[] b = new UTF8Encoding(false).GetBytes(text + "\r\n");
            Write(b, 0, b.Length);
        }

        private void TryRotate()
        {
            if (DateTime.UtcNow < nextRotateAttemptUtc) return;
            fs.Flush();
            fs.Dispose();
            fs = null;
            string failure = null;
            try
            {
                string last = RotatedPath(keep);
                if (File.Exists(last)) File.Delete(last);
                for (int n = keep - 1; n >= 1; n--)
                {
                    string from = RotatedPath(n);
                    if (File.Exists(from)) File.Move(from, RotatedPath(n + 1));
                }
                File.Move(CurrentPath, RotatedPath(1));
            }
            catch (Exception ex)
            {
                // Например, файл открыт другой программой без FILE_SHARE_DELETE. Продолжаем писать в текущий файл.
                failure = ex.Message;
                nextRotateAttemptUtc = DateTime.UtcNow.AddSeconds(30);
            }
            if (failure != null) Warn("ротация " + CurrentPath + " не удалась (повтор через 30 с): " + failure);
            try
            {
                if (failure == null && injectReopenFailures > 0)
                {
                    injectReopenFailures--;
                    throw new IOException("тестовый отказ OPTOMSTROYSVC_TEST_FAIL_REOPEN");
                }
                Open();
            }
            catch (Exception ex)
            {
                // Например, антивирус или программа резервного копирования держит путь, или нет прав NTFS.
                // Файл остаётся закрытым; Write повторяет открытие не чаще раза в ReopenRetrySeconds.
                fs = null;
                nextReopenAttemptUtc = DateTime.UtcNow.AddSeconds(ReopenRetrySeconds);
                Warn("после ротации не удалось открыть " + CurrentPath + ": " + ex.Message + "; вывод теряется, повтор через " + ReopenRetrySeconds + " с");
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                disposed = true;
                if (fs != null) { try { fs.Flush(); fs.Dispose(); } catch { } fs = null; }
            }
        }
    }

    // ---------------------------------------------------------------- Журнал хоста (файл + журнал событий + консоль)

    internal sealed class HostLog
    {
        public const string EventSource = "OptomstroySvc";
        private static RotatingLog file;
        private static string svcName = "?";
        public static bool ConsoleMode;
        public static bool UseEventLog;

        public static void Attach(RotatingLog log, string name)
        {
            file = log;
            svcName = name;
        }

        public static void Info(string msg) { Write("INFO", msg, EventLogEntryType.Information); }
        public static void Warn(string msg) { Write("WARN", msg, EventLogEntryType.Warning); }
        public static void Error(string msg) { Write("ERROR", msg, EventLogEntryType.Error); }

        private static void Write(string level, string msg, EventLogEntryType type)
        {
            string line = DateTimeOffset.Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture)
                + " [" + level + "] " + msg;
            RotatingLog f = file;
            if (f != null) { try { f.WriteLine(line); } catch { } }
            if (ConsoleMode || f == null) { try { Console.Error.WriteLine("OptomstroySvc[" + svcName + "] " + level + ": " + msg); } catch { } }
            // Журнал событий Application: только предупреждения и ошибки. ReportEvent работает и без регистрации
            // источника; после регистрации (New-EventLog, см. README) текст отображается без предупреждения.
            if (UseEventLog && type != EventLogEntryType.Information)
            {
                try
                {
                    IntPtr h = Native.RegisterEventSource(null, EventSource);
                    if (h != IntPtr.Zero)
                    {
                        ushort et = type == EventLogEntryType.Error ? (ushort)1 : (ushort)2;
                        Native.ReportEvent(h, et, 0, 0, IntPtr.Zero, 1, 0, new string[] { "[" + svcName + "] " + msg }, IntPtr.Zero);
                        Native.DeregisterEventSource(h);
                    }
                }
                catch { }
            }
        }
    }

    // ---------------------------------------------------------------- Win32

    internal static class Native
    {
        public const uint CREATE_SUSPENDED = 0x00000004;
        public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const uint CREATE_NO_WINDOW = 0x08000000;
        public const int STARTF_USESTDHANDLES = 0x00000100;
        public const uint HANDLE_FLAG_INHERIT = 0x00000001;
        public const int JobObjectBasicAccountingInformation = 1;
        public const int JobObjectExtendedLimitInformation = 9;
        public const uint JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x00000400;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const uint JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200;
        public const int JobObjectCpuRateControlInformation = 15;
        public const uint JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x1;
        public const uint JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x4;
        public const uint WAIT_OBJECT_0 = 0;
        public const uint WAIT_TIMEOUT = 0x102;

        [StructLayout(LayoutKind.Sequential)]
        public struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_CPU_RATE_CONTROL_INFORMATION
        {
            public uint ControlFlags;
            public uint CpuRate;   // циклов на 10000 (100 = 1 % всех процессоров)
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr RegisterEventSource(string server, string source);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool ReportEvent(IntPtr h, ushort type, ushort category, uint eventId, IntPtr sid,
            ushort numStrings, uint dataSize, string[] strings, IntPtr data);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DeregisterEventSource(IntPtr h);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr h, uint ms);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint code);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, ref JOBOBJECT_CPU_RATE_CONTROL_INFORMATION info, int len);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool QueryInformationJobObject(IntPtr hJob, int infoClass, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info, int len, IntPtr retLen);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool QueryInformationJobObject(IntPtr hJob, int infoClass, out JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len, IntPtr retLen);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

        public static string LastError()
        {
            int e = Marshal.GetLastWin32Error();
            return new Win32Exception(e).Message + " (код " + e.ToString(CultureInfo.InvariantCulture) + ")";
        }
    }

    // ---------------------------------------------------------------- Дочерний процесс

    internal enum StopOutcome { Graceful, GracefulNonZero, Forced, Killed }

    internal sealed class ChildRunner
    {
        private readonly SvcConfig cfg;
        private IntPtr job = IntPtr.Zero;
        private IntPtr hProcess = IntPtr.Zero;
        private int pid;
        private FileStream stdinWriter;
        private Thread outPump, errPump;
        private RotatingLog outLog, errLog;
        private int state; // 0 — работает, 1 — идёт остановка, 2 — неожиданный выход
        public readonly ManualResetEvent Exited = new ManualResetEvent(false);
        public readonly ManualResetEvent ForceKill = new ManualResetEvent(false);
        private uint exitCode;

        public ChildRunner(SvcConfig cfg) { this.cfg = cfg; }

        public int Pid { get { return pid; } }
        public uint ExitCode { get { return exitCode; } }

        public static string QuoteArg(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return a;
            StringBuilder sb = new StringBuilder();
            sb.Append('"');
            int n = 0;
            while (n < a.Length)
            {
                int bs = 0;
                while (n < a.Length && a[n] == '\\') { bs++; n++; }
                if (n == a.Length) { sb.Append('\\', bs * 2); break; }
                if (a[n] == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); }
                else { sb.Append('\\', bs); sb.Append(a[n]); }
                n++;
            }
            sb.Append('"');
            return sb.ToString();
        }

        // Системные переменные, которые передаются и при "inheritEnvironment": false: без них не работают
        // Windows API, временные файлы, поиск программ и библиотек.
        public static readonly string[] BaseEnvironment = new string[] {
            "SystemRoot", "windir", "SystemDrive", "ComSpec", "PATH", "PATHEXT", "TEMP", "TMP",
            "USERPROFILE", "USERNAME", "USERDOMAIN", "COMPUTERNAME", "ALLUSERSPROFILE", "PUBLIC", "APPDATA", "LOCALAPPDATA",
            "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
            "CommonProgramFiles", "CommonProgramFiles(x86)", "CommonProgramW6432",
            "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION",
            "OS", "DriverData" };

        // Переменные, которые дочерний процесс получил бы от хоста (до применения "environment").
        public static SortedDictionary<string, string> InheritedEnvironment(SvcConfig cfg)
        {
            SortedDictionary<string, string> env = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry e in System.Environment.GetEnvironmentVariables())
            {
                string k = (string)e.Key;
                if (k.Length == 0) continue;
                if (!cfg.InheritEnvironment && Array.FindIndex(BaseEnvironment, delegate (string b) { return string.Equals(b, k, StringComparison.OrdinalIgnoreCase); }) < 0) continue;
                env[k] = (string)e.Value;
            }
            return env;
        }

        private string BuildEnvironmentBlock()
        {
            SortedDictionary<string, string> env = InheritedEnvironment(cfg);
            foreach (KeyValuePair<string, string> kv in cfg.Environment)
            {
                if (kv.Value == null) env.Remove(kv.Key); else env[kv.Key] = kv.Value;
            }
            StringBuilder sb = new StringBuilder();
            foreach (KeyValuePair<string, string> kv in env) sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
            sb.Append('\0');
            return sb.ToString();
        }

        public void Start()
        {
            Directory.CreateDirectory(cfg.LogDirectory);
            outLog = new RotatingLog(cfg.LogDirectory, cfg.Name + ".out", cfg.LogMaxBytes, cfg.LogKeepFiles);
            errLog = new RotatingLog(cfg.LogDirectory, cfg.Name + ".err", cfg.LogMaxBytes, cfg.LogKeepFiles);
            outLog.OnWarning = HostLog.Warn;
            errLog.OnWarning = HostLog.Warn;

            job = Native.CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new InvalidOperationException("CreateJobObject: " + Native.LastError());
            Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            li.BasicLimitInformation.LimitFlags = Native.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | Native.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
            if (cfg.JobMemoryLimitMB > 0)
            {
                // Лимит выделенной (commit) памяти на всё дерево процессов: выделение сверх него завершается ошибкой,
                // node.exe падает (out of memory), хост завершается с кодом 4, SCM перезапускает службу.
                li.BasicLimitInformation.LimitFlags |= Native.JOB_OBJECT_LIMIT_JOB_MEMORY;
                li.JobMemoryLimit = new UIntPtr((ulong)cfg.JobMemoryLimitMB * 1024UL * 1024UL);
            }
            if (!Native.SetInformationJobObject(job, Native.JobObjectExtendedLimitInformation, ref li, Marshal.SizeOf(typeof(Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                throw new InvalidOperationException("SetInformationJobObject: " + Native.LastError());
            if (cfg.CpuRatePercent > 0)
            {
                Native.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION ci = new Native.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION();
                ci.ControlFlags = Native.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | Native.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
                ci.CpuRate = (uint)cfg.CpuRatePercent * 100;
                if (!Native.SetInformationJobObject(job, Native.JobObjectCpuRateControlInformation, ref ci, Marshal.SizeOf(typeof(Native.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION))))
                    throw new InvalidOperationException("SetInformationJobObject(CPU): " + Native.LastError());
            }

            Native.SECURITY_ATTRIBUTES sa = new Native.SECURITY_ATTRIBUTES();
            sa.nLength = Marshal.SizeOf(typeof(Native.SECURITY_ATTRIBUTES));
            sa.bInheritHandle = 1;
            IntPtr inR, inW, outR, outW, errR, errW;
            if (!Native.CreatePipe(out inR, out inW, ref sa, 0)) throw new InvalidOperationException("CreatePipe(stdin): " + Native.LastError());
            if (!Native.CreatePipe(out outR, out outW, ref sa, 0)) throw new InvalidOperationException("CreatePipe(stdout): " + Native.LastError());
            if (!Native.CreatePipe(out errR, out errW, ref sa, 0)) throw new InvalidOperationException("CreatePipe(stderr): " + Native.LastError());
            // Концы хоста не наследуются, иначе EOF никогда не наступит.
            Native.SetHandleInformation(inW, Native.HANDLE_FLAG_INHERIT, 0);
            Native.SetHandleInformation(outR, Native.HANDLE_FLAG_INHERIT, 0);
            Native.SetHandleInformation(errR, Native.HANDLE_FLAG_INHERIT, 0);

            Native.STARTUPINFO si = new Native.STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(Native.STARTUPINFO));
            si.dwFlags = Native.STARTF_USESTDHANDLES;
            si.hStdInput = inR;
            si.hStdOutput = outW;
            si.hStdError = errW;

            StringBuilder cmd = new StringBuilder(QuoteArg(cfg.Executable));
            foreach (string a in cfg.Arguments) cmd.Append(' ').Append(QuoteArg(a));
            if (cmd.Length >= 32767) throw new InvalidOperationException("командная строка длиннее 32766 символов");

            IntPtr envBlock = Marshal.StringToHGlobalUni(BuildEnvironmentBlock());
            Native.PROCESS_INFORMATION pi;
            bool ok;
            try
            {
                ok = Native.CreateProcess(cfg.Executable, cmd, IntPtr.Zero, IntPtr.Zero, true,
                    Native.CREATE_SUSPENDED | Native.CREATE_NO_WINDOW | Native.CREATE_UNICODE_ENVIRONMENT,
                    envBlock, cfg.WorkingDirectory, ref si, out pi);
            }
            finally
            {
                Marshal.FreeHGlobal(envBlock);
            }
            string createError = ok ? null : Native.LastError();
            Native.CloseHandle(inR);
            Native.CloseHandle(outW);
            Native.CloseHandle(errW);
            if (!ok)
            {
                Native.CloseHandle(inW); Native.CloseHandle(outR); Native.CloseHandle(errR);
                throw new InvalidOperationException("CreateProcess(" + cfg.Executable + "): " + createError);
            }
            if (!Native.AssignProcessToJobObject(job, pi.hProcess))
            {
                string err = Native.LastError();
                Native.TerminateProcess(pi.hProcess, 1);
                Native.CloseHandle(pi.hThread); Native.CloseHandle(pi.hProcess);
                Native.CloseHandle(inW); Native.CloseHandle(outR); Native.CloseHandle(errR);
                throw new InvalidOperationException("AssignProcessToJobObject: " + err);
            }
            hProcess = pi.hProcess;
            pid = pi.dwProcessId;

            stdinWriter = new FileStream(new SafeFileHandle(inW, true), FileAccess.Write, 1, false);
            outPump = StartPump(new FileStream(new SafeFileHandle(outR, true), FileAccess.Read, 1, false), outLog, "stdout");
            errPump = StartPump(new FileStream(new SafeFileHandle(errR, true), FileAccess.Read, 1, false), errLog, "stderr");

            Native.ResumeThread(pi.hThread);
            Native.CloseHandle(pi.hThread);

            Thread w = new Thread(WaitExit);
            w.IsBackground = true;
            w.Name = "wait-exit";
            w.Start();
        }

        private static Thread StartPump(FileStream src, RotatingLog dst, string name)
        {
            Thread t = new Thread(delegate ()
            {
                byte[] buf = new byte[16384];
                try
                {
                    while (true)
                    {
                        int n;
                        try { n = src.Read(buf, 0, buf.Length); }
                        catch (IOException) { break; } // ERROR_BROKEN_PIPE — все писатели закрыли канал
                        if (n <= 0) break;
                        try { dst.Write(buf, 0, n); }
                        catch (Exception ex) { HostLog.Error("запись " + name + " в журнал не удалась: " + ex.Message); Thread.Sleep(1000); }
                    }
                }
                finally { try { src.Dispose(); } catch { } }
            });
            t.IsBackground = true;
            t.Name = "pump-" + name;
            t.Start();
            return t;
        }

        private void WaitExit()
        {
            Native.WaitForSingleObject(hProcess, 0xFFFFFFFF);
            uint code;
            Native.GetExitCodeProcess(hProcess, out code);
            exitCode = code;
            Exited.Set();
        }

        // true — выход был неожиданным (остановку никто не запрашивал).
        public bool MarkUnexpectedExit()
        {
            return Interlocked.CompareExchange(ref state, 2, 0) == 0;
        }

        public uint ActiveProcessesInJob()
        {
            Native.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION ai;
            if (job != IntPtr.Zero && Native.QueryInformationJobObject(job, Native.JobObjectBasicAccountingInformation, out ai,
                Marshal.SizeOf(typeof(Native.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero))
                return ai.ActiveProcesses;
            return 0;
        }

        // Пиковая выделенная память задания; при лимите — пометка, если пик подошёл к лимиту.
        public string MemoryNote()
        {
            Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
            if (job == IntPtr.Zero || !Native.QueryInformationJobObject(job, Native.JobObjectExtendedLimitInformation, out li,
                Marshal.SizeOf(typeof(Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)), IntPtr.Zero))
                return "";
            ulong peakMb = li.PeakJobMemoryUsed.ToUInt64() / (1024UL * 1024UL);
            if (cfg.JobMemoryLimitMB <= 0) return "; пик памяти " + peakMb + " МБ";
            if (peakMb * 10 >= (ulong)cfg.JobMemoryLimitMB * 9)
                return "; пик памяти " + peakMb + " МБ из лимита jobMemoryLimitMB=" + cfg.JobMemoryLimitMB + " МБ — вероятно, достигнут лимит памяти";
            return "; пик памяти " + peakMb + " МБ (лимит " + cfg.JobMemoryLimitMB + " МБ)";
        }

        // Завершает оставшиеся в задании процессы (потомки, пережившие основной процесс) и дожидается журналов.
        public void Cleanup()
        {
            uint left = ActiveProcessesInJob();
            if (left > 0)
            {
                HostLog.Warn("в задании остались процессы (" + left + "), завершаются принудительно");
                Native.TerminateJobObject(job, 1);
            }
            CloseStdin();
            if (outPump != null && !outPump.Join(5000)) HostLog.Warn("журнал stdout не закрылся за 5 с");
            if (errPump != null && !errPump.Join(5000)) HostLog.Warn("журнал stderr не закрылся за 5 с");
            if (outLog != null) outLog.Dispose();
            if (errLog != null) errLog.Dispose();
        }

        private void CloseStdin()
        {
            FileStream s = Interlocked.Exchange(ref stdinWriter, null);
            if (s != null) { try { s.Dispose(); } catch { } }
        }

        // Остановка. requestTime(ms) вызывается периодически, чтобы сообщать SCM SERVICE_STOP_PENDING с подсказкой ожидания.
        public StopOutcome Stop(Action<int> requestTime)
        {
            Interlocked.Exchange(ref state, 1); // после этого выход процесса уже не считается неожиданным
            StopOutcome outcome;
            if (Exited.WaitOne(0))
            {
                outcome = exitCode == 0 ? StopOutcome.Graceful : StopOutcome.GracefulNonZero;
            }
            else if (cfg.ShutdownViaStdin)
            {
                HostLog.Info("остановка: stdin дочернего процесса закрыт, ожидание до " + cfg.StopTimeoutSeconds + " с");
                CloseStdin();
                DateTime deadline = DateTime.UtcNow.AddSeconds(cfg.StopTimeoutSeconds);
                bool exited = false;
                while (true)
                {
                    int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                    if (left <= 0) break;
                    if (requestTime != null) requestTime(Math.Min(left, 2000) + 15000);
                    int idx = WaitHandle.WaitAny(new WaitHandle[] { Exited, ForceKill }, Math.Min(left, 2000));
                    if (idx == 0) { exited = true; break; }
                    if (idx == 1) { HostLog.Warn("остановка: повторный запрос — принудительное завершение"); break; }
                }
                if (exited)
                {
                    outcome = exitCode == 0 ? StopOutcome.Graceful : StopOutcome.GracefulNonZero;
                }
                else
                {
                    HostLog.Warn("остановка: процесс " + pid + " не завершился за " + cfg.StopTimeoutSeconds + " с, завершаем всё дерево процессов");
                    Kill(requestTime);
                    outcome = StopOutcome.Forced;
                }
            }
            else
            {
                HostLog.Info("остановка: shutdownViaStdin=false, завершаем всё дерево процессов");
                Kill(requestTime);
                outcome = StopOutcome.Killed;
            }
            if (requestTime != null) requestTime(15000);
            if (outcome != StopOutcome.Forced && outcome != StopOutcome.Killed)
                HostLog.Info("остановка: процесс " + pid + " завершился с кодом " + exitCode);
            Cleanup();
            return outcome;
        }

        private void Kill(Action<int> requestTime)
        {
            if (!Native.TerminateJobObject(job, 1))
            {
                HostLog.Error("TerminateJobObject: " + Native.LastError() + "; пробуем TerminateProcess");
                Native.TerminateProcess(hProcess, 1);
            }
            if (requestTime != null) requestTime(15000);
            if (!Exited.WaitOne(10000)) HostLog.Error("процесс " + pid + " не завершился через 10 с после принудительного завершения");
        }
    }

    // ---------------------------------------------------------------- Общее ядро: запуск, неожиданный выход, остановка

    // Один и тот же код для режима службы (через OptomstroyService) и режима --console.
    internal sealed class HostSession
    {
        public SvcConfig Cfg;
        public ChildRunner Runner;
        private RotatingLog svcLog;
        private int closed;

        // 0 — процесс запущен; иначе код выхода хоста (ExitCodes). Причина уже записана в журналы.
        public int Begin(string configPath, string mode)
        {
            try { Cfg = SvcConfig.Load(configPath); }
            catch (ConfigException ex) { HostLog.Error("ошибка файла настроек: " + ex.Message); return ExitCodes.Usage; }

            try { svcLog = Program.OpenHostLog(Cfg); }
            catch (Exception ex)
            {
                HostLog.Error("не удалось открыть журнал хоста в " + Cfg.LogDirectory + ": " + ex.Message
                    + " (проверьте, что папка существует и у учётной записи службы есть право «Изменение» на неё и на файлы в ней)");
                return ExitCodes.Usage;
            }
            try
            {
                Program.LogStartBanner(Cfg, mode);
                Program.LogEnvironmentWarnings(Cfg);
            }
            catch (Exception ex) { HostLog.Warn("не удалось записать сведения о запуске: " + ex.Message); }

            Runner = new ChildRunner(Cfg);
            try
            {
                Runner.Start();
            }
            catch (Exception ex)
            {
                HostLog.Error("не удалось запустить процесс: " + ex.Message);
                try { Runner.Cleanup(); } catch { }
                Close();
                return ExitCodes.StartFailed;
            }
            HostLog.Info("процесс запущен, PID " + Runner.Pid);
            return 0;
        }

        // true — выход был неожиданным: записано в журналы, остатки дерева процессов завершены, журналы закрыты.
        public bool TryHandleUnexpectedExit(string tail)
        {
            if (!Runner.MarkUnexpectedExit()) return false;
            string mem = "";
            try { mem = Runner.MemoryNote(); } catch { }
            HostLog.Error("процесс " + Runner.Pid + " неожиданно завершился с кодом " + Runner.ExitCode + mem + "; " + tail);
            Runner.Cleanup();
            Close();
            return true;
        }

        // Штатная остановка; возвращает код выхода хоста для режима --console.
        public int Stop(string why, Action<int> requestTime)
        {
            HostLog.Info(why);
            StopOutcome o = Runner.Stop(requestTime);
            int rc;
            switch (o)
            {
                case StopOutcome.Graceful: rc = ExitCodes.Ok; break;
                case StopOutcome.Killed: rc = ExitCodes.Ok; break;
                case StopOutcome.Forced: rc = ExitCodes.StopForced; break;
                default: rc = ExitCodes.StopNonZero; break;
            }
            HostLog.Info("остановлено (" + o + "), код выхода хоста " + rc);
            Close();
            return rc;
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            if (svcLog != null)
            {
                HostLog.Attach(null, Cfg != null ? Cfg.Name : "?");
                svcLog.Dispose();
            }
        }
    }

    // ---------------------------------------------------------------- Служба (тонкий адаптер к HostSession)

    internal sealed class OptomstroyService : ServiceBase
    {
        private const int SERVICE_ACCEPT_PRESHUTDOWN = 0x100;
        private const int SERVICE_CONTROL_PRESHUTDOWN = 0x0F;
        private const int ERROR_PROCESS_ABORTED = 1067;

        private readonly string configPath;
        private HostSession session;
        private readonly object stopLock = new object();
        private bool stopped;
        private string stopReason = "остановка по запросу SCM";
        public readonly bool PreshutdownEnabled;

        public OptomstroyService(string configPath)
        {
            this.configPath = configPath;
            ServiceName = "OptomstroySvc"; // для SERVICE_WIN32_OWN_PROCESS имя в таблице диспетчера не используется
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = false;
            PreshutdownEnabled = TryAcceptPreshutdown();
        }

        // В ServiceBase .NET Framework нет свойства CanPreshutdown. Принятые команды хранятся в закрытом поле
        // acceptedCommands; добавляем SERVICE_ACCEPT_PRESHUTDOWN. SCM рассылает PRESHUTDOWN с учётом зависимостей
        // (OptomstroyApi/Worker/Backup остановятся раньше OptomstroyPostgres) и ждёт до PreshutdownTimeout службы.
        // Неизвестная ServiceBase команда 0x0F попадает в OnCustomCommand. Если поле не найдено — остаётся SHUTDOWN.
        private bool TryAcceptPreshutdown()
        {
            try
            {
                FieldInfo f = typeof(ServiceBase).GetField("acceptedCommands", BindingFlags.Instance | BindingFlags.NonPublic);
                if (f == null || f.FieldType != typeof(int)) return false;
                f.SetValue(this, (int)f.GetValue(this) | SERVICE_ACCEPT_PRESHUTDOWN);
                return true;
            }
            catch { return false; }
        }

        protected override void OnStart(string[] args)
        {
            session = new HostSession();
            int rc = session.Begin(configPath, "служба");
            if (rc != 0)
            {
                // Код для SCM: служба остановилась с ошибкой, поэтому действия восстановления (sc failureflag 1)
                // применяются и здесь, а sc.exe query покажет WIN32_EXIT_CODE 1067.
                ExitCode = ERROR_PROCESS_ABORTED;
                throw new HostStartException(rc);
            }
            if (!PreshutdownEnabled) HostLog.Warn("PRESHUTDOWN недоступен в этой версии .NET Framework: при выключении Windows используется SHUTDOWN");
            Thread mon = new Thread(Monitor);
            mon.IsBackground = true;
            mon.Name = "monitor";
            mon.Start();
        }

        private void Monitor()
        {
            session.Runner.Exited.WaitOne();
            if (!session.TryHandleUnexpectedExit("хост завершается с кодом " + ExitCodes.UnexpectedExit + ", SCM применит действия восстановления")) return;
            // Без отчёта SERVICE_STOPPED: SCM считает это сбоем службы и выполняет действия восстановления.
            System.Environment.Exit(ExitCodes.UnexpectedExit);
        }

        protected override void OnStop() { DoStop(stopReason); }

        protected override void OnShutdown() { DoStop("выключение Windows (SHUTDOWN)"); }

        protected override void OnCustomCommand(int command)
        {
            if (command != SERVICE_CONTROL_PRESHUTDOWN) return;
            stopReason = "выключение Windows (PRESHUTDOWN)";
            // ServiceBase.Stop: SERVICE_STOP_PENDING -> OnStop (с RequestAdditionalTime) -> SERVICE_STOPPED.
            Stop();
        }

        private void DoStop(string why)
        {
            lock (stopLock)
            {
                if (stopped) return;
                stopped = true;
            }
            if (session == null || session.Runner == null) return;
            session.Stop(why, delegate (int ms) { try { RequestAdditionalTime(ms); } catch { } });
            ExitCode = 0;
        }

        // ---- Проверка без SCM (--service-test): те же OnStart/OnStop/OnShutdown/OnCustomCommand.
        public void TestStart() { OnStart(new string[0]); }

        public void TestControl(string kind)
        {
            if (kind == "shutdown") OnShutdown();
            else if (kind == "preshutdown") OnCustomCommand(SERVICE_CONTROL_PRESHUTDOWN);
            else OnStop();
        }
    }

    // ---------------------------------------------------------------- Точка входа

    internal static class Program
    {
        public static string Version
        {
            get
            {
                object[] a = typeof(Program).Assembly.GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false);
                return a.Length > 0 ? ((AssemblyInformationalVersionAttribute)a[0]).InformationalVersion : "?";
            }
        }

        private static void Usage()
        {
            Console.Error.WriteLine("Использование:");
            Console.Error.WriteLine("  OptomstroySvc.exe --config <путь\\к\\файлу.svc.json>             (режим службы, запускает SCM)");
            Console.Error.WriteLine("  OptomstroySvc.exe --console --config <путь\\к\\файлу.svc.json>   (на переднем плане, Ctrl+C — остановка)");
            Console.Error.WriteLine("  OptomstroySvc.exe --check-config --config <путь\\к\\файлу.svc.json>");
            Console.Error.WriteLine("  OptomstroySvc.exe --service-test <stop|shutdown|preshutdown> --config <путь>   (проверка класса службы без SCM)");
            Console.Error.WriteLine("  OptomstroySvc.exe --version");
        }

        public static RotatingLog OpenHostLog(SvcConfig cfg)
        {
            Directory.CreateDirectory(cfg.LogDirectory);
            RotatingLog l = new RotatingLog(cfg.LogDirectory, cfg.Name + ".svc", cfg.LogMaxBytes, cfg.LogKeepFiles);
            l.OnWarning = HostLog.Warn;
            HostLog.Attach(l, cfg.Name);
            return l;
        }

        public static void LogStartBanner(SvcConfig cfg, string mode)
        {
            List<string> names = new List<string>(cfg.Environment.Keys);
            HostLog.Info("OptomstroySvc " + Version + " (" + mode + "), настройки: " + cfg.ConfigPath);
            HostLog.Info("запуск: " + cfg.Executable + " " + string.Join(" ", cfg.Arguments.ConvertAll<string>(ChildRunner.QuoteArg).ToArray())
                + " | папка: " + cfg.WorkingDirectory
                + " | переменные из настроек: " + (names.Count == 0 ? "-" : string.Join(",", names.ToArray()))
                + " | inheritEnvironment=" + (cfg.InheritEnvironment ? "true" : "false")
                + " | shutdownViaStdin=" + (cfg.ShutdownViaStdin ? "true" : "false") + ", stopTimeoutSeconds=" + cfg.StopTimeoutSeconds
                + " | jobMemoryLimitMB=" + (cfg.JobMemoryLimitMB > 0 ? cfg.JobMemoryLimitMB.ToString(CultureInfo.InvariantCulture) : "нет")
                + ", cpuRatePercent=" + (cfg.CpuRatePercent > 0 ? cfg.CpuRatePercent.ToString(CultureInfo.InvariantCulture) : "нет"));
        }

        // Пути из аргументов node --env-file=<путь> / --env-file-if-exists=<путь> (и в виде двух аргументов).
        private static List<string> EnvFiles(SvcConfig cfg)
        {
            List<string> files = new List<string>();
            string[] prefixes = new string[] { "--env-file=", "--env-file-if-exists=" };
            for (int n = 0; n < cfg.Arguments.Count; n++)
            {
                string a = cfg.Arguments[n];
                foreach (string p in prefixes)
                    if (a.StartsWith(p, StringComparison.Ordinal)) files.Add(a.Substring(p.Length));
                if ((a == "--env-file" || a == "--env-file-if-exists") && n + 1 < cfg.Arguments.Count) files.Add(cfg.Arguments[n + 1]);
            }
            return files;
        }

        private static List<string> EnvFileNames(string path)
        {
            List<string> names = new List<string>();
            foreach (string raw in File.ReadAllLines(path, new UTF8Encoding(false)))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line[0] == '#') continue;
                if (line.StartsWith("export ", StringComparison.Ordinal)) line = line.Substring(7).TrimStart();
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string name = line.Substring(0, eq).Trim();
                if (name.Length > 0) names.Add(name);
            }
            return names;
        }

        // node --env-file не заменяет переменные, уже заданные в окружении процесса. Переменная Windows с тем же
        // именем молча перекрыла бы значение из config\*.env — предупреждаем (только имена, без значений).
        public static void LogEnvironmentWarnings(SvcConfig cfg)
        {
            SortedDictionary<string, string> inherited = ChildRunner.InheritedEnvironment(cfg);
            foreach (string file in EnvFiles(cfg))
            {
                string full = file;
                try
                {
                    if (!Path.IsPathRooted(full)) full = Path.Combine(cfg.WorkingDirectory, full);
                    if (!File.Exists(full)) { HostLog.Warn("файл переменных " + full + " не найден"); continue; }
                    foreach (string name in EnvFileNames(full))
                    {
                        if (inherited.ContainsKey(name) && !cfg.Environment.ContainsKey(name))
                            HostLog.Warn("переменная " + name + " задана в окружении Windows и перекрывает значение из " + full
                                + " (node --env-file не заменяет заданные переменные). Перенесите её в \"environment\" файла .svc.json или задайте \"inheritEnvironment\": false");
                    }
                }
                catch (Exception ex) { HostLog.Warn("не удалось проверить файл переменных " + full + ": " + ex.Message); }
            }
            if (cfg.InheritEnvironment)
            {
                foreach (string name in inherited.Keys)
                {
                    if (cfg.Environment.ContainsKey(name)) continue;
                    string u = name.ToUpperInvariant();
                    if (u.StartsWith("NODE_", StringComparison.Ordinal) || u.EndsWith("_PROXY", StringComparison.Ordinal))
                        HostLog.Warn("унаследована переменная Windows " + name + ", она влияет на node.exe; рекомендуется \"inheritEnvironment\": false");
                }
            }
        }

        [STAThread]
        public static int Main(string[] args)
        {
            bool console = false, version = false, check = false, help = false;
            string config = null, serviceTest = null;
            for (int n = 0; n < args.Length; n++)
            {
                string a = args[n];
                if (a == "--console") console = true;
                else if (a == "--version") version = true;
                else if (a == "--check-config") check = true;
                else if (a == "--help" || a == "-h" || a == "/?") help = true;
                else if (a == "--config" && n + 1 < args.Length && config == null) config = args[++n];
                else if (a == "--service-test" && n + 1 < args.Length && serviceTest == null
                    && (args[n + 1] == "stop" || args[n + 1] == "shutdown" || args[n + 1] == "preshutdown")) serviceTest = args[++n];
                else
                {
                    TryUtf8Console();
                    Console.Error.WriteLine("OptomstroySvc: неизвестный или повторный аргумент: " + a);
                    Usage();
                    return ExitCodes.Usage;
                }
            }
            if (version)
            {
                Console.Out.WriteLine("OptomstroySvc " + Version);
                return ExitCodes.Ok;
            }
            TryUtf8Console();
            if (help) { Usage(); return ExitCodes.Ok; }
            if (config == null) { Console.Error.WriteLine("OptomstroySvc: не указан --config"); Usage(); return ExitCodes.Usage; }

            if (check)
            {
                try { SvcConfig.Load(config); Console.Out.WriteLine("OptomstroySvc: файл настроек в порядке: " + Path.GetFullPath(config)); return ExitCodes.Ok; }
                catch (ConfigException ex) { Console.Error.WriteLine("OptomstroySvc: " + ex.Message); return ExitCodes.Usage; }
            }
            if (serviceTest != null) return RunServiceTest(config, serviceTest);
            if (console) return RunConsole(config);

            if (System.Environment.UserInteractive)
            {
                // Запуск без SCM и без --console: подсказка вместо зависания в StartServiceCtrlDispatcher.
                Console.Error.WriteLine("OptomstroySvc: режим службы запускается только диспетчером служб (sc.exe start). Для запуска в окне добавьте --console.");
                return ExitCodes.Usage;
            }
            HostLog.UseEventLog = true;
            try
            {
                ServiceBase.Run(new OptomstroyService(config));
                return ExitCodes.Ok;
            }
            catch (HostStartException ex)
            {
                // ServiceBase.Run повторно выбрасывает исключение из OnStart; причина уже в журналах.
                return ex.Code;
            }
            catch (Exception ex)
            {
                HostLog.Error("внутренняя ошибка: " + ex);
                return ExitCodes.Internal;
            }
        }

        private static void TryUtf8Console()
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
        }

        private static ManualResetEvent HookCtrlC(Action secondPress)
        {
            ManualResetEvent stopRequested = new ManualResetEvent(false);
            // Признак «игнорировать Ctrl+C» наследуется от родителя (например, запуск из планировщика); снимаем его.
            Native.SetConsoleCtrlHandler(IntPtr.Zero, false);
            int ctrlCount = 0;
            Console.CancelKeyPress += delegate (object sender, ConsoleCancelEventArgs e)
            {
                e.Cancel = true;
                int c = Interlocked.Increment(ref ctrlCount);
                if (c == 1) { HostLog.Info("получен " + e.SpecialKey + " — штатная остановка"); stopRequested.Set(); }
                else secondPress();
            };
            return stopRequested;
        }

        private static int RunConsole(string configPath)
        {
            HostLog.ConsoleMode = true;
            HostSession s = new HostSession();
            ManualResetEvent stopRequested = HookCtrlC(delegate { ChildRunner r = s.Runner; if (r != null) r.ForceKill.Set(); });
            int rc = s.Begin(configPath, "консоль");
            if (rc != 0) return rc;

            int idx = WaitHandle.WaitAny(new WaitHandle[] { stopRequested, s.Runner.Exited });
            if (idx == 1 && s.TryHandleUnexpectedExit("код выхода хоста " + ExitCodes.UnexpectedExit)) return ExitCodes.UnexpectedExit;
            return s.Stop("остановка по Ctrl+C", null);
        }

        // Класс службы без SCM: OnStart -> (Ctrl+C) -> OnStop / OnShutdown / PRESHUTDOWN. Неожиданный выход
        // дочернего процесса обрабатывает тот же поток наблюдения, что и в службе (выход с кодом 4).
        private static int RunServiceTest(string configPath, string kind)
        {
            HostLog.ConsoleMode = true;
            OptomstroyService svc = new OptomstroyService(configPath);
            Console.Error.WriteLine("OptomstroySvc: service-test " + kind + ", PRESHUTDOWN " + (svc.PreshutdownEnabled ? "включён" : "недоступен"));
            ManualResetEvent stopRequested = HookCtrlC(delegate { });
            try
            {
                svc.TestStart();
            }
            catch (HostStartException ex)
            {
                Console.Error.WriteLine("OptomstroySvc: OnStart не удался, ExitCode для SCM " + svc.ExitCode + ", код хоста " + ex.Code);
                return ex.Code;
            }
            stopRequested.WaitOne();
            svc.TestControl(kind);
            Console.Error.WriteLine("OptomstroySvc: служба остановлена, ExitCode для SCM " + svc.ExitCode);
            return svc.ExitCode;
        }
    }
}
