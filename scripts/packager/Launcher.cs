using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Launcher
{
#if WINDOWS_INSTALLER
    private const string DefaultTarget = "WindowsInstaller";
    private const string DefaultTargetOption = "windows-installer";
    private const string ProgramFileName = "一键打包Windows安装包.exe";
    private const string ProgramTitle = "Kazumi Plus 一键打包 Windows 安装包";
    private const string DefaultBehavior = "双击直接生成 Windows 安装包；成功后打开产物目录。";
#else
    private const string DefaultTarget = "All";
    private const string DefaultTargetOption = "all";
    private const string ProgramFileName = "一键打包.exe";
    private const string ProgramTitle = "Kazumi Plus 一键打包";
    private const string DefaultBehavior = "双击直接打包 Windows、Android 手机、Android TV；成功后打开产物目录。";
#endif

    private static int Main(string[] args)
    {
        bool pause = true;
        int exitCode = 1;
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);

        // 即使其他参数有误，也尊重脚本调用方关闭暂停的要求。
        foreach (string arg in args)
        {
            if (String.Equals(arg, "--no-pause", StringComparison.OrdinalIgnoreCase))
                pause = false;
        }

        try
        {
            string target = DefaultTarget;
            bool allowDirty = true;
            bool openOutput = true;
            bool help = false;

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i].ToLowerInvariant();
                switch (arg)
                {
                    case "--target":
                        if (++i >= args.Length)
                            throw new ArgumentException("--target 后需要指定 all、windows、windows-installer、android 或 android-tv。");
                        target = ParseTarget(args[i]);
                        break;
                    case "--require-clean":
                        allowDirty = false;
                        break;
                    case "--no-pause":
                        pause = false;
                        break;
                    case "--no-open":
                        openOutput = false;
                        break;
                    case "--help":
                    case "-h":
                        help = true;
                        break;
                    default:
                        throw new ArgumentException("无法识别参数：" + args[i] + "。请使用 --help 查看用法。");
                }
            }

            if (help)
            {
                PrintHelp();
                exitCode = 0;
            }
            else
            {
                // 项目位置由程序本身确定，支持从快捷方式或其他目录启动。
                string projectDirectory = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(projectDirectory, "scripts", "package_plus.ps1");
                if (!File.Exists(scriptPath))
                    throw new FileNotFoundException("未找到打包脚本。请将 " + ProgramFileName + " 保留在项目根目录：" + scriptPath);

                string powerShell = FindPowerShell();
                if (powerShell == null)
                    throw new FileNotFoundException("未找到 PowerShell 7。请安装 PowerShell 7.2 或更新版本，再运行 " + ProgramFileName + "。");

                List<string> childArgs = new List<string>();
                childArgs.Add("-NoLogo");
                childArgs.Add("-NoProfile");
                childArgs.Add("-ExecutionPolicy");
                childArgs.Add("Bypass");
                childArgs.Add("-File");
                childArgs.Add(scriptPath);
                childArgs.Add("-Target");
                childArgs.Add(target);
                if (allowDirty)
                    childArgs.Add("-AllowDirty");
                if (openOutput)
                    childArgs.Add("-OpenOutput");

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powerShell;
                startInfo.Arguments = JoinArguments(childArgs);
                startInfo.WorkingDirectory = projectDirectory;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = false;

                Console.WriteLine(ProgramTitle);
                Console.WriteLine("项目目录：" + projectDirectory);
                Console.WriteLine("打包目标：" + target);
                Console.WriteLine(allowDirty ? "源码范围：当前工作区（允许未提交修改）" : "源码要求：干净的工作区");
                Console.WriteLine();

                // 子进程继承当前控制台；等待同一进程结束并原样返回它的退出码。
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                        throw new InvalidOperationException("无法启动 PowerShell 打包进程。");
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }

                Console.WriteLine();
                Console.WriteLine(exitCode == 0 ? "打包已完成。" : "打包未完成，退出码：" + exitCode + "。请查看上方错误及构建日志。");
            }
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine("参数错误：" + exception.Message);
            exitCode = 2;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("打包启动失败：" + exception.Message);
            exitCode = 1;
        }
        finally
        {
            PauseIfInteractive(pause);
        }

        return exitCode;
    }

    private static string ParseTarget(string value)
    {
        switch (value.ToLowerInvariant())
        {
            case "all": return "All";
            case "windows": return "Windows";
            case "windows-installer": return "WindowsInstaller";
            case "android": return "Android";
            case "android-tv": return "AndroidTv";
            default: throw new ArgumentException("不支持的打包目标：" + value + "。可选 all、windows、windows-installer、android、android-tv。");
        }
    }

    private static string FindPowerShell()
    {
        // 优先使用官方默认安装位置，再检查 PATH；最低版本由打包脚本校验。
        string programFiles = Environment.GetEnvironmentVariable("ProgramW6432");
        if (String.IsNullOrEmpty(programFiles))
            programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string installedPath = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
        if (File.Exists(installedPath))
            return installedPath;

        string searchPath = Environment.GetEnvironmentVariable("PATH") ?? String.Empty;
        foreach (string entry in searchPath.Split(Path.PathSeparator))
        {
            string directory = entry.Trim().Trim('"');
            if (directory.Length == 0)
                continue;
            try
            {
                string candidate = Path.Combine(directory, "pwsh.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
            catch (ArgumentException)
            {
                // PATH 中无效的目录不应阻止检查后续条目。
            }
        }
        return null;
    }

    private static string JoinArguments(IEnumerable<string> arguments)
    {
        List<string> quoted = new List<string>();
        foreach (string argument in arguments)
            quoted.Add(QuoteArgument(argument));
        return String.Join(" ", quoted.ToArray());
    }

    private static string QuoteArgument(string argument)
    {
        // 遵循 Windows 命令行规则，防止空格、引号和末尾反斜杠改变参数边界。
        StringBuilder quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                slashes++;
            }
            else if (character == '"')
            {
                quoted.Append('\\', slashes * 2 + 1);
                quoted.Append('"');
                slashes = 0;
            }
            else
            {
                quoted.Append('\\', slashes);
                quoted.Append(character);
                slashes = 0;
            }
        }
        quoted.Append('\\', slashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static void PrintHelp()
    {
        Console.WriteLine(ProgramTitle);
        Console.WriteLine(DefaultBehavior);
        Console.WriteLine();
        Console.WriteLine("用法：" + ProgramFileName + " [选项]");
        Console.WriteLine("  --target all|windows|windows-installer|android|android-tv");
        Console.WriteLine("                               指定目标（默认 " + DefaultTargetOption + "）");
        Console.WriteLine("  --require-clean              要求工作区没有未提交修改");
        Console.WriteLine("  --no-pause                   结束后直接退出");
        Console.WriteLine("  --no-open                    成功后不打开产物目录");
        Console.WriteLine("  --help                       显示本说明");
        Console.WriteLine();
#if WINDOWS_INSTALLER
        Console.WriteLine("需要 PowerShell 7.2+、项目 Windows 构建环境与安装包编译器。");
#else
        Console.WriteLine("需要 PowerShell 7.2+ 和项目既有 Flutter/Android/Windows 构建环境。");
#endif
    }

    private static void PauseIfInteractive(bool pause)
    {
        if (!pause || Console.IsInputRedirected)
            return;
        try
        {
            Console.WriteLine();
            Console.Write("按任意键关闭窗口……");
            Console.ReadKey(true);
        }
        catch (InvalidOperationException)
        {
            // 无可用控制台时保留原退出码，避免暂停失败覆盖构建结果。
        }
        catch (IOException)
        {
            // 控制台已经关闭时直接退出。
        }
    }
}
