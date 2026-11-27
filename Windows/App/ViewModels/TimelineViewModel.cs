using System.Collections.ObjectModel;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows.ViewModels;

/// <summary>
/// The articles for the selected sidebar item. As on the Mac, an article that stops matching
/// the selection — read, in All Unread — stays until the selection changes.
/// </summary>
public sealed class TimelineViewModel
{
    private const int FetchLimit = 2000;
    private int generation;

    public ObservableCollection<TimelineItem> Items { get; } = [];

    public ArticleSelection? Selection { get; private set; }

    /// <summary>The thumbnail mode the items were fetched with.</summary>
    public string? ThumbnailMode { get; private set; }

    /// <summary>The sort the items were fetched with.</summary>
    public TimelineSort Sort { get; private set; } = TimelineSort.NewestFirst;

    /// <summary>Shows a new selection.</summary>
    public async Task LoadAsync(ArticleSelection? selection)
    {
        Selection = selection;
        var current = ++generation;
        if (selection is null)
        {
            Items.Clear();
            return;
        }
        ThumbnailMode = AppSettings.Current.ThumbnailMode;
        Sort = AppSettings.Current.Sort;
        var articles = await SwiftCore.FetchArticlesAsync(selection, FetchLimit, ThumbnailMode, Sort);
        if (current != generation)
        {
            return; // A newer selection is loading.
        }
        Items.Clear();
        foreach (var article in articles)
        {
            var item = new TimelineItem(article, ThumbnailMode);
            Items.Add(item);
            _ = item.LoadIconAsync(); // One request per feed: IconCache shares them.
        }
    }

    /// <summary>Shows thumbnails that just became ready.</summary>
    public void ShowReadyThumbnails(IReadOnlyCollection<string> urls)
    {
        var ready = urls.ToHashSet();
        foreach (var item in Items.Where(item => item.ThumbnailURL is { } url && ready.Contains(url)))
        {
            _ = item.LoadThumbnailAsync();
        }
    }

    public void ReloadIcons(IReadOnlySet<string>? feedIDs)
    {
        foreach (var item in Items.Where(item => feedIDs is null || feedIDs.Contains(item.Summary.FeedID)))
        {
            _ = item.LoadIconAsync();
        }
    }

    /// <summary>Takes in new articles and status changes for the same selection, keeping rows and order.</summary>
    public async Task RefreshAsync()
    {
        if (Selection is not { } selection)
        {
            return;
        }
        var current = generation;
        var articles = await SwiftCore.FetchArticlesAsync(selection, FetchLimit, ThumbnailMode, Sort);
        if (current != generation)
        {
            return;
        }

        var byID = Items.ToDictionary(item => item.ArticleID);
        var insertIndex = 0;
        foreach (var article in articles)
        {
            if (byID.TryGetValue(article.ArticleID, out var item))
            {
                item.Update(article);
                insertIndex = Items.IndexOf(item) + 1;
            }
            else
            {
                // New articles arrive newest first; put each before the next known row.
                var newItem = new TimelineItem(article, ThumbnailMode);
                Items.Insert(Math.Min(insertIndex, Items.Count), newItem);
                _ = newItem.LoadIconAsync();
                insertIndex++;
            }
        }
    }

    /// <summary>
    /// Puts the rows shown in the order of the current sort setting, as the Mac re-sorts its timeline:
    /// rows that stopped matching the selection (read, in All Unread) stay. Keeps the row objects, so the
    /// caller can select them again. False if a newer load replaced the items meanwhile.
    /// </summary>
    public async Task<bool> ResortAsync()
    {
        var current = ++generation;
        Sort = AppSettings.Current.Sort;
        if (Items.Count == 0)
        {
            return true;
        }
        var order = await SwiftCore.SortArticlesAsync(Items.Select(item => item.Reference), Sort);
        if (current != generation)
        {
            return false;
        }
        var byKey = Items.ToDictionary(item => (item.Summary.AccountID, item.ArticleID));
        var ordered = order.Select(reference => byKey.GetValueOrDefault((reference.AccountID, reference.ArticleID))).OfType<TimelineItem>().ToList();
        Items.Clear();
        foreach (var item in ordered)
        {
            Items.Add(item);
        }
        return true;
    }

    public TimelineItem? NextUnread(TimelineItem? after)
    {
        var start = after is null ? 0 : Items.IndexOf(after) + 1;
        return Items.Skip(start).FirstOrDefault(item => item.IsUnread);
    }

    public TimelineItem? PreviousUnread(TimelineItem? before)
    {
        var end = before is null ? Items.Count : Items.IndexOf(before);
        return Items.Take(end).LastOrDefault(item => item.IsUnread);
    }
}
