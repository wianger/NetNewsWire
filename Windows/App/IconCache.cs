using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NetNewsWire.Windows.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace NetNewsWire.Windows;

/// <summary>
/// Feed icons as XAML images, one per feed however many rows show it. The core reports
/// `iconsChanged` when a downloader finds a better icon; those entries are dropped and reloaded.
/// </summary>
internal static class IconCache
{
    private static readonly Dictionary<string, Task<FeedIcon?>> feedIcons = [];

    /// <summary>Set from the window's theme: whether icons are shown on a dark background.</summary>
    public static bool IsDarkTheme { get; set; }

    /// <summary>Raised after icons are dropped, so views can ask again. Null: any feed.</summary>
    public static event Action<IReadOnlySet<string>?>? IconsChanged;

    public static Task<FeedIcon?> FeedIconAsync(string accountID, string feedID)
    {
        var key = Key(accountID, feedID);
        if (!feedIcons.TryGetValue(key, out var icon))
        {
            icon = LoadAsync(() => SwiftCore.GetFeedIconAsync(accountID, feedID));
            feedIcons[key] = icon;
        }
        return icon;
    }

    public static void Invalidate(List<string>? feedIDs)
    {
        if (feedIDs is null)
        {
            feedIcons.Clear();
            IconsChanged?.Invoke(null);
            return;
        }
        var changed = feedIDs.ToHashSet();
        foreach (var key in feedIcons.Keys.Where(key => changed.Contains(FeedID(key))).ToList())
        {
            feedIcons.Remove(key);
        }
        IconsChanged?.Invoke(changed);
    }

    /// <summary>The PNG bytes of an icon, for the article page's `nnwImageIcon:` requests.</summary>
    public static async Task<byte[]?> ArticleIconPngAsync(ArticleReference article)
    {
        try
        {
            return Convert.FromBase64String((await SwiftCore.GetArticleIconAsync(article)).Png);
        }
        catch (CoreException)
        {
            return null;
        }
    }

    private static async Task<FeedIcon?> LoadAsync(Func<Task<IconResult>> fetch)
    {
        try
        {
            var icon = await fetch();
            var bitmap = new BitmapImage();
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(Convert.FromBase64String(icon.Png).AsBuffer());
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
            return new FeedIcon(bitmap, icon.IsDark, icon.IsBright, icon.IsBackgroundSuppressed);
        }
        catch (CoreException)
        {
            return null;
        }
    }

    private static string Key(string accountID, string feedID) => $"{accountID}\n{feedID}";

    private static string FeedID(string key) => key[(key.IndexOf('\n') + 1)..];
}

/// <summary>An icon and whether it needs a backplate to show, as the Mac's IconView decides.</summary>
internal sealed record FeedIcon(ImageSource Image, bool IsDark, bool IsBright, bool IsBackgroundSuppressed)
{
    /// <summary>A dark icon on a dark background, or a bright one on a light background, would disappear.</summary>
    public bool NeedsBackplate(bool isDarkTheme) => !IsBackgroundSuppressed && (isDarkTheme ? IsDark : IsBright);
}
