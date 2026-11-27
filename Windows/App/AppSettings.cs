using System.Text.Json;
using System.Text.Json.Serialization;
using NetNewsWire.Windows.Core;

namespace NetNewsWire.Windows;

/// <summary>
/// The Windows app's settings, in %LOCALAPPDATA%\NetNewsWire\Settings.json next to the core's data.
/// The core is told them per request (for example the theme with each render), so it keeps no UI state.
/// </summary>
internal sealed class AppSettings
{
    /// <summary>The Mac app's article text sizes, smallest first.</summary>
    public static readonly string[] TextSizes = ["small", "medium", "large", "xlarge", "xxlarge"];

    public static readonly string[] TextSizeNames = ["Small", "Medium", "Large", "Extra Large", "Extra Extra Large"];

    /// <summary>Lazy, so the static arrays below are set before Load validates against them.</summary>
    public static AppSettings Current => current.Value;

    private static readonly Lazy<AppSettings> current = new(Load);

    /// <summary>Raised after a change is saved.</summary>
    public static event Action? Changed;

    /// <summary>Null: the default theme.</summary>
    public string? ThemeName { get; set; }

    public string TextSize { get; set; } = "medium";

    /// <summary>none, small (beside the text), or large (below it). As on the Mac, none by default.</summary>
    public string TimelineThumbnails { get; set; } = "none";

    public static readonly string[] TimelineThumbnailModes = ["none", "small", "large"];

    public static readonly string[] TimelineThumbnailModeNames = ["None", "Small", "Large"];

    /// <summary>The Mac's refresh intervals (Shared/Timer/RefreshInterval.swift), in seconds; 0 is Manually.</summary>
    public static readonly string[] RefreshIntervals = ["manually", "every30Minutes", "everyHour", "every2Hours", "every4Hours", "every8Hours"];

    public static readonly string[] RefreshIntervalNames = ["Manually", "Every 30 Minutes", "Every Hour", "Every 2 Hours", "Every 4 Hours", "Every 8 Hours"];

    private static readonly int[] RefreshIntervalSeconds = [0, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 8 * 60 * 60];

    /// <summary>As on the Mac, every two hours by default.</summary>
    public string RefreshInterval { get; set; } = "every2Hours";

    public int RefreshIntervalInSeconds => RefreshIntervalSeconds[Math.Max(0, Array.IndexOf(RefreshIntervals, RefreshInterval))];

    /// <summary>The Mac timeline's sort fields. Saved per window on the Mac; for the app here.</summary>
    public static readonly string[] SortKeys = ["date", "feed", "title", "unread", "starred"];

    public static readonly string[] SortKeyNames = ["Date", "Feed", "Title", "Unread", "Starred"];

    public string TimelineSortKey { get; set; } = "date";

    public bool TimelineSortAscending { get; set; }

    public bool TimelineGroupByFeed { get; set; }

    public TimelineSort Sort => new(TimelineSortKey, TimelineSortAscending, TimelineGroupByFeed && TimelineSortKey == "date");

    /// <summary>The direction used the first time a field is chosen, as on the Mac: newest, unread, and starred on top; text A to Z.</summary>
    public static bool SortsAscendingFirst(string key) => key is "feed" or "title";

    /// <summary>The Mac's menu titles for a direction: dates by age, text alphabetically, flags ascending or descending.</summary>
    public static string SortDirectionTitle(string key, bool ascending) => key switch
    {
        "date" => ascending ? "Oldest Article on Top" : "Newest Article on Top",
        "feed" or "title" => ascending ? "A to Z" : "Z to A",
        _ => ascending ? "Ascending" : "Descending",
    };

    /// <summary>Null when the timeline shows no thumbnails.</summary>
    public string? ThumbnailMode => TimelineThumbnails is "small" or "large" ? TimelineThumbnails : null;

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, AppSettingsJsonContext.Default.AppSettings));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"Couldn't save settings: {e.Message}");
        }
        Changed?.Invoke();
    }

    private static string FilePath
    {
        get
        {
            // The environment variable first, as the core reads it, so a test's data folder holds both.
            var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(localAppData, "NetNewsWire", "Settings.json");
        }
    }

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize(File.ReadAllText(FilePath), AppSettingsJsonContext.Default.AppSettings) is { } settings)
            {
                if (!TextSizes.Contains(settings.TextSize))
                {
                    settings.TextSize = "medium";
                }
                if (!TimelineThumbnailModes.Contains(settings.TimelineThumbnails))
                {
                    settings.TimelineThumbnails = "none";
                }
                if (!RefreshIntervals.Contains(settings.RefreshInterval))
                {
                    settings.RefreshInterval = "every2Hours";
                }
                if (!SortKeys.Contains(settings.TimelineSortKey))
                {
                    settings.TimelineSortKey = "date";
                    settings.TimelineSortAscending = false;
                }
                return settings;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"Couldn't read settings: {e.Message}");
        }
        return new AppSettings();
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(AppSettings))]
internal sealed partial class AppSettingsJsonContext : JsonSerializerContext;
