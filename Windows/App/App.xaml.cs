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
        var notificationArguments = (activation.Data as Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs)?.Arguments;
        uiQueue?.TryEnqueue(async () =>
        {
            if (mainWindow is null)
            {
                return;
            }
            mainWindow.BringToFront();
            if (notificationArguments is not null)
            {
                await mainWindow.HandleNotificationAsync(notificationArguments);
            }
            else if (url is not null)
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
        // Before anything else, so a notification click that launched the app is delivered.
        NotificationService.Invoked += arguments => uiQueue?.TryEnqueue(async () =>
        {
            if (mainWindow is not null)
            {
                mainWindow.BringToFront();
                await mainWindow.HandleNotificationAsync(arguments);
            }
        });
        NotificationService.Register();
        SwiftCore.Start(uiQueue);
        var window = new MainWindow();
        mainWindow = window;
        window.Activate();

        // Opened with a URL, such as a feed: link, or by a notification click, when it wasn't running.
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        if (activation.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notificationActivation)
        {
            _ = window.HandleNotificationAsync(notificationActivation.Arguments);
        }
        else if (Program.OpenedURL(activation) is { } openedURL)
        {
            _ = window.OpenURLAsync(openedURL);
        }

        // Closing the window quits, after the core has saved and sent its changes.
        window.AppWindow.Closing += (sender, closingArgs) =>
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
            _ = SelfTest.RunAsync(window, commandLine[index + 1], commandLine[index + 2]);
        }

        // `NetNewsWire.exe --selftest-activation <report-path>`: waits for a second launch to hand it a URL. See SelfTest.
        var activationIndex = Array.IndexOf(commandLine, "--selftest-activation");
        if (activationIndex >= 0 && commandLine.Length > activationIndex + 1)
        {
            _ = SelfTest.RunActivationAsync(window, commandLine[activationIndex + 1]);
        }

        // `NetNewsWire.exe --selftest-sync <report-path>`: syncs with the server named in the environment. See SyncSelfTest.
        var syncIndex = Array.IndexOf(commandLine, "--selftest-sync");
        if (syncIndex >= 0 && commandLine.Length > syncIndex + 1)
        {
            _ = SyncSelfTest.RunAsync(commandLine[syncIndex + 1]);
        }
    }
}
