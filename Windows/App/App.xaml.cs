using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

public partial class App : Application
{
    private Window? window;

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

        // `NetNewsWire.exe --selftest <feed-url> <report-path>`: exercises the Swift core
        // end to end, writes a JSON report, and exits.
        var commandLine = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(commandLine, "--selftest");
        if (index >= 0 && commandLine.Length > index + 2)
        {
            _ = SelfTest.RunAsync(mainWindow, commandLine[index + 1], commandLine[index + 2]);
        }
    }
}
