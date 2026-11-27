using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml.Media;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows.ViewModels;

public enum SidebarNodeKind
{
    SmartFeed,
    Account,
    Folder,
    Feed
}

/// <summary>
/// One sidebar row. Nodes are kept and updated in place when the core reports changes,
/// so selection and expansion survive refreshes.
/// </summary>
public sealed partial class SidebarNode(string key, SidebarNodeKind kind) : ObservableObject
{
    /// <summary>Identifies the node across reloads: kind plus the core's IDs.</summary>
    public string Key { get; } = key;

    public SidebarNodeKind Kind { get; } = kind;

    public ObservableCollection<SidebarNode> Children { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AccessibleName))]
    public partial string Name { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UnreadText))]
    [NotifyPropertyChangedFor(nameof(AccessibleName))]
    public partial int UnreadCount { get; set; }

    /// <summary>What Narrator reads: the name and, as VoiceOver on the Mac, the unread count.</summary>
    public string AccessibleName => UnreadCount > 0 ? $"{Name}, {UnreadCount:N0} unread" : Name;

    [ObservableProperty]
    public partial bool IsExpanded { get; set; } = true;

    /// <summary>What the timeline shows for this node. Null for an account header.</summary>
    [ObservableProperty]
    public partial ArticleSelection? Selection { get; set; }

    /// <summary>The feed or folder this node stands for, for commands such as Rename and Delete.</summary>
    public FeedInfo? Feed { get; set; }

    public FolderInfo? Folder { get; set; }

    public string? AccountID { get; set; }

    public string UnreadText => UnreadCount > 0 ? UnreadCount.ToString("N0") : "";

    /// <summary>A feed's icon, once loaded. Until then, and for other rows, the glyph shows.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasIcon))]
    [NotifyPropertyChangedFor(nameof(ShowsGlyph))]
    public partial ImageSource? Icon { get; set; }

    public bool HasIcon => Icon is not null;

    public bool ShowsGlyph => Icon is null;

    /// <summary>Shown behind the icon when it would disappear into the background.</summary>
    [ObservableProperty]
    public partial bool ShowsIconBackplate { get; set; }

    private FeedIcon? feedIcon;

    public async Task LoadIconAsync()
    {
        if (Kind == SidebarNodeKind.Feed && Feed is { } feed)
        {
            feedIcon = await IconCache.FeedIconAsync(feed.AccountID, feed.FeedID);
            Icon = feedIcon?.Image;
            UpdateIconBackplate();
        }
    }

    public void UpdateIconBackplate() => ShowsIconBackplate = feedIcon?.NeedsBackplate(IconCache.IsDarkTheme) ?? false;

    /// <summary>A Segoe Fluent Icons glyph.</summary>
    public string Glyph => Kind switch
    {
        SidebarNodeKind.SmartFeed => Key switch
        {
            "smart:today" => "",   // Calendar
            "smart:starred" => "", // FavoriteStar
            _ => ""                // Inbox-like: AllApps
        },
        SidebarNodeKind.Account => "", // Home
        SidebarNodeKind.Folder => "",  // Folder
        _ => ""                        // Wifi-like feed glyph
    };
}
