using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Microsoft.UI.Dispatching;
using Microsoft.Win32.SafeHandles;

namespace NetNewsWire.Windows.Core;

/// <summary>
/// Managed façade over the Swift core. Call everything on the UI thread: it owns
/// Swift's main queue, so @MainActor code and every callback run there too.
/// </summary>
public static class SwiftCore
{
    private static bool started;

    /// <summary>Raised on the UI thread when something in the core changes.</summary>
    public static event Action<CoreEvent>? EventReceived;

    public static string Version => NativeMethods.TakeString(NativeMethods.nnw_core_version()) ?? "";

    /// <summary>
    /// Binds Swift's main queue to the UI thread and starts the core. Call once, on the UI
    /// thread, before anything else.
    /// </summary>
    public static void Start(DispatcherQueue uiQueue)
    {
        if (started)
        {
            return;
        }
        started = true;

        if (!NativeMethods.nnw_is_main_thread())
        {
            throw new InvalidOperationException("SwiftCore.Start must be called on the thread that owns the Swift main queue.");
        }

        StartMainQueueBridge(uiQueue);

        if (!StartCore())
        {
            throw new InvalidOperationException("The Swift core did not start.");
        }
    }

    private static unsafe bool StartCore() => NativeMethods.nnw_core_start(0, &OnEvent);

    /// <summary>Set by <see cref="Shutdown"/>: the UI thread is going away, so nothing more is sent to it.</summary>
    private static volatile bool isShutDown;

    /// <summary>Saves, and sends unsent read and starred changes. Call before <see cref="Shutdown"/>.</summary>
    public static Task PrepareToQuitAsync() =>
        RequestAsync("app.prepareToQuit", null, CoreJsonContext.Default.EmptyResult);

    /// <summary>
    /// Stops passing core events, responses, and main-queue work to the UI thread, which is about to be
    /// torn down. Work still running in the core after this has nowhere to go and is dropped.
    /// </summary>
    public static void Shutdown() => isShutDown = true;

    // MARK: - Requests

    public static Task<CoreInfo> GetInfoAsync() =>
        RequestAsync("core.info", null, CoreJsonContext.Default.CoreInfo);

    public static Task<SidebarSnapshot> GetSidebarAsync() =>
        RequestAsync("sidebar.get", null, CoreJsonContext.Default.SidebarSnapshot);

    /// <summary>ThumbnailMode small or large fills in each summary's ThumbnailURL. Newest first without a sort.</summary>
    public static Task<List<ArticleSummary>> FetchArticlesAsync(ArticleSelection selection, int? limit = null, string? thumbnailMode = null, TimelineSort? sort = null)
    {
        var parameters = new FetchArticlesParams(selection, limit, thumbnailMode, sort is null ? null : new SortParams(sort.Key, sort.Ascending), sort?.GroupByFeed);
        return RequestAsync("articles.fetch", Serialize(parameters, CoreJsonContext.Default.FetchArticlesParams), CoreJsonContext.Default.ListArticleSummary);
    }

    /// <summary>The same articles in the order of a sort. Articles that are gone are left out.</summary>
    public static Task<List<ArticleReference>> SortArticlesAsync(IEnumerable<ArticleReference> articles, TimelineSort sort)
    {
        var parameters = new SortArticlesParams([.. articles], new SortParams(sort.Key, sort.Ascending), sort.GroupByFeed);
        return RequestAsync("articles.sort", Serialize(parameters, CoreJsonContext.Default.SortArticlesParams), CoreJsonContext.Default.ListArticleReference);
    }

    /// <summary>The decoded thumbnail, or pending — which starts or moves up its download.</summary>
    public static Task<ThumbnailResult> GetThumbnailAsync(string url, string mode, string? feedName, string? articleTitle) =>
        RequestAsync("thumbnails.get", Serialize(new ThumbnailParams(url, mode, feedName, articleTitle), CoreJsonContext.Default.ThumbnailParams), CoreJsonContext.Default.ThumbnailResult);

    public static Task<ArticleDetail> GetArticleAsync(ArticleReference article) =>
        RequestAsync("article.get", Serialize(article, CoreJsonContext.Default.ArticleReference), CoreJsonContext.Default.ArticleDetail);

    /// <summary>The article page from the renderer Mac and iOS use. TextSize: small, medium, large, xlarge, xxlarge.</summary>
    public static Task<RenderedPage> RenderArticleAsync(ArticleReference article, string? textSize = null, string? themeName = null, int? windowScrollY = null) =>
        RequestAsync("article.render", Serialize(new RenderArticleParams(article.AccountID, article.ArticleID, textSize, themeName, windowScrollY), CoreJsonContext.Default.RenderArticleParams), CoreJsonContext.Default.RenderedPage);

    /// <summary>A page with a message in place of an article, such as “No selection”, in the same theme.</summary>
    public static Task<RenderedPage> RenderMessageAsync(string message, string? themeName = null) =>
        RequestAsync("article.renderMessage", Serialize(new RenderMessageParams(message, themeName), CoreJsonContext.Default.RenderMessageParams), CoreJsonContext.Default.RenderedPage);

    /// <summary>The default theme first, then the app's and installed themes by name.</summary>
    public static Task<List<ThemeInfo>> ListThemesAsync() =>
        RequestAsync("themes.list", null, CoreJsonContext.Default.ListThemeInfo);

    /// <summary>Copies a .nnwtheme folder into the installed themes.</summary>
    public static Task<ThemeInfo> InstallThemeAsync(string folderPath) =>
        RequestAsync("themes.install", Serialize(new InstallThemeParams(folderPath), CoreJsonContext.Default.InstallThemeParams), CoreJsonContext.Default.ThemeInfo);

    public static Task DeleteThemeAsync(string name) =>
        RequestAsync("themes.delete", Serialize(new ThemeNameParams(name), CoreJsonContext.Default.ThemeNameParams), CoreJsonContext.Default.EmptyResult);

    /// <summary>What a URL the app was opened with means, as the Mac decides: a feed to add, a theme, or nothing.</summary>
    public static Task<OpenedURLAction> InterpretOpenedURLAsync(string url) =>
        RequestAsync("app.interpretOpenedURL", Serialize(new OpenedURLParams(url), CoreJsonContext.Default.OpenedURLParams), CoreJsonContext.Default.OpenedURLAction);

    // Accounts

    /// <summary>The sync services this build can add.</summary>
    public static Task<List<AccountTypeInfo>> GetAccountTypesAsync() =>
        RequestAsync("accounts.types", null, CoreJsonContext.Default.ListAccountTypeInfo);

    /// <summary>Signs in to the service, then adds the account and starts refreshing it. Errors: invalidParams, invalidCredentials, duplicate, failed.</summary>
    public static Task<AddedAccount> AddAccountAsync(string type, string? username, string? password, string? apiToken, string? apiURL) =>
        RequestAsync("accounts.add", Serialize(new AddAccountParams(type, username, password, apiToken, apiURL), CoreJsonContext.Default.AddAccountParams), CoreJsonContext.Default.AddedAccount);

    public static Task DeleteAccountAsync(string accountID) =>
        RequestAsync("accounts.delete", Serialize(new AccountIDParams(accountID), CoreJsonContext.Default.AccountIDParams), CoreJsonContext.Default.EmptyResult);

    public static Task SetAccountActiveAsync(string accountID, bool isActive) =>
        RequestAsync("accounts.setActive", Serialize(new SetAccountActiveParams(accountID, isActive), CoreJsonContext.Default.SetAccountActiveParams), CoreJsonContext.Default.EmptyResult);

    /// <summary>The scripts every article page needs, in order (main.js, newsfoot.js).</summary>
    public static async Task<List<string>> GetArticleScriptsAsync() =>
        (await RequestAsync("article.scripts", null, CoreJsonContext.Default.ArticleScripts)).Scripts;

    /// <summary>The feed's icon: its own, its home page's, its favicon, or a generated one — as on the Mac.</summary>
    public static Task<IconResult> GetFeedIconAsync(string accountID, string feedID) =>
        RequestAsync("icons.feed", Serialize(new FeedIconParams(accountID, feedID), CoreJsonContext.Default.FeedIconParams), CoreJsonContext.Default.IconResult);

    /// <summary>The image at the top of the article page: the author's avatar, else the feed's icon.</summary>
    public static Task<IconResult> GetArticleIconAsync(ArticleReference article) =>
        RequestAsync("icons.article", Serialize(article, CoreJsonContext.Default.ArticleReference), CoreJsonContext.Default.IconResult);

    public static Task MarkArticlesAsync(IEnumerable<ArticleReference> articles, bool read) =>
        MarkAsync(articles, "read", read);

    public static Task StarArticlesAsync(IEnumerable<ArticleReference> articles, bool starred) =>
        MarkAsync(articles, "starred", starred);

    public static Task<FeedInfo> SubscribeAsync(string url, string? name = null, string? accountID = null, int? folderID = null) =>
        RequestAsync("feeds.subscribe", Serialize(new SubscribeParams(url, name, accountID, folderID), CoreJsonContext.Default.SubscribeParams), CoreJsonContext.Default.FeedInfo);

    public static Task DeleteFeedAsync(string accountID, string feedID, int? folderID) =>
        RequestAsync("feeds.delete", Serialize(new FeedLocationParams(accountID, feedID, folderID), CoreJsonContext.Default.FeedLocationParams), CoreJsonContext.Default.EmptyResult);

    public static Task RenameFeedAsync(string accountID, string feedID, string name) =>
        RequestAsync("feeds.rename", Serialize(new RenameFeedParams(accountID, feedID, name), CoreJsonContext.Default.RenameFeedParams), CoreJsonContext.Default.EmptyResult);

    public static Task MoveFeedAsync(string accountID, string feedID, int? fromFolderID, int? toFolderID) =>
        RequestAsync("feeds.move", Serialize(new MoveFeedParams(accountID, feedID, fromFolderID, toFolderID), CoreJsonContext.Default.MoveFeedParams), CoreJsonContext.Default.EmptyResult);

    public static Task<FolderInfo> AddFolderAsync(string name, string? accountID = null) =>
        RequestAsync("folders.add", Serialize(new AddFolderParams(accountID, name), CoreJsonContext.Default.AddFolderParams), CoreJsonContext.Default.FolderInfo);

    public static Task RenameFolderAsync(string accountID, int folderID, string name) =>
        RequestAsync("folders.rename", Serialize(new RenameFolderParams(accountID, folderID, name), CoreJsonContext.Default.RenameFolderParams), CoreJsonContext.Default.EmptyResult);

    public static Task DeleteFolderAsync(string accountID, int folderID) =>
        RequestAsync("folders.delete", Serialize(new FolderLocationParams(accountID, folderID), CoreJsonContext.Default.FolderLocationParams), CoreJsonContext.Default.EmptyResult);

    public static Task ImportOpmlAsync(string path, string? accountID = null) =>
        RequestAsync("opml.import", Serialize(new ImportOpmlParams(path, accountID), CoreJsonContext.Default.ImportOpmlParams), CoreJsonContext.Default.EmptyResult);

    public static async Task<string> ExportOpmlAsync(string? accountID = null) =>
        (await RequestAsync("opml.export", Serialize(new AccountParams(accountID), CoreJsonContext.Default.AccountParams), CoreJsonContext.Default.ExportOpmlResult)).Opml;

    public static Task<RefreshResult> RefreshAllAsync() =>
        RequestAsync("refresh.all", null, CoreJsonContext.Default.RefreshResult);

    private static Task MarkAsync(IEnumerable<ArticleReference> articles, string key, bool flag) =>
        RequestAsync("articles.mark", Serialize(new MarkArticlesParams(articles.ToList(), key, flag), CoreJsonContext.Default.MarkArticlesParams), CoreJsonContext.Default.EmptyResult);

    /// <summary>Sends one request. Throws <see cref="CoreException"/> if the core reports an error.</summary>
    private static async Task<T> RequestAsync<T>(string method, string? paramsJson, JsonTypeInfo<T> resultType)
    {
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = GCHandle.ToIntPtr(GCHandle.Alloc(completion));
        SendRequest(method, paramsJson, context);
        var response = await completion.Task;

        using var document = JsonDocument.Parse(response);
        var root = document.RootElement;
        if (root.TryGetProperty("error", out var error))
        {
            var body = error.Deserialize(CoreJsonContext.Default.CoreErrorBody);
            throw new CoreException(body?.Code ?? "failed", body?.Message ?? response);
        }
        if (!root.TryGetProperty("result", out var result))
        {
            throw new CoreException("failed", $"{method}: no result in {response}");
        }
        return result.Deserialize(resultType) ?? throw new CoreException("failed", $"{method}: empty result");
    }

    // Function pointers need an unsafe context, which can't contain an await.
    private static unsafe void SendRequest(string method, string? paramsJson, nint context) =>
        NativeMethods.nnw_request(method, paramsJson, context, &OnResponse);

    private static string Serialize<T>(T value, JsonTypeInfo<T> typeInfo) => JsonSerializer.Serialize(value, typeInfo);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void OnResponse(nint context, nint json)
    {
        var handle = GCHandle.FromIntPtr(context);
        var completion = (TaskCompletionSource<string>)handle.Target!;
        handle.Free();
        var text = NativeMethods.TakeString(json) ?? "{}";
        if (!isShutDown)
        {
            completion.SetResult(text);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void OnEvent(nint context, nint json)
    {
        var text = NativeMethods.TakeString(json);
        if (text is null || isShutDown)
        {
            return;
        }
        try
        {
            if (JsonSerializer.Deserialize(text, CoreJsonContext.Default.CoreEvent) is { } coreEvent)
            {
                EventReceived?.Invoke(coreEvent);
            }
        }
        catch (Exception e)
        {
            // An exception must not unwind into Swift.
            System.Diagnostics.Debug.WriteLine($"SwiftCore event handler failed: {e}");
        }
    }

    // MARK: - Main queue

    /// <summary>
    /// Waits for Swift to enqueue main-queue work, then drains it on the UI thread.
    /// See Windows/Core/Sources/NetNewsWireCore/MainQueueBridge.swift.
    /// </summary>
    private static void StartMainQueueBridge(DispatcherQueue uiQueue)
    {
        var handle = NativeMethods.nnw_main_queue_handle();
        var mainQueueEvent = new ManualResetEvent(false) { SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false) };
        var drained = new AutoResetEvent(false);

        // Waiting for `drained` before waiting again keeps a manual-reset event from spinning.
        var bridge = new Thread(() =>
        {
            while (true)
            {
                mainQueueEvent.WaitOne();
                if (isShutDown)
                {
                    return;
                }
                var enqueued = uiQueue.TryEnqueue(() =>
                {
                    if (!isShutDown)
                    {
                        NativeMethods.nnw_drain_main_queue();
                    }
                    drained.Set();
                });
                if (!enqueued)
                {
                    return; // The UI thread is shutting down.
                }
                drained.WaitOne();
            }
        })
        {
            IsBackground = true,
            Name = "Swift main queue bridge"
        };
        bridge.Start();
    }
}
