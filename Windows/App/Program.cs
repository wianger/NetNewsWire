using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace NetNewsWire.Windows;

/// <summary>
/// One app per data folder, as on the Mac: a second launch — a feed: link clicked in a browser, or
/// the app started again — hands its activation to the running app and exits, rather than opening
/// the same database twice. Uses the Windows App SDK's AppInstance redirection.
/// </summary>
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        if (RedirectedToRunningInstance())
        {
            return 0;
        }
        Application.Start(callbackParams =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }

    /// <summary>The URL this instance was opened with, if any: a protocol activation, or a URL on the command line.</summary>
    internal static string? OpenedURL(AppActivationArguments activation)
    {
        switch (activation.Kind)
        {
            case ExtendedActivationKind.Protocol when activation.Data is global::Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs protocol:
                return protocol.Uri.OriginalString;
            case ExtendedActivationKind.Launch when activation.Data is global::Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch:
                // An unpackaged app registered for a scheme is started with the URL as its argument.
                // Options (the self-tests' --selftest and friends) aren't URLs.
                var arguments = ArgumentsAfterProgramName(launch.Arguments ?? "").Trim().Trim('"');
                return arguments.Length > 0 && !arguments.StartsWith("--", StringComparison.Ordinal) && !arguments.Contains(' ') ? arguments : null;
            default:
                return null;
        }
    }

    /// <summary>
    /// The arguments without the program's path. A redirected launch's Arguments is the whole command
    /// line, starting with the exe's path, quoted or not; the first launch's may be the arguments alone.
    /// </summary>
    internal static string ArgumentsAfterProgramName(string commandLine)
    {
        var text = commandLine.TrimStart();
        string first;
        string rest;
        if (text.StartsWith('"'))
        {
            var closingQuote = text.IndexOf('"', 1);
            first = closingQuote > 0 ? text[1..closingQuote] : text[1..];
            rest = closingQuote > 0 ? text[(closingQuote + 1)..] : "";
        }
        else
        {
            var space = text.IndexOf(' ');
            first = space >= 0 ? text[..space] : text;
            rest = space >= 0 ? text[space..] : "";
        }
        return first.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? rest : text;
    }

    private static bool RedirectedToRunningInstance()
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        var instance = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (instance.IsCurrent)
        {
            instance.Activated += (_, redirected) => App.HandleActivation(redirected);
            return false;
        }
        // Off the UI thread, so this STA thread doesn't wait on itself.
        Task.Run(async () => await instance.RedirectActivationToAsync(activation)).Wait();
        return true;
    }

    /// <summary>One instance per data folder: the core's database can only be open in one process.</summary>
    private static string InstanceKey
    {
        get
        {
            var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var hash = SHA256.HashData(Encoding.UTF8.GetBytes(localAppData.ToUpperInvariant()));
            return "NetNewsWire-" + Convert.ToHexString(hash, 0, 8);
        }
    }
}
