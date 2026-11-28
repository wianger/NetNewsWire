using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using NetNewsWire.Windows.Core;
using Windows.System;

namespace NetNewsWire.Windows;

/// <summary>
/// The article pane: a WebView2 showing pages from the shared renderer, with the same scripts
/// the Mac and iOS web views load (main.js, newsfoot.js) plus main_windows.js.
/// Links open in the default browser, as on the Mac.
/// </summary>
internal sealed class ArticleViewController(WebView2 webView)
{
    private Task? setup;
    private CoreWebView2Environment? environment;
    private ArticleReference? shownArticle;
    private string? shownMessage;

    /// <summary>
    /// The scheme of the page's `[[avatar_src]]` (CoreService.imageIconScheme, nnwImageIcon), answered with the
    /// article's icon. Lowercase: Chromium canonicalizes schemes, so that's how requests arrive.
    /// </summary>
    private const string ImageIconScheme = "nnwimageicon";

    /// <summary>The link under the pointer, or null. Raised on the UI thread.</summary>
    public event Action<string?>? HoveredLinkChanged;

    /// <summary>A shortcut key pressed while the page has focus. WebView2 is its own window, so the app's own key handling never sees it.</summary>
    public event Action<(string Key, bool Shift)>? KeyPressed;

    public Task ShowArticleAsync(ArticleReference article)
    {
        shownArticle = article;
        shownMessage = null;
        var settings = AppSettings.Current;
        return ShowAsync(() => SwiftCore.RenderArticleAsync(article, settings.TextSize, settings.ThemeName));
    }

    public Task ShowMessageAsync(string message)
    {
        shownArticle = null;
        shownMessage = message;
        return ShowAsync(() => SwiftCore.RenderMessageAsync(message, AppSettings.Current.ThemeName));
    }

    /// <summary>Shows the same article or message again, after a theme or text size change.</summary>
    public Task ReloadAsync() =>
        shownArticle is { } article ? ShowArticleAsync(article)
        : shownMessage is { } message ? ShowMessageAsync(message)
        : Task.CompletedTask;

    /// <summary>Renders the article and reports whether WebView2 finished navigating successfully.</summary>
    public async Task<bool> ShowArticleAndWaitAsync(ArticleReference article)
    {
        await EnsureSetUpAsync();
        var completion = new TaskCompletionSource<bool>();
        void OnCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args) => completion.TrySetResult(args.IsSuccess);
        webView.CoreWebView2.NavigationCompleted += OnCompleted;
        try
        {
            await ShowArticleAsync(article);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(30));
        }
        finally
        {
            webView.CoreWebView2.NavigationCompleted -= OnCompleted;
        }
    }

    /// <summary>Runs JavaScript in the page and returns its JSON result. For the self-test.</summary>
    public async Task<string> EvaluateAsync(string script)
    {
        await EnsureSetUpAsync();
        return await webView.CoreWebView2.ExecuteScriptAsync(script);
    }

    private async Task ShowAsync(Func<Task<RenderedPage>> render)
    {
        await EnsureSetUpAsync();
        var page = await render();
        webView.NavigateToString(page.Html);
    }

    private Task EnsureSetUpAsync() => setup ??= SetUpAsync();

    private async Task SetUpAsync()
    {
        // Custom schemes can only be registered as the environment is created. The user data goes
        // with the rest of the app's data, not next to the exe, which may not be writable.
        var registration = new CoreWebView2CustomSchemeRegistration(ImageIconScheme) { TreatAsSecure = 1 }; // BOOL, projected as Int32 in this WinRT projection.
        registration.AllowedOrigins.Add("*");
        var options = new CoreWebView2EnvironmentOptions { CustomSchemeRegistrations = [registration] };
        var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(localAppData, "NetNewsWire", "WebView2"), options);
        await webView.EnsureCoreWebView2Async(environment);
        var core = webView.CoreWebView2;

        core.AddWebResourceRequestedFilter($"{ImageIconScheme}:*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnWebResourceRequested;

        foreach (var script in await SwiftCore.GetArticleScriptsAsync())
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(script);
        }
        await core.AddScriptToExecuteOnDocumentCreatedAsync(LoadEmbeddedScript("main_windows.js"));

        core.Settings.AreDevToolsEnabled = System.Diagnostics.Debugger.IsAttached;
        core.Settings.IsStatusBarEnabled = false; // The app shows the hovered link itself.
        core.Settings.AreDefaultContextMenusEnabled = true;

        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindowRequested;
        core.WebMessageReceived += OnWebMessageReceived;
    }

    /// <summary>`nnwImageIcon:&lt;articleID&gt;`: the shown article's avatar or feed icon, as the Mac's DetailWebViewController answers it.</summary>
    private async void OnWebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        if (environment is null || shownArticle is not { } article)
        {
            return;
        }
        var uri = args.Request.Uri;
        var requestedID = Uri.UnescapeDataString(uri[(uri.IndexOf(':') + 1)..]);
        if (requestedID != article.ArticleID)
        {
            return;
        }
        var deferral = args.GetDeferral();
        try
        {
            if (await IconCache.ArticleIconPngAsync(article) is { } png)
            {
                var stream = new global::Windows.Storage.Streams.InMemoryRandomAccessStream();
                await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(png));
                stream.Seek(0);
                args.Response = environment.CreateWebResourceResponse(stream, 200, "OK", "Content-Type: image/png");
            }
        }
        finally
        {
            deferral.Complete();
        }
    }

    /// <summary>The page itself loads from a string (about:blank). Anything else is a link the user clicked.</summary>
    private static void OnNavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (args.Uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase) || args.Uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        args.Cancel = true;
        OpenInBrowser(args.Uri);
    }

    private static void OnNewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        OpenInBrowser(args.Uri);
    }

    private static void OpenInBrowser(string uri)
    {
        if (Uri.TryCreate(uri, UriKind.Absolute, out var parsed) && (parsed.Scheme == Uri.UriSchemeHttp || parsed.Scheme == Uri.UriSchemeHttps || parsed.Scheme == Uri.UriSchemeMailto))
        {
            _ = Launcher.LaunchUriAsync(parsed);
        }
    }

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        try
        {
            using var message = JsonDocument.Parse(args.WebMessageAsJson);
            var type = message.RootElement.GetProperty("type").GetString();
            switch (type)
            {
                case "mouseDidEnter":
                    HoveredLinkChanged?.Invoke(message.RootElement.GetProperty("href").GetString());
                    break;
                case "mouseDidExit":
                    HoveredLinkChanged?.Invoke(null);
                    break;
                case "keyDown":
                    var key = message.RootElement.GetProperty("key").GetString();
                    var shift = message.RootElement.TryGetProperty("shift", out var shiftValue) && shiftValue.GetBoolean();
                    if (key is not null)
                    {
                        KeyPressed?.Invoke((key, shift));
                    }
                    break;
            }
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            // A page can post anything; ignore what isn't ours.
        }
    }

    private static string LoadEmbeddedScript(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"Missing embedded script {name}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
