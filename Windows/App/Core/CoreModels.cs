using System.Text.Json;
using System.Text.Json.Serialization;

namespace NetNewsWire.Windows.Core;

// Mirrors Windows/Core/Sources/CoreService/Models.swift. Field names are the JSON names
// (camelCase); dates are ISO 8601.

public sealed record SidebarSnapshot(List<SmartFeedInfo> SmartFeeds, List<AccountInfo> Accounts, int TotalUnreadCount);

public sealed record SmartFeedInfo(string Kind, string Name, int UnreadCount);

public sealed record AccountInfo(string AccountID, string Name, string Type, bool IsActive, int UnreadCount, List<FolderInfo> Folders, List<FeedInfo> Feeds);

public sealed record FolderInfo(int FolderID, string Name, int UnreadCount, List<FeedInfo> Feeds);

public sealed record FeedInfo(string AccountID, string FeedID, string Name, string Url, string? HomePageURL, int UnreadCount);

public sealed record ArticleSummary(
    string AccountID, string ArticleID, string FeedID, string FeedName,
    string? Title, string? Summary, string? Link, string? ThumbnailURL,
    DateTimeOffset Date, bool IsRead, bool IsStarred)
{
    public ArticleReference Reference => new(AccountID, ArticleID);
}

public sealed record ArticleDetail(
    string AccountID, string ArticleID, string FeedID, string FeedName, string? FeedHomePageURL,
    string? Title, string? Html, string? Link, string? ExternalLink, string? ImageURL,
    List<AuthorInfo> Authors, DateTimeOffset? DatePublished, DateTimeOffset? DateModified,
    bool IsRead, bool IsStarred);

public sealed record AuthorInfo(string? Name, string? Url, string? AvatarURL, string? EmailAddress);

/// <summary>Which articles the timeline shows. Kind: today, unread, starred, feed, folder, search.</summary>
public sealed record ArticleSelection(
    string Kind, string? AccountID = null, string? FeedID = null, int? FolderID = null,
    string? Query = null, bool? UnreadOnly = null);

public sealed record ArticleReference(string AccountID, string ArticleID);

/// <summary>Kind: sidebarChanged, unreadCountsChanged, statusesChanged, articlesChanged, refreshProgress.</summary>
public sealed record CoreEvent(string Kind, List<string>? ArticleIDs, List<string>? FeedIDs, List<string>? Urls, RefreshProgress? Progress);

/// <summary>A timeline thumbnail as PNG, or pending: a thumbnailsChanged event with its URL follows.</summary>
public sealed record ThumbnailResult(string? Png, int Width, int Height, bool IsPending);

/// <summary>An icon as PNG. IsDark/IsBright say whether it needs a backplate on a dark or light background.</summary>
public sealed record IconResult(string Png, int Width, int Height, bool IsDark, bool IsBright, bool IsBackgroundSuppressed);

public sealed record RefreshProgress(int NumberOfTasks, int NumberCompleted, int NumberRemaining, bool IsComplete);

public sealed record RefreshResult(bool DidRefresh, List<string> Errors);

public sealed record CoreInfo(string Version, string DataFolder);

/// <summary>A full article page from the shared renderer, ready for WebView2.</summary>
public sealed record RenderedPage(string Html, string Title, string BaseURL);

internal sealed record ArticleScripts(List<string> Scripts);

/// <summary>An article theme. App themes ship with the app; installed ones can be deleted.</summary>
public sealed record ThemeInfo(string Name, string CreatorName, string CreatorHomePage, string Version, bool IsAppTheme, bool IsDefault);

internal sealed record ExportOpmlResult(string Opml);

/// <summary>A sync service that can be added. FreshRSS and Miniflux need the server's URL; Miniflux also takes an API token.</summary>
public sealed record AccountTypeInfo(string Type, string Name, bool NeedsAPIURL, string? ApiURLPlaceholder, bool AcceptsAPIToken, string SignUpURL);

public sealed record AddedAccount(string AccountID, string Name);

/// <summary>What a URL the app was opened with means. Kind: addFeed, installTheme, or ignore.</summary>
public sealed record OpenedURLAction(string Kind, string? Url);

internal sealed record EmptyResult;

/// <summary>
/// How the timeline is sorted, as on the Mac: a field (date, feed, title, unread, starred) and a direction.
/// Every field but date sorts by date, newest first, within it. Group by Feed only applies to a date sort.
/// </summary>
public sealed record TimelineSort(string Key, bool Ascending, bool GroupByFeed)
{
    public static readonly TimelineSort NewestFirst = new("date", false, false);
}

internal sealed record CoreErrorBody(string Code, string Message);

// Request params.
internal sealed record FetchArticlesParams(ArticleSelection Selection, int? Limit, string? ThumbnailMode, SortParams? Sort, bool? GroupByFeed);
internal sealed record SortParams(string Key, bool Ascending);
internal sealed record SortArticlesParams(List<ArticleReference> Articles, SortParams? Sort, bool? GroupByFeed);
internal sealed record ThumbnailParams(string Url, string Mode, string? FeedName, string? ArticleTitle);
internal sealed record MarkArticlesParams(List<ArticleReference> Articles, string Key, bool Flag);
internal sealed record SubscribeParams(string Url, string? Name, string? AccountID, int? FolderID);
internal sealed record FeedLocationParams(string AccountID, string FeedID, int? FolderID);
internal sealed record RenameFeedParams(string AccountID, string FeedID, string Name);
internal sealed record MoveFeedParams(string AccountID, string FeedID, int? FromFolderID, int? ToFolderID);
internal sealed record AddFolderParams(string? AccountID, string Name);
internal sealed record RenameFolderParams(string AccountID, int FolderID, string Name);
internal sealed record FolderLocationParams(string AccountID, int FolderID);
internal sealed record ImportOpmlParams(string Path, string? AccountID);
internal sealed record AccountParams(string? AccountID);
internal sealed record RenderArticleParams(string AccountID, string ArticleID, string? TextSize, string? ThemeName, int? WindowScrollY);
internal sealed record RenderMessageParams(string Message, string? ThemeName);
internal sealed record InstallThemeParams(string Path);
internal sealed record ThemeNameParams(string Name);
internal sealed record AddAccountParams(string Type, string? Username, string? Password, string? ApiToken, string? ApiURL);
internal sealed record AccountIDParams(string AccountID);
internal sealed record OpenedURLParams(string Url);
internal sealed record SetAccountActiveParams(string AccountID, bool IsActive);
internal sealed record FeedIconParams(string AccountID, string FeedID);

/// <summary>A request the core rejected or that failed. Code: unknownMethod, invalidParams, notFound, notStarted, failed.</summary>
public sealed class CoreException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>Source-generated serialization: no reflection, so it survives trimming and Native AOT.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(SidebarSnapshot))]
[JsonSerializable(typeof(List<ArticleSummary>))]
[JsonSerializable(typeof(ArticleDetail))]
[JsonSerializable(typeof(FeedInfo))]
[JsonSerializable(typeof(FolderInfo))]
[JsonSerializable(typeof(CoreEvent))]
[JsonSerializable(typeof(RefreshResult))]
[JsonSerializable(typeof(CoreInfo))]
[JsonSerializable(typeof(ExportOpmlResult))]
[JsonSerializable(typeof(EmptyResult))]
[JsonSerializable(typeof(CoreErrorBody))]
[JsonSerializable(typeof(FetchArticlesParams))]
[JsonSerializable(typeof(List<AccountTypeInfo>))]
[JsonSerializable(typeof(AddedAccount))]
[JsonSerializable(typeof(OpenedURLAction))]
[JsonSerializable(typeof(OpenedURLParams))]
[JsonSerializable(typeof(AddAccountParams))]
[JsonSerializable(typeof(AccountIDParams))]
[JsonSerializable(typeof(SetAccountActiveParams))]
[JsonSerializable(typeof(ArticleReference))]
[JsonSerializable(typeof(List<ArticleReference>))]
[JsonSerializable(typeof(SortArticlesParams))]
[JsonSerializable(typeof(MarkArticlesParams))]
[JsonSerializable(typeof(SubscribeParams))]
[JsonSerializable(typeof(FeedLocationParams))]
[JsonSerializable(typeof(RenameFeedParams))]
[JsonSerializable(typeof(MoveFeedParams))]
[JsonSerializable(typeof(AddFolderParams))]
[JsonSerializable(typeof(RenameFolderParams))]
[JsonSerializable(typeof(FolderLocationParams))]
[JsonSerializable(typeof(ImportOpmlParams))]
[JsonSerializable(typeof(AccountParams))]
[JsonSerializable(typeof(RenderedPage))]
[JsonSerializable(typeof(ArticleScripts))]
[JsonSerializable(typeof(RenderArticleParams))]
[JsonSerializable(typeof(RenderMessageParams))]
[JsonSerializable(typeof(FeedIconParams))]
[JsonSerializable(typeof(ThumbnailParams))]
[JsonSerializable(typeof(ThumbnailResult))]
[JsonSerializable(typeof(List<ThemeInfo>))]
[JsonSerializable(typeof(ThemeInfo))]
[JsonSerializable(typeof(InstallThemeParams))]
[JsonSerializable(typeof(ThemeNameParams))]
[JsonSerializable(typeof(IconResult))]
internal sealed partial class CoreJsonContext : JsonSerializerContext;
