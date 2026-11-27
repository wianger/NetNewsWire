using System.Text.Json;
using Microsoft.UI.Xaml;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

/// <summary>
/// End-to-end check of a sync account against a real server:
/// `NetNewsWire.exe --selftest-sync &lt;report-path&gt;`, with the server in NNW_SYNC_TYPE, NNW_SYNC_URL,
/// NNW_SYNC_USERNAME, and NNW_SYNC_PASSWORD (not on the command line, which other processes can read).
/// Adds the account, waits for the first sync, marks the newest article of NNW_SYNC_FEED read and
/// starred, syncs again so the change reaches the server, then deletes the account and its credentials.
/// </summary>
internal static class SyncSelfTest
{
    public static async Task RunAsync(string reportPath)
    {
        var report = new Dictionary<string, object?>();
        string? accountID = null;
        var refreshComplete = new SemaphoreSlim(0);
        SwiftCore.EventReceived += coreEvent =>
        {
            if (coreEvent.Kind == "refreshProgress" && coreEvent.Progress?.IsComplete == true)
            {
                refreshComplete.Release();
            }
        };

        try
        {
            var type = Environment.GetEnvironmentVariable("NNW_SYNC_TYPE") ?? "freshRSS";
            var added = await SwiftCore.AddAccountAsync(type,
                Environment.GetEnvironmentVariable("NNW_SYNC_USERNAME"),
                Environment.GetEnvironmentVariable("NNW_SYNC_PASSWORD"),
                Environment.GetEnvironmentVariable("NNW_SYNC_TOKEN"),
                Environment.GetEnvironmentVariable("NNW_SYNC_URL"));
            accountID = added.AccountID;
            report["added"] = added.Name;

            // The first sync: subscriptions, then articles and their statuses.
            var account = await WaitForAccountAsync(accountID, refreshComplete, account => account.Feeds.Count + account.Folders.Sum(folder => folder.Feeds.Count) > 0);
            report["feeds"] = account is null ? null : Describe(account);

            var feedName = Environment.GetEnvironmentVariable("NNW_SYNC_FEED") ?? "NetNewsWire";
            if (account?.Feeds.Concat(account.Folders.SelectMany(folder => folder.Feeds)).FirstOrDefault(feed => feed.Name == feedName) is { } feed)
            {
                var articles = await SwiftCore.FetchArticlesAsync(new ArticleSelection("feed", feed.AccountID, feed.FeedID));
                report["feedArticleCount"] = articles.Count;
                if (articles.FirstOrDefault(article => !article.IsRead) is { } article)
                {
                    await SwiftCore.MarkArticlesAsync([article.Reference], read: true);
                    await SwiftCore.StarArticlesAsync([article.Reference], starred: true);
                    report["markedReadAndStarred"] = article.Title;

                    // Statuses are sent with the next sync, as on the Mac.
                    while (refreshComplete.CurrentCount > 0)
                    {
                        await refreshComplete.WaitAsync();
                    }
                    var refresh = await SwiftCore.RefreshAllAsync();
                    report["secondSyncErrors"] = refresh.Errors;
                    await refreshComplete.WaitAsync(TimeSpan.FromSeconds(90));
                    var after = (await SwiftCore.GetSidebarAsync()).Accounts.FirstOrDefault(a => a.AccountID == accountID);
                    report["feedsAfterMarking"] = after is null ? null : Describe(after);
                }
            }
        }
        catch (Exception e)
        {
            report["exception"] = e.ToString();
        }

        if (accountID is not null && Environment.GetEnvironmentVariable("NNW_SYNC_KEEP") is null)
        {
            try
            {
                await SwiftCore.DeleteAccountAsync(accountID);
                report["deleted"] = true;
            }
            catch (CoreException e)
            {
                report["deleteError"] = e.Message;
            }
        }

        await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, SelfTestJsonContext.Default.DictionaryStringObject));
        await App.QuitAsync();
    }

    /// <summary>The account once the condition holds after a completed refresh, or as it is after 120 seconds.</summary>
    private static async Task<AccountInfo?> WaitForAccountAsync(string accountID, SemaphoreSlim refreshComplete, Func<AccountInfo, bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(120);
        AccountInfo? account = null;
        while (DateTime.UtcNow < deadline)
        {
            await refreshComplete.WaitAsync(TimeSpan.FromSeconds(5));
            account = (await SwiftCore.GetSidebarAsync()).Accounts.FirstOrDefault(a => a.AccountID == accountID);
            if (account is not null && condition(account))
            {
                await Task.Delay(TimeSpan.FromSeconds(3)); // Let the article fetch that follows the subscriptions finish.
                return (await SwiftCore.GetSidebarAsync()).Accounts.FirstOrDefault(a => a.AccountID == accountID);
            }
        }
        return account;
    }

    /// <summary>Each feed with its unread count, prefixed by its folder's name if it's in one.</summary>
    private static List<string> Describe(AccountInfo account) =>
        account.Feeds.Select(feed => $"{feed.Name}: {feed.UnreadCount} unread")
            .Concat(account.Folders.SelectMany(folder => folder.Feeds.Select(feed => $"{folder.Name}/{feed.Name}: {feed.UnreadCount} unread")))
            .OrderBy(text => text, StringComparer.Ordinal)
            .ToList();
}
