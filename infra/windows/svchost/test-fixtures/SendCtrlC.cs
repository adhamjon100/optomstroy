// Вспомогательная программа тестов: посылает Ctrl+C (или Ctrl+Break) в консоль процесса с указанным PID —
// так же, как это делает человек, нажимая Ctrl+C в окне OptomstroySvc.exe --console.
// SendCtrlC.exe <pid> [break]
using System;
using System.Runtime.InteropServices;
using System.Threading;

internal static class SendCtrlC
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);

    private static int Main(string[] args)
    {
        uint pid = uint.Parse(args[0]);
        uint ev = (args.Length > 1 && args[1] == "break") ? 1u : 0u;
        FreeConsole();
        if (!AttachConsole(pid)) return 10;
        SetConsoleCtrlHandler(IntPtr.Zero, true); // сами не реагируем
        bool ok = GenerateConsoleCtrlEvent(ev, 0);
        Thread.Sleep(300);
        FreeConsole();
        return ok ? 0 : 11;
    }
}
