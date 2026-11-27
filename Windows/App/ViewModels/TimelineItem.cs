using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml.Media;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows.ViewModels;

/// <summary>A timeline row. Read and starred change in place, so marking doesn't rebuild the list.</summary>
public sealed partial class TimelineItem(ArticleSummary summary, string? thumbnailMode) : ObservableObject
{
    /// <summary>small, large, or null: how the timeline shows thumbnails.</summary>
    public string? ThumbnailMode { get; } = thumbnailMode;
    public ArticleSummary Summary { get; private set; } = summary;

    public ArticleReference Reference => Summary.Reference;

    public string ArticleID => Summary.ArticleID;

    public string Title => string.IsNullOrWhiteSpace(Summary.Title) ? Summary.Summary ?? "Untitled" : Summary.Title;

    /// <summary>The preview line. Empty when the title already is the summary.</summary>
    public string Preview => string.IsNullOrWhiteSpace(Summary.Title) ? "" : Summary.Summary ?? "";

    public string FeedName => Summary.FeedName;

    /// <summary>Today: the time. Otherwise: the date. As ArticleStringFormatter.dateString does on the Mac.</summary>
    public string DateText
    {
        get
        {
            var local = Summary.Date.ToLocalTime();
            return local.Date == DateTime.Today ? local.ToString("t") : local.ToString("d");
        }
    }

    public string AccessibleName => $"{(IsRead ? "" : "Unread, ")}{(IsStarred ? "Starred, " : "")}{Title}, {FeedName}, {DateText}";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AccessibleName))]
    [NotifyPropertyChangedFor(nameof(IsUnread))]
    public partial bool IsRead { get; set; } = summary.IsRead;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AccessibleName))]
    public partial bool IsStarred { get; set; } = summary.IsStarred;

    public bool IsUnread => !IsRead;

    /// <summary>The feed's icon, once loaded.</summary>
    [ObservableProperty]
    public partial ImageSource? Icon { get; set; }

    /// <summary>Shown behind the icon when it would disappear into the background.</summary>
    [ObservableProperty]
    public partial bool ShowsIconBackplate { get; set; }

    private FeedIcon? feedIcon;

    public async Task LoadIconAsync()
    {
        feedIcon = await IconCache.FeedIconAsync(Summary.AccountID, Summary.FeedID);
        Icon = feedIcon?.Image;
        UpdateIconBackplate();
    }

    public void UpdateIconBackplate() => ShowsIconBackplate = feedIcon?.NeedsBackplate(IconCache.IsDarkTheme) ?? false;

    /// <summary>The article's thumbnail, once downloaded and decoded.</summary>
    [ObservableProperty]
    public partial ImageSource? Thumbnail { get; set; }

    public string? ThumbnailURL => ThumbnailMode is null ? null : Summary.ThumbnailURL;

    /// <summary>Room is kept for a thumbnail the article has, while it loads — so rows don't jump.</summary>
    public bool ShowsSmallThumbnail => ThumbnailMode == "small" && ThumbnailURL is not null;

    public bool ShowsLargeThumbnail => ThumbnailMode == "large" && ThumbnailURL is not null;

    public async Task LoadThumbnailAsync()
    {
        if (ThumbnailURL is { } url && ThumbnailMode is { } mode)
        {
            Thumbnail = await ThumbnailCache.ThumbnailAsync(url, mode, Summary.FeedName, Summary.Title);
        }
    }

    public void Update(ArticleSummary summary)
    {
        var thumbnailChanged = summary.ThumbnailURL != Summary.ThumbnailURL;
        Summary = summary;
        if (thumbnailChanged)
        {
            // The finder picked another image, as when the first one failed.
            Thumbnail = null;
            OnPropertyChanged(nameof(ShowsSmallThumbnail));
            OnPropertyChanged(nameof(ShowsLargeThumbnail));
            _ = LoadThumbnailAsync();
        }
        IsRead = summary.IsRead;
        IsStarred = summary.IsStarred;
    }
}
