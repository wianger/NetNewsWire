using System.Text.Json;
using Microsoft.UI.Xaml;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

/// <summary>
/// Headless end-to-end check of the app and the Swift core, used by CI:
/// `NetNewsWire.exe --selftest &lt;feed-url&gt; &lt;report-path&gt;`. Subscribes the local account to
/// the feed (or finds it), refreshes, fetches its articles, marks one read, and renders it.
/// </summary>
internal static class SelfTest
{
    public static async Task RunAsync(MainWindow window, string feedUrl, string reportPath)
    {
        var report = new Dictionary<string, object?>
        {
            ["coreVersion"] = SwiftCore.Version,
            ["uiThreadIsSwiftMainThread"] = NativeMethods.nnw_is_main_thread(),
        };
        var events = new List<string>();
        SwiftCore.EventReceived += coreEvent => events.Add(coreEvent.Kind);

        try
        {
            var uiThreadId = Environment.CurrentManagedThreadId;
            report["dataFolder"] = (await SwiftCore.GetInfoAsync()).DataFolder;
            report["continuationOnUIThread"] = Environment.CurrentManagedThreadId == uiThreadId;

            var feed = await FindFeedAsync(feedUrl);
            if (feed is null)
            {
                feed = await SwiftCore.SubscribeAsync(feedUrl).WaitAsync(TimeSpan.FromSeconds(60));
                report["subscribed"] = true;
            }
            report["feedName"] = feed.Name;

            var refresh = await SwiftCore.RefreshAllAsync().WaitAsync(TimeSpan.FromSeconds(120));
            report["refreshed"] = refresh.DidRefresh;
            report["refreshErrors"] = refresh.Errors;

            // The feed's icon: downloaded (feed icon, home page icon, or favicon) and decoded by WIC,
            // or the generated one if none arrives in time.
            var iconsChanged = new TaskCompletionSource();
            SwiftCore.EventReceived += coreEvent =>
            {
                if (coreEvent.Kind == "iconsChanged")
                {
                    iconsChanged.TrySetResult();
                }
            };
            _ = await SwiftCore.GetFeedIconAsync(feed.AccountID, feed.FeedID); // Starts the downloads.
            await Task.WhenAny(iconsChanged.Task, Task.Delay(TimeSpan.FromSeconds(30)));
            var feedIcon = await SwiftCore.GetFeedIconAsync(feed.AccountID, feed.FeedID);
            report["feedIcon"] = $"{feedIcon.Width}x{feedIcon.Height} generated={feedIcon.IsBackgroundSuppressed} dark={feedIcon.IsDark} bright={feedIcon.IsBright}";

            var articles = await SwiftCore.FetchArticlesAsync(new ArticleSelection("feed", feed.AccountID, feed.FeedID));
            report["articleCount"] = articles.Count;
            report["firstTitle"] = articles.FirstOrDefault()?.Title;

            if (articles.FirstOrDefault() is { } first)
            {
                await SwiftCore.MarkArticlesAsync([first.Reference], read: true);
                var detail = await SwiftCore.GetArticleAsync(first.Reference);
                report["markedRead"] = detail.IsRead;
                await SwiftCore.MarkArticlesAsync([first.Reference], read: false);

                var sidebar = await SwiftCore.GetSidebarAsync();
                report["totalUnreadCount"] = sidebar.TotalUnreadCount;
                report["webView2Rendered"] = await window.ShowArticleForSelfTestAsync(first.Reference);
                // The shared renderer's page, with the scripts Mac and iOS load and main_windows.js.
                report["pageFeedLink"] = await window.EvaluateInArticleAsync("document.querySelector('.feedlink')?.textContent ?? null");
                report["pageTitle"] = await window.EvaluateInArticleAsync("document.querySelector('.articleTitle')?.textContent?.trim() ?? null");
                report["sharedScriptsLoaded"] = await window.EvaluateInArticleAsync("typeof processPage === 'function' && typeof postRenderProcessing === 'function'");
            }

            // The window, driven as a user would: focus, the N and R shortcuts, the article page.
            report["initialFocus"] = window.FocusedElementForSelfTest();
            var (toolbarString, sidebarString, codeString) = window.LocalizedStringsForSelfTest();
            report["stringToolbar"] = toolbarString;
            report["stringSidebar"] = sidebarString;
            report["stringCode"] = codeString;
            await window.SelectSidebarItemForSelfTestAsync("smart:unread");
            var (title, isRead) = await window.PressShortcutForSelfTestAsync("n");
            report["shortcutNextUnreadSelected"] = title;
            report["shownArticleMarkedRead"] = isRead;
            report["shownPageTitle"] = await window.EvaluateInArticleAsync("document.querySelector('.articleTitle')?.textContent?.trim() ?? null");
            // Sorting, as the Mac's sort menu: the same rows in a new order, the selection and the article kept.
            var (byTitle, selectedAfterSort, shownAfterSort) = await window.SortForSelfTestAsync("title", ascending: true, groupByFeed: false);
            report["sortedByTitle"] = byTitle.SequenceEqual(byTitle.Order(StringComparer.CurrentCultureIgnoreCase));
            report["sortKeptSelection"] = selectedAfterSort == title && shownAfterSort is not null && shownAfterSort != "null";
            report["sortRowCount"] = byTitle.Count;
            report["sortMenuByTitle"] = string.Join(", ", window.SortMenuForSelfTest());
            (var byDate, _, _) = await window.SortForSelfTestAsync("date", ascending: false, groupByFeed: false);
            report["sortRestoredRowCount"] = byDate.Count;
            report["sortMenuByDate"] = string.Join(", ", window.SortMenuForSelfTest());
            await Task.Delay(1000);
            report["articleIconWidth"] = await window.EvaluateInArticleAsync("document.getElementById('nnwImageIcon')?.naturalWidth ?? null");
            // Thumbnails: chosen by the finder, downloaded and decoded at display size by the core.
            var withThumbnails = await SwiftCore.FetchArticlesAsync(new ArticleSelection("feed", feed.AccountID, feed.FeedID), thumbnailMode: "small");
            report["articlesWithThumbnails"] = withThumbnails.Count(article => article.ThumbnailURL is not null);
            if (withThumbnails.FirstOrDefault(article => article.ThumbnailURL is not null) is { ThumbnailURL: { } thumbnailURL } thumbnailed)
            {
                var thumbnailReady = new TaskCompletionSource();
                SwiftCore.EventReceived += coreEvent =>
                {
                    if (coreEvent.Kind == "thumbnailsChanged" && coreEvent.Urls?.Contains(thumbnailURL) == true)
                    {
                        thumbnailReady.TrySetResult();
                    }
                };
                var firstAnswer = await SwiftCore.GetThumbnailAsync(thumbnailURL, "small", thumbnailed.FeedName, thumbnailed.Title);
                if (firstAnswer.IsPending)
                {
                    await Task.WhenAny(thumbnailReady.Task, Task.Delay(TimeSpan.FromSeconds(30)));
                }
                var thumbnail = await SwiftCore.GetThumbnailAsync(thumbnailURL, "small", thumbnailed.FeedName, thumbnailed.Title);
                report["thumbnail"] = thumbnail.IsPending ? "pending" : $"{thumbnail.Width}x{thumbnail.Height}";
            }

            // Notifications: shown for a new article, a click opens it, and reading it withdraws the notification.
            var unreadInFeed = (await SwiftCore.FetchArticlesAsync(new ArticleSelection("feed", feed.AccountID, feed.FeedID))).FirstOrDefault(article => !article.IsRead);
            if (unreadInFeed is not null)
            {
                var (available, shown, selected, removed) = await window.NotificationRoundTripForSelfTestAsync(feed, unreadInFeed);
                report["notificationsAvailable"] = available;
                report["notificationShown"] = shown;
                report["notificationClickSelected"] = selected;
                report["notificationRemovedWhenRead"] = removed;
            }

            // Get Info: the name edited and saved, as in the Mac's inspector; then put back.
            var feedKey = $"feed:{feed.AccountID}:top:{feed.FeedID}";
            report["getInfoRenamed"] = await window.RenameInGetInfoForSelfTestAsync(feedKey, "Renamed in Get Info");
            await window.RenameInGetInfoForSelfTestAsync(feedKey, feed.Name);

            // A link dropped on the sidebar: the Add Feed dialog, filled in. feed: URLs are what browsers hand to feed readers.
            var (droppedURL, droppedFolder) = await window.DropLinkForSelfTestAsync("feed:https://example.com/feed.xml", feedKey);
            report["droppedLink"] = $"{droppedURL} folder={droppedFolder?.ToString() ?? "top"}";
            report["droppedNonLinkIgnored"] = (await window.DropLinkForSelfTestAsync("just some text", feedKey)).URL is null;

            // Accounts: the services offered, and a sign-in that fails (no such server) keeps the dialog open with the error.
            var (services, accountError, stayedOpen) = await window.AddAccountWithUnreachableServerForSelfTestAsync("FreshRSS", "https://fresh.example.invalid/api/greader.php");
            report["accountServices"] = string.Join(", ", services);
            report["accountSignInError"] = accountError;
            report["accountDialogStayedOpen"] = stayedOpen;
            report["accountsAfterFailedSignIn"] = (await SwiftCore.GetSidebarAsync()).Accounts.Count;

            // Organizing: a feed moved into a folder shows under it.
            report["movedFeedParent"] = await window.MoveFeedToNewFolderForSelfTestAsync($"feed:{feed.AccountID}:top:{feed.FeedID}", "Self-Test Folder");

            // Themes: the ones next to the exe, and the setting applied to the page.
            var themes = await SwiftCore.ListThemesAsync();

            // A theme from a link, after the download: unzipped, confirmed, installed, then removed again.
            var bundledThemes = Path.Combine(AppContext.BaseDirectory, "Themes");
            if (Directory.Exists(Path.Combine(bundledThemes, "Sepia.nnwtheme")))
            {
                report["themeFromLinkLastDialog"] = await window.InstallThemeFromZipForSelfTestAsync(Path.Combine(bundledThemes, "Sepia.nnwtheme"));
                // The list shows the app's own Sepia first; deleting works only for an installed theme, so it proves the install.
                try
                {
                    await SwiftCore.DeleteThemeAsync("Sepia");
                    report["themeFromLinkInstalled"] = true;
                }
                catch (CoreException)
                {
                    report["themeFromLinkInstalled"] = false;
                }
            }
            report["themeCount"] = themes.Count;
            if (themes.Any(theme => theme.Name == "Sepia") && articles.FirstOrDefault() is { } themed)
            {
                AppSettings.Current.ThemeName = "Sepia";
                AppSettings.Current.TextSize = "large";
                await window.ShowArticleForSelfTestAsync(themed.Reference);
                report["sepiaBackground"] = await window.EvaluateInArticleAsync("getComputedStyle(document.body).backgroundColor");
                report["textSizeClass"] = await window.EvaluateInArticleAsync("document.getElementById('bodyContainer')?.className ?? null");
                AppSettings.Current.ThemeName = null;
                AppSettings.Current.TextSize = "medium";
            }

            (_, isRead) = await window.PressShortcutForSelfTestAsync("r");
            report["shortcutToggleReadMadeUnread"] = isRead == false;

            try
            {
                await SwiftCore.FetchArticlesAsync(new ArticleSelection("feed", feed.AccountID, "no-such-feed"));
                report["notFoundError"] = "none";
            }
            catch (CoreException e)
            {
                report["notFoundError"] = e.Code;
            }
        }
        catch (Exception e)
        {
            report["exception"] = e.ToString();
        }

        report["events"] = events.Distinct().ToList();
        await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, SelfTestJsonContext.Default.DictionaryStringObject));
        NotificationService.UnregisterForSelfTest();
        await App.QuitAsync();
    }

    /// <summary>
    /// `NetNewsWire.exe --selftest-activation &lt;report-path&gt;`: the first instance. The test then launches the
    /// app again with a feed: URL, which should be handed to this instance and open Add Feed.
    /// </summary>
    public static async Task RunActivationAsync(MainWindow window, string reportPath)
    {
        var report = new Dictionary<string, object?>();
        var (openedURL, addFeedURL) = await window.WaitForOpenedURLForSelfTestAsync(TimeSpan.FromSeconds(60));
        report["openedURL"] = openedURL;
        report["addFeedURL"] = addFeedURL;
        await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, SelfTestJsonContext.Default.DictionaryStringObject));
        NotificationService.UnregisterForSelfTest();
        await App.QuitAsync();
    }

    private static async Task<FeedInfo?> FindFeedAsync(string url)
    {
        var sidebar = await SwiftCore.GetSidebarAsync();
        return sidebar.Accounts
            .SelectMany(account => account.Feeds.Concat(account.Folders.SelectMany(folder => folder.Feeds)))
            .FirstOrDefault(feed => string.Equals(feed.Url, url, StringComparison.OrdinalIgnoreCase));
    }
}

[System.Text.Json.Serialization.JsonSourceGenerationOptions(WriteIndented = true)]
[System.Text.Json.Serialization.JsonSerializable(typeof(Dictionary<string, object?>))]
[System.Text.Json.Serialization.JsonSerializable(typeof(List<string>))]
[System.Text.Json.Serialization.JsonSerializable(typeof(bool))]
[System.Text.Json.Serialization.JsonSerializable(typeof(int))]
[System.Text.Json.Serialization.JsonSerializable(typeof(string))]
internal sealed partial class SelfTestJsonContext : System.Text.Json.Serialization.JsonSerializerContext;
