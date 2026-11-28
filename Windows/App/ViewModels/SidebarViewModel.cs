using System.Collections.ObjectModel;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows.ViewModels;

/// <summary>The sidebar tree: smart feeds, then each active account with its folders and feeds.</summary>
public sealed class SidebarViewModel
{
    public ObservableCollection<SidebarNode> Nodes { get; } = [];

    /// <summary>Every node, depth first, in the order the sidebar shows them.</summary>
    public IEnumerable<SidebarNode> AllNodes => Flatten(Nodes);

    public int TotalUnreadCount { get; private set; }

    public async Task ReloadAsync()
    {
        var snapshot = await SwiftCore.GetSidebarAsync();
        TotalUnreadCount = snapshot.TotalUnreadCount;

        var desired = new List<NodeSpec>();
        foreach (var smartFeed in snapshot.SmartFeeds)
        {
            desired.Add(new NodeSpec($"smart:{smartFeed.Kind}", SidebarNodeKind.SmartFeed, SmartFeedName(smartFeed), smartFeed.UnreadCount, new ArticleSelection(smartFeed.Kind)));
        }
        foreach (var account in snapshot.Accounts.Where(account => account.IsActive))
        {
            var children = new List<NodeSpec>();
            foreach (var folder in account.Folders)
            {
                var feeds = folder.Feeds.Select(feed => FeedSpec(feed, folder.FolderID)).ToList();
                children.Add(new NodeSpec($"folder:{account.AccountID}:{folder.FolderID}", SidebarNodeKind.Folder, folder.Name, folder.UnreadCount,
                    new ArticleSelection("folder", account.AccountID, FolderID: folder.FolderID), feeds) { Folder = folder, AccountID = account.AccountID });
            }
            children.AddRange(account.Feeds.Select(feed => FeedSpec(feed, null)));
            desired.Add(new NodeSpec($"account:{account.AccountID}", SidebarNodeKind.Account, AccountName(account), account.UnreadCount, null, children) { AccountID = account.AccountID });
        }

        Sync(Nodes, desired);

        foreach (var node in AllNodes.Where(node => node.Kind == SidebarNodeKind.Feed && node.Icon is null))
        {
            _ = node.LoadIconAsync();
        }
    }

    /// <summary>Reloads the icons the core says changed.</summary>
    public void ReloadIcons(IReadOnlySet<string>? feedIDs)
    {
        foreach (var node in AllNodes.Where(node => node.Feed is { } feed && (feedIDs is null || feedIDs.Contains(feed.FeedID))))
        {
            _ = node.LoadIconAsync();
        }
    }

    public SidebarNode? Find(string key) => AllNodes.FirstOrDefault(node => node.Key == key);

    private static NodeSpec FeedSpec(FeedInfo feed, int? folderID) =>
        new($"feed:{feed.AccountID}:{folderID?.ToString() ?? "top"}:{feed.FeedID}", SidebarNodeKind.Feed, feed.Name, feed.UnreadCount,
            new ArticleSelection("feed", feed.AccountID, feed.FeedID)) { Feed = feed, Folder = null, AccountID = feed.AccountID, FolderID = folderID };

    /// <summary>Makes `nodes` match `desired`, reusing nodes with the same key.</summary>
    private static void Sync(ObservableCollection<SidebarNode> nodes, List<NodeSpec> desired)
    {
        var existing = nodes.ToDictionary(node => node.Key);
        for (var index = 0; index < desired.Count; index++)
        {
            var spec = desired[index];
            if (!existing.Remove(spec.Key, out var node))
            {
                node = new SidebarNode(spec.Key, spec.Kind);
                nodes.Insert(index, node);
            }
            else
            {
                var currentIndex = nodes.IndexOf(node);
                if (currentIndex != index)
                {
                    nodes.Move(currentIndex, index);
                }
            }
            node.Name = spec.Name;
            node.UnreadCount = spec.UnreadCount;
            node.Selection = spec.Selection;
            node.Feed = spec.Feed;
            node.Folder = spec.Folder ?? (spec.FolderID is { } folderID ? new FolderInfo(folderID, "", 0, []) : null);
            node.AccountID = spec.AccountID;
            Sync(node.Children, spec.Children ?? []);
        }
        foreach (var removed in existing.Values)
        {
            nodes.Remove(removed);
        }
    }

    private static IEnumerable<SidebarNode> Flatten(IEnumerable<SidebarNode> nodes)
    {
        foreach (var node in nodes)
        {
            yield return node;
            foreach (var child in Flatten(node.Children))
            {
                yield return child;
            }
        }
    }

    private sealed record NodeSpec(string Key, SidebarNodeKind Kind, string Name, int UnreadCount, ArticleSelection? Selection, List<NodeSpec>? Children = null)
    {
        public FeedInfo? Feed { get; init; }
        public FolderInfo? Folder { get; init; }
        public string? AccountID { get; init; }
        /// <summary>For a feed: the folder it is in, so Delete removes it from the right place.</summary>
        public int? FolderID { get; init; }
    }

    /// <summary>The smart feeds' names in the user's language. The core names them in English.</summary>
    private static string SmartFeedName(SmartFeedInfo smartFeed) => smartFeed.Kind switch
    {
        "today" => Loc.Get("Today"),
        "unread" => Loc.Get("AllUnread"),
        "starred" => Loc.Get("Starred"),
        _ => smartFeed.Name,
    };

    /// <summary>The local account's name in the user's language; sync accounts keep their own names.</summary>
    internal static string AccountName(AccountInfo account) => account.Type == "onMyMac" ? Loc.Get("OnThisPC") : account.Name;
}
