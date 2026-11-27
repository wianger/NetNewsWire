using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NetNewsWire.Windows.Core;
using Windows.Storage.Streams;

namespace NetNewsWire.Windows;

/// <summary>
/// Timeline thumbnails as XAML images. The core decodes them at display size and keeps a bounded
/// cache; this keeps the XAML images for the same URLs so rows scrolled back into view don't flicker.
/// </summary>
internal static class ThumbnailCache
{
    private const int MaxCount = 300;
    private static readonly Dictionary<string, ImageSource> images = [];

    /// <summary>The image now if ready; otherwise null, and the core sends thumbnailsChanged when it is.</summary>
    public static async Task<ImageSource?> ThumbnailAsync(string url, string mode, string? feedName, string? articleTitle)
    {
        var key = $"{mode} {url}";
        if (images.TryGetValue(key, out var cached))
        {
            return cached;
        }
        ThumbnailResult result;
        try
        {
            result = await SwiftCore.GetThumbnailAsync(url, mode, feedName, articleTitle);
        }
        catch (CoreException)
        {
            return null;
        }
        if (result.IsPending || result.Png is null)
        {
            return null;
        }
        var bitmap = new BitmapImage();
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(Convert.FromBase64String(result.Png).AsBuffer());
        stream.Seek(0);
        await bitmap.SetSourceAsync(stream);
        if (images.Count >= MaxCount)
        {
            images.Clear();
        }
        images[key] = bitmap;
        return bitmap;
    }

    public static void Clear() => images.Clear();
}
