using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

/// <summary>
/// New-article notifications, as the Mac's UserNotificationManager shows them: the feed's name, the
/// article's title and summary, and Mark as Read and Star buttons. Tagged by article, so one is removed
/// when its article is read. No group: a notification is identified by its tag and group together, and
/// a read article's feed isn't known when it's removed (Windows already groups them under the app).
/// The core decides which articles get one.
/// </summary>
internal static class NotificationService
{
    public const string ActionKey = "action";
    public const string OpenAction = "open";
    public const string MarkReadAction = "markRead";
    public const string StarAction = "star";

    private static bool isRegistered;

    /// <summary>Clicks on notifications and their buttons, while the app is running.</summary>
    public static event Action<IDictionary<string, string>>? Invoked;

    /// <summary>
    /// Registers for notification clicks. Call early in launch: a click when the app isn't running starts
    /// it with an AppNotification activation, which Program redirects like any other.
    /// </summary>
    public static void Register()
    {
        if (isRegistered)
        {
            return;
        }
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) => Invoked?.Invoke(args.Arguments);
            AppNotificationManager.Default.Register();
            isRegistered = true;
        }
        catch (Exception e)
        {
            // Without registration there are no notifications, but the app works.
            System.Diagnostics.Debug.WriteLine($"Notifications unavailable: {e.Message}");
        }
    }

    public static bool IsAvailable => isRegistered && AppNotificationManager.IsSupported();

    public static void Show(List<NewArticleNotice> notices)
    {
        if (!IsAvailable)
        {
            return;
        }
        foreach (var notice in notices)
        {
            var builder = new AppNotificationBuilder()
                .AddArgument(ActionKey, OpenAction)
                .AddArgument("accountID", notice.AccountID)
                .AddArgument("feedID", notice.FeedID)
                .AddArgument("articleID", notice.ArticleID)
                .AddText(notice.FeedName)
                .SetTag(Tag(notice.ArticleID));
            if (!string.IsNullOrWhiteSpace(notice.Title))
            {
                builder.AddText(notice.Title);
            }
            if (!string.IsNullOrWhiteSpace(notice.Summary))
            {
                builder.AddText(notice.Summary);
            }
            builder.AddButton(Button(Loc.Get("MarkAsRead"), MarkReadAction, notice));
            builder.AddButton(Button(Loc.Get("Star"), StarAction, notice));
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
    }

    /// <summary>Removes the notifications for articles that were marked read.</summary>
    public static async Task RemoveAsync(IEnumerable<string> articleIDs)
    {
        if (!IsAvailable)
        {
            return;
        }
        foreach (var articleID in articleIDs)
        {
            await AppNotificationManager.Default.RemoveByTagAsync(Tag(articleID));
        }
    }

    /// <summary>
    /// For the self-tests: removes this exe's notification registration, which an unpackaged app keeps in
    /// the user's profile by the exe's path, so a test build leaves none behind. The app registers again
    /// when it next starts.
    /// </summary>
    public static void UnregisterForSelfTest()
    {
        if (!isRegistered)
        {
            return;
        }
        try
        {
            AppNotificationManager.Default.RemoveAllAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
            AppNotificationManager.Default.UnregisterAll();
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"Unregistering notifications: {e.Message}");
        }
        isRegistered = false;
    }

    /// <summary>The tags of the notifications showing, for the self-test.</summary>
    public static async Task<List<string>> ShowingTagsAsync() =>
        IsAvailable ? [.. (await AppNotificationManager.Default.GetAllAsync()).Select(notification => notification.Tag)] : [];

    // Tags are limited to 64 characters; article IDs can be long URLs, so they're hashed.
    private static string Tag(string articleID) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(articleID)), 0, 16);

    private static AppNotificationButton Button(string title, string action, NewArticleNotice notice) =>
        new AppNotificationButton(title)
            .AddArgument(ActionKey, action)
            .AddArgument("accountID", notice.AccountID)
            .AddArgument("feedID", notice.FeedID)
            .AddArgument("articleID", notice.ArticleID);
}
