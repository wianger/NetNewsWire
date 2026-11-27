using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

public partial class App : Application
{
    private static MainWindow? mainWindow;
    private static DispatcherQueue? uiQueue;
    private static bool isQuitting;

    /// <summary>
    /// A later launch, redirected here by <see cref="Program"/>: brings the window forward, and opens
    /// the URL it carried, such as a feed: link. Called on a background thread.
    /// </summary>
    internal static void HandleActivation(AppActivationArguments activation)
    {
        var url = Program.OpenedURL(activation);
        uiQueue?.TryEnqueue(async () =>
        {
            if (mainWindow is null)
            {
                return;
            }
            mainWindow.BringToFront();
            if (url is not null)
            {
                await mainWindow.OpenURLAsync(url);
            }
        });
    }

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
        uiQueue = DispatcherQueue.GetForCurrentThread();
        SwiftCore.Start(uiQueue);
        var mainWindow = new MainWindow();
        App.mainWindow = mainWindow;
        mainWindow.Activate();

        // Opened with a URL, such as a feed: link, when it wasn't running.
        if (Program.OpenedURL(AppInstance.GetCurrent().GetActivatedEventArgs()) is { } openedURL)
        {
            _ = mainWindow.OpenURLAsync(openedURL);
        }

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

        // `NetNewsWire.exe --selftest-activation <report-path>`: waits for a second launch to hand it a URL. See SelfTest.
        var activationIndex = Array.IndexOf(commandLine, "--selftest-activation");
        if (activationIndex >= 0 && commandLine.Length > activationIndex + 1)
        {
            _ = SelfTest.RunActivationAsync(mainWindow, commandLine[activationIndex + 1]);
        }

        // `NetNewsWire.exe --selftest-sync <report-path>`: syncs with the server named in the environment. See SyncSelfTest.
        var syncIndex = Array.IndexOf(commandLine, "--selftest-sync");
        if (syncIndex >= 0 && commandLine.Length > syncIndex + 1)
        {
            _ = SyncSelfTest.RunAsync(commandLine[syncIndex + 1]);
        }
    }
}
