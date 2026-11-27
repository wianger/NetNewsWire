using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

public partial class App : Application
{
    private Window? window;
    private static bool isQuitting;

    /// <summary>
    /// Quits as the Mac app does: the core saves and sends unsent read and starred changes (up to
    /// two seconds), then stops talking to the UI thread, which can then be torn down safely.
    /// </summary>
    internal static async Task QuitAsync()
    {
        if (isQuitting)
        {
            return;
        }
        isQuitting = true;
        try
        {
            await SwiftCore.PrepareToQuitAsync().WaitAsync(TimeSpan.FromSeconds(4));
        }
        catch (Exception e) when (e is TimeoutException or CoreException)
        {
            System.Diagnostics.Debug.WriteLine($"Preparing to quit: {e.Message}");
        }
        SwiftCore.Shutdown();
        Current.Exit();
    }

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        SwiftCore.Start(DispatcherQueue.GetForCurrentThread());
        var mainWindow = new MainWindow();
        window = mainWindow;
        window.Activate();

        // Closing the window quits, after the core has saved and sent its changes.
        mainWindow.AppWindow.Closing += (sender, closingArgs) =>
        {
            closingArgs.Cancel = true;
            _ = QuitAsync();
        };

        // `NetNewsWire.exe --selftest <feed-url> <report-path>`: exercises the Swift core
        // end to end, writes a JSON report, and exits.
        var commandLine = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(commandLine, "--selftest");
        if (index >= 0 && commandLine.Length > index + 2)
        {
            _ = SelfTest.RunAsync(mainWindow, commandLine[index + 1], commandLine[index + 2]);
        }

        // `NetNewsWire.exe --selftest-sync <report-path>`: syncs with the server named in the environment. See SyncSelfTest.
        var syncIndex = Array.IndexOf(commandLine, "--selftest-sync");
        if (syncIndex >= 0 && commandLine.Length > syncIndex + 1)
        {
            _ = SyncSelfTest.RunAsync(commandLine[syncIndex + 1]);
        }
    }
}
