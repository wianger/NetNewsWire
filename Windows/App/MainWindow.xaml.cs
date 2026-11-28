using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using NetNewsWire.Windows.Core;
using NetNewsWire.Windows.ViewModels;
using Windows.Storage.Pickers;
using Windows.System;

namespace NetNewsWire.Windows;

/// <summary>
/// The main window: sidebar, timeline, and article, as on the Mac.
/// Single-key shortcuts match the Mac app (Shared/Resources/GlobalKeyboardShortcuts.plist).
/// </summary>
public sealed partial class MainWindow : Window
{
    internal SidebarViewModel Sidebar { get; } = new();
    internal TimelineViewModel Timeline { get; } = new();

    private readonly ArticleViewController articleView;
    private TimelineItem? shownArticle;

    /// <summary>While rows are put in a new order and selected again: not a change of selection.</summary>
    private bool isResorting;
    private bool isSyncingSelection;

    public MainWindow()
    {
        InitializeComponent();

        // Links dropped from a browser. Registered for handled events too, since the TreeView handles drags for reordering.
        SidebarTree.AddHandler(UIElement.DragOverEvent, new DragEventHandler(SidebarTree_ExternalDragOver), true);
        SidebarTree.AddHandler(UIElement.DropEvent, new DragEventHandler(SidebarTree_ExternalDrop), true);

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppTitleBar.Loaded += (_, _) => UpdateTitleBarRegions();
        AppTitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();

        articleView = new ArticleViewController(ArticleView);
        articleView.HoveredLinkChanged += ShowHoveredLink;
        articleView.KeyPressed += key => HandleShortcut(key.Key, key.Shift, fromPage: true);

        AddAccelerator(VirtualKey.R, VirtualKeyModifiers.Control, RefreshAsync);
        AddAccelerator(VirtualKey.N, VirtualKeyModifiers.Control, () => AddFeedAsync());
        AddAccelerator(VirtualKey.I, VirtualKeyModifiers.Control, ShowSelectedFeedInfoAsync); // Cmd-I on the Mac
        AddAccelerator(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, NewFolderAsync);
        AddAccelerator(VirtualKey.K, VirtualKeyModifiers.Control, MarkAllAsReadAsync);
        AddAccelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => { SearchBox.Focus(FocusState.Keyboard); return Task.CompletedTask; });
        AddAccelerator((VirtualKey)188, VirtualKeyModifiers.Control, ShowSettingsAsync);       // Ctrl+,
        AddAccelerator((VirtualKey)187, VirtualKeyModifiers.Control, () => ChangeTextSize(+1)); // Ctrl+=, as Cmd-+ on the Mac
        AddAccelerator(VirtualKey.Add, VirtualKeyModifiers.Control, () => ChangeTextSize(+1));
        AddAccelerator((VirtualKey)189, VirtualKeyModifiers.Control, () => ChangeTextSize(-1)); // Ctrl+-
        AddAccelerator(VirtualKey.Subtract, VirtualKeyModifiers.Control, () => ChangeTextSize(-1));
        AppSettings.Changed += () =>
        {
            _ = articleView.ReloadAsync();
            if (Timeline.ThumbnailMode != AppSettings.Current.ThumbnailMode)
            {
                _ = Timeline.LoadAsync(Timeline.Selection); // Fetch again with the new thumbnail mode.
            }
            else if (Timeline.Sort != AppSettings.Current.Sort)
            {
                _ = RunAsync(ResortTimelineAsync);
            }
        };

        // Icons that would disappear into the background get a backplate, which depends on the theme.
        IconCache.IsDarkTheme = RootGrid.ActualTheme == ElementTheme.Dark;
        RootGrid.ActualThemeChanged += (_, _) =>
        {
            IconCache.IsDarkTheme = RootGrid.ActualTheme == ElementTheme.Dark;
            foreach (var node in Sidebar.AllNodes)
            {
                node.UpdateIconBackplate();
            }
            foreach (var item in Timeline.Items)
            {
                item.UpdateIconBackplate();
            }
        };
        RootGrid.PreviewKeyDown += RootGrid_PreviewKeyDown;

        // UI Automation sees the TreeView's inner list, not the TreeView, so name that list.
        SidebarTree.Loaded += (_, _) =>
        {
            if (FindDescendant<TreeViewList>(SidebarTree) is { } list)
            {
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list, "Sidebar");
            }
        };

        SwiftCore.EventReceived += OnCoreEvent;
        IconCache.IconsChanged += feedIDs =>
        {
            Sidebar.ReloadIcons(feedIDs);
            Timeline.ReloadIcons(feedIDs);
        };
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        StatusText.Text = SwiftCore.Version;
        await Sidebar.ReloadAsync();
        UpdateTitle();
        await articleView.ShowMessageAsync("No selection");
        if (Sidebar.Find("smart:unread") is { } unread && unread.Selection is { } selection)
        {
            isSyncingSelection = true;
            SidebarTree.SelectedItem = unread;
            isSyncingSelection = false;
            await ShowSelectionAsync(selection);
        }
        // Activation focuses the first tab stop, the search box in the title bar. Start in the
        // timeline instead, once it has rows to focus, so the single-key shortcuts work right away.
        // An empty timeline can't take focus; the sidebar always has the smart feeds.
        if (FocusManager.GetFocusedElement(Content.XamlRoot) is null or TextBox && SearchBox.Text.Length == 0)
        {
            if (!TimelineList.Focus(FocusState.Programmatic))
            {
                SidebarTree.Focus(FocusState.Programmatic);
            }
        }
    }

    // MARK: - Core events

    private async void OnCoreEvent(CoreEvent coreEvent)
    {
        try
        {
            switch (coreEvent.Kind)
            {
                case "sidebarChanged":
                case "unreadCountsChanged":
                    await Sidebar.ReloadAsync();
                    UpdateTitle();
                    break;
                case "articlesChanged":
                case "statusesChanged":
                    await Timeline.RefreshAsync();
                    break;
                case "iconsChanged":
                    IconCache.Invalidate(coreEvent.FeedIDs);
                    break;
                case "thumbnailsChanged":
                    if (coreEvent.Urls is { Count: > 0 } urls)
                    {
                        Timeline.ShowReadyThumbnails(urls);
                    }
                    if (coreEvent.ArticleIDs is { Count: > 0 })
                    {
                        await Timeline.RefreshAsync(); // New thumbnail URLs for those articles.
                    }
                    break;
                case "newArticles" when coreEvent.NewArticles is { Count: > 0 } notices:
                    NotificationService.Show(notices);
                    break;
                case "articlesRead" when coreEvent.ArticleIDs is { Count: > 0 } readIDs:
                    await NotificationService.RemoveAsync(readIDs);
                    break;
                case "refreshProgress" when coreEvent.Progress is { } progress:
                    StatusText.Text = progress.IsComplete ? "" : $"Refreshing — {progress.NumberCompleted} of {progress.NumberOfTasks}";
                    break;
            }
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private void UpdateTitle()
    {
        Title = Sidebar.TotalUnreadCount > 0 ? $"NetNewsWire ({Sidebar.TotalUnreadCount:N0})" : "NetNewsWire";
    }

    // MARK: - Sidebar

    private async void SidebarTree_SelectionChanged(TreeView sender, TreeViewSelectionChangedEventArgs args)
    {
        if (isSyncingSelection || SidebarTree.SelectedItem is not SidebarNode node)
        {
            return;
        }
        if (node.Selection is null)
        {
            return; // An account header: nothing to show.
        }
        SearchBox.Text = "";
        await ShowSelectionAsync(node.Selection);
    }

    private async Task ShowSelectionAsync(ArticleSelection selection)
    {
        try
        {
            await Timeline.LoadAsync(selection);
            shownArticle = null;
            await articleView.ShowMessageAsync(Timeline.Items.Count == 0 ? "No articles" : "No selection");
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private void SidebarItem_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if ((sender as FrameworkElement)?.DataContext is not SidebarNode node)
        {
            return;
        }
        var menu = new MenuFlyout();
        if (node.Kind is SidebarNodeKind.Feed)
        {
            menu.Items.Add(MenuItem("Get Info", "\uE946", () => ShowFeedInfoAsync(node)));
        }
        if (node.Kind is SidebarNodeKind.Feed or SidebarNodeKind.Folder)
        {
            menu.Items.Add(MenuItem("Rename…", "", () => RenameAsync(node)));
            menu.Items.Add(MenuItem("Delete", "", () => DeleteAsync(node)));
        }
        if (node.Kind is SidebarNodeKind.Feed && node.Feed?.HomePageURL is { } homePage)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem("Open Home Page", "", () => LaunchAsync(homePage)));
        }
        if (node.Selection is not null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem("Mark All as Read", "", async () =>
            {
                SidebarTree.SelectedItem = node;
                await ShowSelectionAsync(node.Selection);
                await MarkAllAsReadAsync();
            }));
        }
        if (menu.Items.Count == 0)
        {
            return;
        }
        if (args.TryGetPosition(sender, out var point))
        {
            menu.ShowAt(sender, point);
        }
        else
        {
            menu.ShowAt((FrameworkElement)sender);
        }
        args.Handled = true;
    }

    // MARK: - Drag and drop

    /// <summary>The feed being dragged, and the folder it was in (null: the top level).</summary>
    private (SidebarNode Node, int? FromFolderID)? draggedFeed;

    /// <summary>Only feeds move, as on the Mac; folders and smart feeds stay put.</summary>
    private void SidebarTree_DragItemsStarting(TreeView sender, TreeViewDragItemsStartingEventArgs args)
    {
        if (args.Items is [SidebarNode { Kind: SidebarNodeKind.Feed } node])
        {
            draggedFeed = (node, node.Folder?.FolderID);
            return;
        }
        args.Cancel = true;
    }

    /// <summary>
    /// The tree has already moved the node in its own collections; the core decides. A drop onto a folder
    /// or the feed's account moves the feed there; anything else is undone by reloading from the core.
    /// </summary>
    private async void SidebarTree_DragItemsCompleted(TreeView sender, TreeViewDragItemsCompletedEventArgs args)
    {
        if (draggedFeed is not ({ Feed: { } feed } node, var fromFolderID))
        {
            await Sidebar.ReloadAsync();
            return;
        }
        draggedFeed = null;

        int? toFolderID = args.NewParentItem switch
        {
            SidebarNode { Kind: SidebarNodeKind.Folder, AccountID: var accountID, Folder: { } folder } when accountID == feed.AccountID => folder.FolderID,
            SidebarNode { Kind: SidebarNodeKind.Account, AccountID: var accountID } when accountID == feed.AccountID => null,
            _ => fromFolderID // Somewhere it can't go: leave it where it was.
        };
        try
        {
            if (toFolderID != fromFolderID)
            {
                await SwiftCore.MoveFeedAsync(feed.AccountID, feed.FeedID, fromFolderID, toFolderID);
                StatusText.Text = $"Moved {node.Name}";
            }
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
        // The tree already moved the node in its own collections; syncing to the core's structure
        // drops it from wherever it landed and puts the feed where the core has it. A feed's key
        // includes its folder, so a moved feed is a new row and the old one goes.
        await Sidebar.ReloadAsync();
    }

    private static MenuFlyoutItem MenuItem(string text, string glyph, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += async (_, _) => await action();
        return item;
    }

    // MARK: - Timeline and article

    private async void TimelineList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isResorting)
        {
            return;
        }
        var selected = TimelineList.SelectedItems.OfType<TimelineItem>().ToList();
        try
        {
            switch (selected.Count)
            {
                case 0:
                    shownArticle = null;
                    await articleView.ShowMessageAsync("No selection");
                    break;
                case 1:
                    var item = selected[0];
                    if (item == shownArticle)
                    {
                        return;
                    }
                    shownArticle = item;
                    await articleView.ShowArticleAsync(item.Reference);
                    if (item.IsUnread)
                    {
                        item.IsRead = true;
                        await SwiftCore.MarkArticlesAsync([item.Reference], read: true);
                    }
                    break;
                default:
                    shownArticle = null;
                    await articleView.ShowMessageAsync("Multiple selection");
                    break;
            }
        }
        catch (CoreException ex)
        {
            ShowError(ex);
        }
    }

    // MARK: - Sorting

    /// <summary>The Mac's sort menu: the field, the direction worded for it, and Group by Feed for a date sort.</summary>
    private void SortMenu_Opening(object? sender, object e)
    {
        var settings = AppSettings.Current;
        SortMenu.Items.Clear();
        for (var i = 0; i < AppSettings.SortKeys.Length; i++)
        {
            var key = AppSettings.SortKeys[i];
            var item = new RadioMenuFlyoutItem { Text = AppSettings.SortKeyNames[i], GroupName = "SortKey", IsChecked = settings.TimelineSortKey == key };
            item.Click += (_, _) => ChangeSort(key, AppSettings.SortsAscendingFirst(key), settings.TimelineGroupByFeed);
            SortMenu.Items.Add(item);
        }
        SortMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var ascending in new[] { true, false })
        {
            var item = new RadioMenuFlyoutItem { Text = AppSettings.SortDirectionTitle(settings.TimelineSortKey, ascending), GroupName = "SortDirection", IsChecked = settings.TimelineSortAscending == ascending };
            item.Click += (_, _) => ChangeSort(settings.TimelineSortKey, ascending, settings.TimelineGroupByFeed);
            SortMenu.Items.Add(item);
        }
        SortMenu.Items.Add(new MenuFlyoutSeparator());
        var group = new ToggleMenuFlyoutItem { Text = "Group by Feed", IsChecked = settings.TimelineGroupByFeed, IsEnabled = settings.TimelineSortKey == "date" };
        group.Click += (_, _) => ChangeSort(settings.TimelineSortKey, settings.TimelineSortAscending, !settings.TimelineGroupByFeed);
        SortMenu.Items.Add(group);
    }

    /// <summary>Saves the sort; the Changed handler puts the timeline in the new order.</summary>
    internal void ChangeSort(string key, bool ascending, bool groupByFeed)
    {
        var settings = AppSettings.Current;
        if (settings.TimelineSortKey == key && settings.TimelineSortAscending == ascending && settings.TimelineGroupByFeed == groupByFeed)
        {
            return;
        }
        settings.TimelineSortKey = key;
        settings.TimelineSortAscending = ascending;
        settings.TimelineGroupByFeed = groupByFeed;
        settings.Save();
    }

    /// <summary>Puts the rows in the new order, keeping the selection and the article shown, as on the Mac.</summary>
    private async Task ResortTimelineAsync()
    {
        var selected = TimelineList.SelectedItems.OfType<TimelineItem>().ToList();
        isResorting = true;
        try
        {
            if (!await Timeline.ResortAsync())
            {
                return;
            }
            foreach (var item in selected.Where(Timeline.Items.Contains))
            {
                TimelineList.SelectedItems.Add(item);
            }
        }
        finally
        {
            isResorting = false;
        }
        if (TimelineList.SelectedItems.FirstOrDefault() is { } first)
        {
            TimelineList.ScrollIntoView(first);
        }
    }

    /// <summary>Asks for a row's thumbnail when the row is realized — only rows on screen, newest first, as on the Mac.</summary>
    private void TimelineList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.Item is TimelineItem { Thumbnail: null, ThumbnailURL: not null } item)
        {
            _ = item.LoadThumbnailAsync();
        }
    }

    private List<TimelineItem> SelectedArticles => TimelineList.SelectedItems.OfType<TimelineItem>().ToList();

    private void SelectArticle(TimelineItem item)
    {
        TimelineList.SelectedItems.Clear();
        TimelineList.SelectedItem = item;
        TimelineList.ScrollIntoView(item);
    }

    private void ShowHoveredLink(string? link)
    {
        LinkOverlayText.Text = link ?? "";
        LinkOverlay.Visibility = string.IsNullOrEmpty(link) ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: - Commands

    private async Task RefreshAsync()
    {
        RefreshButton.IsEnabled = false;
        try
        {
            var result = await SwiftCore.RefreshAllAsync();
            StatusText.Text = !result.DidRefresh ? "Not refreshed: no network connection"
                : result.Errors.Count == 0 ? "" : $"Refreshed with {result.Errors.Count} error(s): {result.Errors[0]}";
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
        finally
        {
            RefreshButton.IsEnabled = true;
        }
    }

    /// <param name="url">A URL dropped on the sidebar. Without one, a URL on the clipboard is offered, as on the Mac.</param>
    /// <param name="folderID">The folder it was dropped on.</param>
    private async Task AddFeedAsync(string? url = null, int? folderID = null)
    {
        var sidebar = await SwiftCore.GetSidebarAsync();
        var localAccount = sidebar.Accounts.FirstOrDefault(account => account.AccountID == "OnMyMac");
        var urlBox = new TextBox { PlaceholderText = "https://example.com/feed.xml", Header = "URL", InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Url) } } };
        var nameBox = new TextBox { PlaceholderText = "Optional", Header = "Name" };
        var folders = new ComboBox { Header = "Folder", HorizontalAlignment = HorizontalAlignment.Stretch };
        folders.Items.Add(new ComboBoxItem { Content = "None (top level)", Tag = null });
        foreach (var folder in localAccount?.Folders ?? [])
        {
            folders.Items.Add(new ComboBoxItem { Content = folder.Name, Tag = folder.FolderID });
        }
        folders.SelectedIndex = Math.Max(0, folders.Items.OfType<ComboBoxItem>().ToList().FindIndex(item => item.Tag as int? == folderID));
        if (url is not null)
        {
            urlBox.Text = url;
        }
        else if (global::Windows.ApplicationModel.DataTransfer.Clipboard.GetContent() is { } clipboard && clipboard.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
        {
            if (FeedURL(await clipboard.GetTextAsync()) is { } clipboardURL)
            {
                urlBox.Text = clipboardURL; // As the Mac app does, offer a URL that's on the clipboard.
            }
        }
        addFeedURLForSelfTest = (urlBox.Text, (folders.SelectedItem as ComboBoxItem)?.Tag as int?);

        var dialog = new ContentDialog
        {
            Title = "Add a Feed",
            Content = new StackPanel { Spacing = 12, MinWidth = 400, Children = { urlBox, nameBox, folders } },
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || urlBox.Text.Trim().Length == 0)
        {
            return;
        }

        StatusText.Text = $"Finding a feed at {urlBox.Text.Trim()}";
        try
        {
            var chosenFolderID = (folders.SelectedItem as ComboBoxItem)?.Tag as int?;
            var name = nameBox.Text.Trim();
            var feed = await SwiftCore.SubscribeAsync(urlBox.Text.Trim(), name.Length == 0 ? null : name, folderID: chosenFolderID);
            StatusText.Text = $"Added {feed.Name}";
            var key = $"feed:{feed.AccountID}:{chosenFolderID?.ToString() ?? "top"}:{feed.FeedID}";
            await Sidebar.ReloadAsync();
            if (Sidebar.Find(key) is { } node)
            {
                SidebarTree.SelectedItem = node;
            }
        }
        catch (CoreException e)
        {
            StatusText.Text = "";
            await ShowAlertAsync("Couldn’t Add the Feed", e.Message);
        }
    }

    // MARK: - Opened URLs

    /// <summary>Restores and activates the window, for a launch redirected to this instance.</summary>
    internal void BringToFront()
    {
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized } presenter)
        {
            presenter.Restore();
        }
        Activate();
    }

    /// <summary>
    /// A URL the app was opened with, such as a feed: link from a browser. As on the Mac, a feed
    /// opens Add Feed with it filled in.
    /// </summary>
    internal async Task OpenURLAsync(string url)
    {
        lastOpenedURLForSelfTest = url;
        try
        {
            var action = await SwiftCore.InterpretOpenedURLAsync(url);
            switch (action.Kind)
            {
                case "addFeed" when action.Url is { } feedURL:
                    await AddFeedAsync(feedURL);
                    break;
                case "installTheme" when action.Url is { } themeURL:
                    await InstallThemeFromLinkAsync(themeURL);
                    break;
            }
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private string? lastOpenedURLForSelfTest;

    // MARK: - Themes from links

    /// <summary>
    /// A netnewswire://theme/ link, as the Mac handles it: download the zip, unzip it, find the .nnwtheme
    /// in it, and ask before installing — and again before replacing an installed theme of the same name.
    /// </summary>
    private async Task InstallThemeFromLinkAsync(string url)
    {
        StatusText.Text = "Downloading the theme";
        string zipPath;
        try
        {
            zipPath = await SwiftCore.DownloadThemeAsync(url);
        }
        catch (CoreException e)
        {
            StatusText.Text = "";
            await ShowAlertAsync("Couldn’t Download the Theme", e.Message);
            return;
        }
        StatusText.Text = "";
        await InstallThemeFromZipAsync(zipPath);
    }

    private async Task InstallThemeFromZipAsync(string zipPath)
    {
        var folder = Path.Combine(Path.GetTempPath(), $"NetNewsWire-theme-{Guid.NewGuid():N}");
        try
        {
            // ExtractToDirectory refuses entries that would land outside the folder.
            System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, folder);
            var themePath = Directory.EnumerateDirectories(folder, "*.nnwtheme", SearchOption.AllDirectories).FirstOrDefault();
            if (themePath is null)
            {
                await ShowAlertAsync("Couldn’t Install the Theme", "There is no NetNewsWire theme in the download.");
                return;
            }
            var theme = await SwiftCore.InspectThemeAsync(themePath);

            var website = new StackPanel { Spacing = 4 };
            if (Uri.TryCreate(theme.CreatorHomePage, UriKind.Absolute, out var homePage) && (homePage.Scheme == Uri.UriSchemeHttp || homePage.Scheme == Uri.UriSchemeHttps))
            {
                website.Children.Add(new TextBlock { Text = "Author’s website:" });
                website.Children.Add(new HyperlinkButton { Content = theme.CreatorHomePage, NavigateUri = homePage, Padding = new Thickness(0) });
            }
            if (await ConfirmThemeAsync($"Install theme “{theme.Name}” by {theme.CreatorName}?", website, "Install Theme") != ContentDialogResult.Primary)
            {
                return;
            }
            if (theme.IsInstalled && await ConfirmThemeAsync($"The theme “{theme.Name}” already exists. Overwrite it?", null, "Overwrite") != ContentDialogResult.Primary)
            {
                return;
            }
            await SwiftCore.InstallThemeAsync(themePath);
            await ShowAlertAsync("Theme Installed", $"The theme “{theme.Name}” has been installed.");
        }
        catch (Exception e) when (e is CoreException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            await ShowAlertAsync("Couldn’t Install the Theme", e.Message);
        }
        finally
        {
            try
            {
                File.Delete(zipPath);
                Directory.Delete(folder, recursive: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                System.Diagnostics.Debug.WriteLine($"Cleaning up the theme download: {e.Message}");
            }
        }
    }

    private Task<ContentDialogResult> ConfirmThemeAsync(string title, UIElement? content, string primaryButton)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content,
            PrimaryButtonText = primaryButton,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };
        return dialog.ShowAsync().AsTask();
    }

    /// <summary>
    /// The link flow after the download: zips a theme folder, runs the install flow on it, presses Install Theme
    /// and then OK, and returns the alert's title. The caller deletes the installed theme.
    /// </summary>
    internal async Task<string?> InstallThemeFromZipForSelfTestAsync(string themeFolder)
    {
        var zipPath = Path.Combine(Path.GetTempPath(), $"NetNewsWire-selftest-{Guid.NewGuid():N}.zip");
        var staging = Path.Combine(Path.GetTempPath(), $"NetNewsWire-selftest-{Guid.NewGuid():N}");
        CopyDirectory(themeFolder, Path.Combine(staging, Path.GetFileName(themeFolder)));
        System.IO.Compression.ZipFile.CreateFromDirectory(staging, zipPath);
        Directory.Delete(staging, recursive: true);

        var installing = InstallThemeFromZipAsync(zipPath);
        string? finalTitle = null;
        for (var step = 0; step < 3 && !installing.IsCompleted; step++)
        {
            await Task.Delay(1500);
            finalTitle = OpenDialogTitleForSelfTest();
            PressDialogButtonForSelfTest(finalTitle?.StartsWith("Install theme", StringComparison.Ordinal) == true ? "Install Theme" : finalTitle?.Contains("Overwrite", StringComparison.Ordinal) == true ? "Overwrite" : "OK");
        }
        await installing;
        return finalTitle;

        static void CopyDirectory(string source, string destination)
        {
            Directory.CreateDirectory(destination);
            foreach (var file in Directory.GetFiles(source))
            {
                File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
            }
            foreach (var directory in Directory.GetDirectories(source))
            {
                CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
            }
        }
    }

    private string? OpenDialogTitleForSelfTest() =>
        Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Content.XamlRoot)
            .Select(popup => popup.Child as ContentDialog ?? FindDescendant<ContentDialog>(popup.Child))
            .FirstOrDefault(dialog => dialog is not null)?.Title as string;

    // MARK: - Notifications

    /// <summary>
    /// A click on a new-article notification or one of its buttons. Open shows the article in its feed,
    /// as the Mac does; Mark as Read and Star change its status.
    /// </summary>
    internal async Task HandleNotificationAsync(IDictionary<string, string> arguments)
    {
        if (!arguments.TryGetValue("accountID", out var accountID) || !arguments.TryGetValue("articleID", out var articleID))
        {
            return;
        }
        var reference = new ArticleReference(accountID, articleID);
        try
        {
            switch (arguments.TryGetValue(NotificationService.ActionKey, out var action) ? action : NotificationService.OpenAction)
            {
                case NotificationService.MarkReadAction:
                    await SwiftCore.MarkArticlesAsync([reference], read: true);
                    break;
                case NotificationService.StarAction:
                    await SwiftCore.StarArticlesAsync([reference], starred: true);
                    break;
                default:
                    arguments.TryGetValue("feedID", out var feedID);
                    await ShowArticleAsync(accountID, feedID, articleID);
                    break;
            }
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    /// <summary>Selects the article's feed in the sidebar, then the article in the timeline.</summary>
    private async Task ShowArticleAsync(string accountID, string? feedID, string articleID)
    {
        if (Sidebar.AllNodes.FirstOrDefault(node => node.AccountID == accountID && node.Feed?.FeedID == feedID) is not { Selection: { } selection } node)
        {
            return;
        }
        SidebarTree.SelectedItem = node;
        await ShowSelectionAsync(selection);
        if (Timeline.Items.FirstOrDefault(item => item.ArticleID == articleID && item.Summary.AccountID == accountID) is { } item)
        {
            TimelineList.SelectedItem = item;
            TimelineList.ScrollIntoView(item);
        }
    }

    /// <summary>
    /// Shows a notification for a feed's newest article, clicks it, then marks the article read:
    /// returns whether it showed, the article the click selected, and whether marking it read removed it.
    /// </summary>
    internal async Task<(bool Available, bool Shown, string? Selected, bool Removed)> NotificationRoundTripForSelfTestAsync(FeedInfo feed, ArticleSummary article)
    {
        if (!NotificationService.IsAvailable)
        {
            return (false, false, null, false);
        }
        var notice = new NewArticleNotice(feed.AccountID, article.ArticleID, feed.FeedID, feed.Name, article.Title, article.Summary);
        NotificationService.Show([notice]);
        await Task.Delay(1000);
        var shownTags = await NotificationService.ShowingTagsAsync();

        var arguments = new Dictionary<string, string> { ["action"] = "open", ["accountID"] = feed.AccountID, ["feedID"] = feed.FeedID, ["articleID"] = article.ArticleID };
        await HandleNotificationAsync(arguments);
        await Task.Delay(1000);
        var selected = SelectedArticles.FirstOrDefault()?.ArticleID;

        // Selecting it marked it read, which withdraws the notification (the core's articlesRead event).
        await SwiftCore.MarkArticlesAsync([new ArticleReference(feed.AccountID, article.ArticleID)], read: true);
        await Task.Delay(1500);
        var remainingTags = await NotificationService.ShowingTagsAsync();
        return (true, shownTags.Count > 0, selected == article.ArticleID ? article.Title : selected, shownTags.Count > remainingTags.Count);
    }

    /// <summary>Waits for a URL handed over by another launch, then reports it and what Add Feed showed, and cancels.</summary>
    internal async Task<(string? OpenedURL, string? AddFeedURL)> WaitForOpenedURLForSelfTestAsync(TimeSpan timeout)
    {
        addFeedURLForSelfTest = null;
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline && addFeedURLForSelfTest is null)
        {
            await Task.Delay(200);
        }
        await Task.Delay(300);
        var addFeedURL = addFeedURLForSelfTest?.URL;
        PressDialogButtonForSelfTest("Cancel");
        return (lastOpenedURLForSelfTest, addFeedURL);
    }

    // MARK: - Accounts

    /// <summary>
    /// The Mac's Accounts settings: each account with a checkbox to turn it off, Delete for sync
    /// accounts, and Add Account. One dialog at a time, so adding closes this one first.
    /// </summary>
    private async Task ShowAccountsAsync()
    {
        var sidebar = await SwiftCore.GetSidebarAsync();
        var list = new StackPanel { Spacing = 8, MinWidth = 440 };
        ContentDialog? dialog = null;
        foreach (var account in sidebar.Accounts)
        {
            var row = new Grid { ColumnSpacing = 8, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
            var active = new CheckBox { Content = account.Name, IsChecked = account.IsActive };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(active, $"{account.Name}, active");
            active.Click += async (_, _) => await RunAsync(() => SwiftCore.SetAccountActiveAsync(account.AccountID, active.IsChecked == true));
            row.Children.Add(active);
            if (account.AccountID != "OnMyMac")
            {
                var delete = new Button { Content = "Delete" };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(delete, $"Delete {account.Name}");
                Grid.SetColumn(delete, 1);
                row.Children.Add(delete);
                delete.Click += (_, _) =>
                {
                    accountToDelete = account;
                    dialog?.Hide(); // Then confirm, since only one dialog can be open.
                };
            }
            list.Children.Add(row);
        }

        accountToDelete = null;
        dialog = new ContentDialog
        {
            Title = "Accounts",
            Content = new ScrollViewer { Content = list, MaxHeight = 420 },
            PrimaryButtonText = "Add Account…",
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };
        var result = await dialog.ShowAsync();
        if (accountToDelete is { } deleting)
        {
            await DeleteAccountAsync(deleting);
        }
        else if (result == ContentDialogResult.Primary)
        {
            await AddAccountAsync();
        }
    }

    private AccountInfo? accountToDelete;

    private async Task DeleteAccountAsync(AccountInfo account)
    {
        var confirm = new ContentDialog
        {
            Title = $"Delete “{account.Name}”?",
            Content = "Its feeds and articles are removed from this PC. Nothing changes on the server.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SwiftCore.DeleteAccountAsync(account.AccountID);
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Delete the Account", e.Message);
        }
    }

    /// <summary>As the Mac's account sheets: the service, its fields, a sign-up link. The dialog stays open until the service accepts the sign-in.</summary>
    private async Task AddAccountAsync()
    {
        var types = await SwiftCore.GetAccountTypesAsync();
        if (types.Count == 0)
        {
            return;
        }
        var typeBox = new ComboBox { Header = "Service", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = types.Select(type => type.Name).ToList(), SelectedIndex = 0 };
        var apiURLBox = new TextBox { Header = "API URL", InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Url) } } };
        var usernameBox = new TextBox { Header = "Username or email" };
        var passwordBox = new PasswordBox { Header = "Password" };
        var tokenBox = new PasswordBox { Header = "API token (instead of a username and password)" };
        var signUp = new HyperlinkButton { Padding = new Thickness(0) };
        var progress = new ProgressRing { IsActive = false, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left };
        var errorText = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"] };

        AccountTypeInfo Selected() => types[Math.Clamp(typeBox.SelectedIndex, 0, types.Count - 1)];
        void UpdateFields()
        {
            var type = Selected();
            apiURLBox.Visibility = type.NeedsAPIURL ? Visibility.Visible : Visibility.Collapsed;
            apiURLBox.PlaceholderText = type.ApiURLPlaceholder ?? "";
            tokenBox.Visibility = type.AcceptsAPIToken ? Visibility.Visible : Visibility.Collapsed;
            signUp.Content = $"Don’t have a {type.Name} account? Find out more";
            signUp.NavigateUri = Uri.TryCreate(type.SignUpURL, UriKind.Absolute, out var uri) ? uri : null;
            errorText.Text = "";
        }
        typeBox.SelectionChanged += (_, _) => UpdateFields();
        UpdateFields();

        var dialog = new ContentDialog
        {
            Title = "Add an Account",
            Content = new StackPanel { Spacing = 12, MinWidth = 420, Children = { typeBox, apiURLBox, usernameBox, passwordBox, tokenBox, signUp, progress, errorText } },
            PrimaryButtonText = "Sign In",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };
        AddedAccount? added = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            progress.IsActive = true;
            errorText.Text = "";
            try
            {
                var type = Selected();
                added = await SwiftCore.AddAccountAsync(type.Type, usernameBox.Text, passwordBox.Password,
                    type.AcceptsAPIToken && tokenBox.Password.Length > 0 ? tokenBox.Password : null,
                    type.NeedsAPIURL ? apiURLBox.Text : null);
            }
            catch (CoreException e)
            {
                errorText.Text = e.Message;
                args.Cancel = true; // Stay open, as the Mac's sheet does, so the user can fix it.
            }
            finally
            {
                progress.IsActive = false;
                deferral.Complete();
            }
        };
        addAccountDialogForSelfTest = (dialog, typeBox, apiURLBox, usernameBox, passwordBox, errorText);
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            addAccountDialogForSelfTest = null;
        }
        if (added is not null)
        {
            StatusText.Text = $"Added {added.Name}. Refreshing.";
        }
    }

    private (ContentDialog Dialog, ComboBox Type, TextBox ApiURL, TextBox Username, PasswordBox Password, TextBlock Error)? addAccountDialogForSelfTest;

    // MARK: - Get Info

    private Task ShowSelectedFeedInfoAsync() =>
        SidebarTree.SelectedItem is SidebarNode { Kind: SidebarNodeKind.Feed } node ? ShowFeedInfoAsync(node) : Task.CompletedTask;

    /// <summary>The Mac's feed inspector: the icon, the name to edit, the home page, and the feed's URL.</summary>
    private async Task ShowFeedInfoAsync(SidebarNode node)
    {
        if (node.Feed is not { } feed)
        {
            return;
        }
        var nameBox = new TextBox { Header = "Name", Text = feed.Name, HorizontalAlignment = HorizontalAlignment.Stretch };
        var header = new Grid { ColumnSpacing = 12, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        if (node.Icon is { } icon)
        {
            var image = new Image { Source = icon, Width = 48, Height = 48, VerticalAlignment = VerticalAlignment.Bottom };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            header.Children.Add(image);
        }
        Grid.SetColumn(nameBox, 1);
        header.Children.Add(nameBox);

        var panel = new StackPanel { Spacing = 12, MinWidth = 440, Children = { header } };
        panel.Children.Add(InfoRow("Home Page", feed.HomePageURL, "Open", "Open the home page in the browser", feed.HomePageURL is { } homePage ? () => LaunchAsync(homePage) : null));
        var notifyBox = new CheckBox { Content = "Notify about new articles", IsChecked = feed.NotifiesAboutNewArticles, IsEnabled = NotificationService.IsAvailable };
        panel.Children.Add(InfoRow("Feed URL", feed.Url, "Copy", "Copy the feed URL", () =>
        {
            var package = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(feed.Url);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            return Task.CompletedTask;
        }));

        panel.Children.Add(notifyBox);

        var dialog = new ContentDialog
        {
            Title = feed.Name,
            Content = panel,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };
        feedInfoDialogForSelfTest = (dialog, nameBox);
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }
        finally
        {
            feedInfoDialogForSelfTest = null;
        }
        // As on the Mac, an empty name is ignored rather than clearing the feed's name.
        var name = nameBox.Text.Trim();
        var notify = notifyBox.IsChecked == true;
        try
        {
            if (notify != feed.NotifiesAboutNewArticles)
            {
                await SwiftCore.SetFeedNotificationsAsync(feed.AccountID, feed.FeedID, notify);
                await Sidebar.ReloadAsync(); // Get Info reads the setting from the sidebar's feed.
            }
            if (name.Length > 0 && name != feed.Name)
            {
                await SwiftCore.RenameFeedAsync(feed.AccountID, feed.FeedID, name);
            }
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Rename", e.Message);
        }
    }

    /// <summary>A read-only, selectable value with a button beside it.</summary>
    private static Grid InfoRow(string header, string? value, string buttonText, string buttonName, Func<Task>? action)
    {
        var box = new TextBox { Header = header, Text = value ?? "", IsReadOnly = true, PlaceholderText = "None" };
        var button = new Button { Content = buttonText, VerticalAlignment = VerticalAlignment.Bottom, IsEnabled = action is not null };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, buttonName);
        if (action is not null)
        {
            button.Click += async (_, _) => await action();
        }
        var row = new Grid { ColumnSpacing = 8, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        Grid.SetColumn(button, 1);
        row.Children.Add(box);
        row.Children.Add(button);
        return row;
    }

    private (ContentDialog Dialog, TextBox NameBox)? feedInfoDialogForSelfTest;

    private (string URL, int? FolderID)? addFeedURLForSelfTest;

    // MARK: - Dropping a URL to add a feed

    /// <summary>
    /// A URL that may be a feed, as the Mac takes from a drop or the clipboard: http and https,
    /// and feed: URLs, which browsers hand to feed readers (feed:https://… and feed://…).
    /// </summary>
    internal static string? FeedURL(string text)
    {
        text = text.Trim();
        if (text.StartsWith("feed:", StringComparison.OrdinalIgnoreCase))
        {
            var rest = text[5..];
            text = rest.StartsWith("//", StringComparison.Ordinal) ? "http:" + rest : rest;
        }
        return Uri.TryCreate(text, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) ? text : null;
    }

    private static async Task<string?> DroppedFeedURLAsync(global::Windows.ApplicationModel.DataTransfer.DataPackageView data)
    {
        if (data.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.WebLink))
        {
            return FeedURL((await data.GetWebLinkAsync()).OriginalString);
        }
        if (data.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
        {
            return FeedURL(await data.GetTextAsync());
        }
        return null;
    }

    /// <summary>The folder a drop on this sidebar row adds into, as on the Mac: a folder, or a feed's folder. Null: the top level.</summary>
    internal static int? DropFolderID(SidebarNode? node) => node?.Kind is SidebarNodeKind.Folder or SidebarNodeKind.Feed ? node.Folder?.FolderID : null;

    private static SidebarNode? SidebarNodeAt(object? source)
    {
        for (var element = source as DependencyObject; element is not null; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            if (element is FrameworkElement { DataContext: SidebarNode node })
            {
                return node;
            }
        }
        return null;
    }

    /// <summary>A link dragged in from a browser is offered as a copy. The sidebar's own feed drags are the TreeView's.</summary>
    private void SidebarTree_ExternalDragOver(object sender, DragEventArgs e)
    {
        if (draggedFeed is not null)
        {
            return;
        }
        var data = e.DataView;
        if (data.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.WebLink) || data.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
        {
            e.AcceptedOperation = global::Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Add Feed";
            e.Handled = true;
        }
    }

    /// <summary>As on the Mac: the Add Feed dialog, with the URL and the folder dropped on filled in.</summary>
    private async void SidebarTree_ExternalDrop(object sender, DragEventArgs e)
    {
        if (draggedFeed is not null)
        {
            return;
        }
        var target = SidebarNodeAt(e.OriginalSource);
        var deferral = e.GetDeferral();
        string? url;
        try
        {
            url = await DroppedFeedURLAsync(e.DataView);
        }
        finally
        {
            deferral.Complete();
        }
        if (url is not null)
        {
            await RunAsync(() => AddFeedAsync(url, DropFolderID(target)));
        }
    }

    private async Task NewFolderAsync()
    {
        var name = await PromptAsync("New Folder", "Name", "", "Create");
        if (string.IsNullOrWhiteSpace(name))
        {
            return;
        }
        try
        {
            await SwiftCore.AddFolderAsync(name.Trim());
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Create the Folder", e.Message);
        }
    }

    private async Task RenameAsync(SidebarNode node)
    {
        var name = await PromptAsync("Rename", "Name", node.Name, "Rename");
        if (string.IsNullOrWhiteSpace(name) || name == node.Name || node.AccountID is not { } accountID)
        {
            return;
        }
        try
        {
            if (node.Kind == SidebarNodeKind.Feed && node.Feed is { } feed)
            {
                await SwiftCore.RenameFeedAsync(accountID, feed.FeedID, name.Trim());
            }
            else if (node.Kind == SidebarNodeKind.Folder && node.Folder is { } folder)
            {
                await SwiftCore.RenameFolderAsync(accountID, folder.FolderID, name.Trim());
            }
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Rename", e.Message);
        }
    }

    private async Task DeleteAsync(SidebarNode node)
    {
        if (node.AccountID is not { } accountID)
        {
            return;
        }
        var what = node.Kind == SidebarNodeKind.Folder ? $"the folder “{node.Name}” and its feeds" : $"“{node.Name}”";
        var dialog = new ContentDialog
        {
            Title = "Delete?",
            Content = $"Are you sure you want to delete {what}?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            if (node.Kind == SidebarNodeKind.Feed && node.Feed is { } feed)
            {
                await SwiftCore.DeleteFeedAsync(accountID, feed.FeedID, node.Folder?.FolderID);
            }
            else if (node.Kind == SidebarNodeKind.Folder && node.Folder is { } folder)
            {
                await SwiftCore.DeleteFolderAsync(accountID, folder.FolderID);
            }
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Delete", e.Message);
        }
    }

    private async Task MarkAllAsReadAsync()
    {
        var unread = Timeline.Items.Where(item => item.IsUnread).ToList();
        if (unread.Count == 0)
        {
            return;
        }
        foreach (var item in unread)
        {
            item.IsRead = true;
        }
        try
        {
            await SwiftCore.MarkArticlesAsync(unread.Select(item => item.Reference).ToList(), read: true);
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private async Task ToggleReadAsync()
    {
        var selected = SelectedArticles;
        if (selected.Count == 0)
        {
            return;
        }
        // As on the Mac: if any is unread, mark all read; otherwise mark all unread.
        var markRead = selected.Any(item => item.IsUnread);
        foreach (var item in selected)
        {
            item.IsRead = markRead;
        }
        try
        {
            await SwiftCore.MarkArticlesAsync(selected.Select(item => item.Reference).ToList(), markRead);
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private async Task ToggleStarredAsync()
    {
        var selected = SelectedArticles;
        if (selected.Count == 0)
        {
            return;
        }
        var star = selected.Any(item => !item.IsStarred);
        foreach (var item in selected)
        {
            item.IsStarred = star;
        }
        try
        {
            await SwiftCore.StarArticlesAsync(selected.Select(item => item.Reference).ToList(), star);
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    private async Task MarkUnreadAndGoToNextUnreadAsync()
    {
        if (SelectedArticles is [var item])
        {
            item.IsRead = false;
            await SwiftCore.MarkArticlesAsync([item.Reference], read: false);
        }
        await GoToNextUnreadAsync();
    }

    /// <summary>The next unread article in the timeline, else the first unread in the next sidebar item that has any.</summary>
    private async Task GoToNextUnreadAsync()
    {
        if (Timeline.NextUnread(SelectedArticles.LastOrDefault()) is { } next)
        {
            SelectArticle(next);
            return;
        }
        var nodes = Sidebar.AllNodes.Where(node => node.Kind is SidebarNodeKind.Feed or SidebarNodeKind.Folder).ToList();
        var current = SidebarTree.SelectedItem as SidebarNode;
        var start = current is null ? 0 : nodes.IndexOf(current) + 1;
        var candidates = nodes.Skip(start).Concat(nodes.Take(Math.Max(start, 0)));
        if (candidates.FirstOrDefault(node => node.UnreadCount > 0 && node != current) is { } nextNode)
        {
            isSyncingSelection = true;
            SidebarTree.SelectedItem = nextNode;
            isSyncingSelection = false;
            await Timeline.LoadAsync(nextNode.Selection);
            if (Timeline.NextUnread(null) is { } first)
            {
                SelectArticle(first);
            }
        }
    }

    /// <summary>Space, as on the Mac: scroll the article down a page, or at its end go to the next unread article.</summary>
    private async Task ScrollOrGoToNextUnreadAsync()
    {
        if (shownArticle is not null)
        {
            const string script = "(function() { if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) { return true; } window.scrollBy({ top: window.innerHeight * 0.9, behavior: 'smooth' }); return false; })()";
            if (await articleView.EvaluateAsync(script) == "false")
            {
                return;
            }
        }
        await GoToNextUnreadAsync();
    }

    private Task GoToPreviousUnreadAsync()
    {
        if (Timeline.PreviousUnread(SelectedArticles.FirstOrDefault()) is { } previous)
        {
            SelectArticle(previous);
        }
        return Task.CompletedTask;
    }

    private async Task OpenInBrowserAsync()
    {
        foreach (var item in SelectedArticles.Take(20))
        {
            if (item.Summary.Link is { } link)
            {
                await LaunchAsync(link);
            }
        }
    }

    private static async Task LaunchAsync(string link)
    {
        if (Uri.TryCreate(link, UriKind.Absolute, out var uri))
        {
            await Launcher.LaunchUriAsync(uri);
        }
    }

    private async Task ImportOpmlAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".opml");
        picker.FileTypeFilter.Add(".xml");
        if (await picker.PickSingleFileAsync() is not { } file)
        {
            return;
        }
        try
        {
            await SwiftCore.ImportOpmlAsync(file.Path);
            StatusText.Text = $"Imported {file.Name}";
        }
        catch (CoreException e)
        {
            await ShowAlertAsync("Couldn’t Import", e.Message);
        }
    }

    private async Task ExportOpmlAsync()
    {
        var picker = new FileSavePicker { SuggestedFileName = "Subscriptions" };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeChoices.Add("OPML", [".opml"]);
        if (await picker.PickSaveFileAsync() is not { } file)
        {
            return;
        }
        try
        {
            var opml = await SwiftCore.ExportOpmlAsync();
            await global::Windows.Storage.FileIO.WriteTextAsync(file, opml);
            StatusText.Text = $"Exported {file.Name}";
        }
        catch (Exception e) when (e is CoreException or IOException or UnauthorizedAccessException)
        {
            await ShowAlertAsync("Couldn’t Export", e.Message);
        }
    }

    // MARK: - Settings

    private static Task ChangeTextSize(int step)
    {
        var settings = AppSettings.Current;
        var index = Math.Clamp(Array.IndexOf(AppSettings.TextSizes, settings.TextSize) + step, 0, AppSettings.TextSizes.Length - 1);
        if (AppSettings.TextSizes[index] != settings.TextSize)
        {
            settings.TextSize = AppSettings.TextSizes[index];
            settings.Save();
        }
        return Task.CompletedTask;
    }

    /// <summary>Theme and text size, as the Mac's Appearance settings. Changes apply right away.</summary>
    private async Task ShowSettingsAsync()
    {
        var settings = AppSettings.Current;
        var themeBox = new ComboBox { Header = "Article theme", HorizontalAlignment = HorizontalAlignment.Stretch };
        var themeCredit = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
        var deleteButton = new Button { Content = "Delete Theme" };
        var installButton = new Button { Content = "Install Theme…" };
        var textSizeBox = new ComboBox { Header = "Article text size", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = AppSettings.TextSizeNames };
        textSizeBox.SelectedIndex = Math.Max(0, Array.IndexOf(AppSettings.TextSizes, settings.TextSize));
        var refreshBox = new ComboBox { Header = "Refresh feeds", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = AppSettings.RefreshIntervalNames };
        refreshBox.SelectedIndex = Math.Max(0, Array.IndexOf(AppSettings.RefreshIntervals, settings.RefreshInterval));
        refreshBox.SelectionChanged += (_, _) =>
        {
            if (refreshBox.SelectedIndex >= 0 && AppSettings.RefreshIntervals[refreshBox.SelectedIndex] != settings.RefreshInterval)
            {
                settings.RefreshInterval = AppSettings.RefreshIntervals[refreshBox.SelectedIndex];
                settings.Save();
            }
        };
        var thumbnailsBox = new ComboBox { Header = "Timeline thumbnails", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = AppSettings.TimelineThumbnailModeNames };
        thumbnailsBox.SelectedIndex = Math.Max(0, Array.IndexOf(AppSettings.TimelineThumbnailModes, settings.TimelineThumbnails));
        thumbnailsBox.SelectionChanged += (_, _) =>
        {
            if (thumbnailsBox.SelectedIndex >= 0 && AppSettings.TimelineThumbnailModes[thumbnailsBox.SelectedIndex] != settings.TimelineThumbnails)
            {
                settings.TimelineThumbnails = AppSettings.TimelineThumbnailModes[thumbnailsBox.SelectedIndex];
                settings.Save();
            }
        };

        List<ThemeInfo> themes = [];
        async Task LoadThemesAsync(string? select)
        {
            themes = await SwiftCore.ListThemesAsync();
            themeBox.ItemsSource = themes.Select(theme => theme.Name).ToList();
            var index = themes.FindIndex(theme => theme.Name == select);
            themeBox.SelectedIndex = index >= 0 ? index : 0;
        }
        void UpdateThemeDetails()
        {
            if (themeBox.SelectedIndex is var index && index >= 0 && index < themes.Count)
            {
                var theme = themes[index];
                themeCredit.Text = theme.IsDefault ? "" : $"By {theme.CreatorName}";
                deleteButton.IsEnabled = !theme.IsAppTheme && !theme.IsDefault;
            }
        }

        themeBox.SelectionChanged += (_, _) =>
        {
            UpdateThemeDetails();
            if (themeBox.SelectedIndex >= 0 && themeBox.SelectedIndex < themes.Count)
            {
                var theme = themes[themeBox.SelectedIndex];
                var name = theme.IsDefault ? null : theme.Name;
                if (name != settings.ThemeName)
                {
                    settings.ThemeName = name;
                    settings.Save();
                }
            }
        };
        textSizeBox.SelectionChanged += (_, _) =>
        {
            if (textSizeBox.SelectedIndex >= 0 && AppSettings.TextSizes[textSizeBox.SelectedIndex] != settings.TextSize)
            {
                settings.TextSize = AppSettings.TextSizes[textSizeBox.SelectedIndex];
                settings.Save();
            }
        };
        installButton.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add("*");
            if (await picker.PickSingleFolderAsync() is not { } folder)
            {
                return;
            }
            try
            {
                var theme = await SwiftCore.InstallThemeAsync(folder.Path);
                await LoadThemesAsync(theme.Name);
            }
            catch (CoreException ex)
            {
                themeCredit.Text = ex.Message;
            }
        };
        deleteButton.Click += async (_, _) =>
        {
            if (themeBox.SelectedIndex < 0 || themeBox.SelectedIndex >= themes.Count)
            {
                return;
            }
            try
            {
                await SwiftCore.DeleteThemeAsync(themes[themeBox.SelectedIndex].Name);
                await LoadThemesAsync(null);
            }
            catch (CoreException ex)
            {
                themeCredit.Text = ex.Message;
            }
        };

        await LoadThemesAsync(settings.ThemeName ?? themes.FirstOrDefault()?.Name);
        UpdateThemeDetails();

        var dialog = new ContentDialog
        {
            Title = "Settings",
            Content = new StackPanel
            {
                Spacing = 12,
                MinWidth = 400,
                Children =
                {
                    refreshBox,
                    themeBox,
                    themeCredit,
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { installButton, deleteButton } },
                    textSizeBox,
                    thumbnailsBox
                }
            },
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };
        await dialog.ShowAsync();
    }

    // MARK: - Search

    private async void SearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var query = args.QueryText.Trim();
        if (query.Length == 0)
        {
            return;
        }
        isSyncingSelection = true;
        SidebarTree.SelectedItem = null;
        isSyncingSelection = false;
        await ShowSelectionAsync(new ArticleSelection("search", Query: query));
        StatusText.Text = $"{Timeline.Items.Count:N0} results for “{query}”";
    }

    // MARK: - Keyboard

    private void AddAccelerator(VirtualKey key, VirtualKeyModifiers modifiers, Func<Task> action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += async (_, args) =>
        {
            args.Handled = true;
            await action();
        };
        RootGrid.KeyboardAccelerators.Add(accelerator);
    }

    private void RootGrid_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Typing in a text box, such as search, isn't a shortcut.
        if (e.OriginalSource is TextBox or AutoSuggestBox or PasswordBox)
        {
            return;
        }
        var modifiers = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) | InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu);
        if (modifiers.HasFlag(global::Windows.UI.Core.CoreVirtualKeyStates.Down))
        {
            return;
        }
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(global::Windows.UI.Core.CoreVirtualKeyStates.Down);
        var key = e.Key switch
        {
            VirtualKey.Space => " ",
            VirtualKey.Enter => "Enter",
            (VirtualKey)187 or VirtualKey.Add => "+",       // = / + key
            (VirtualKey)189 or VirtualKey.Subtract => "-",  // - key
            >= VirtualKey.A and <= VirtualKey.Z => ((char)('a' + (e.Key - VirtualKey.A))).ToString(),
            _ => null
        };
        if (key is not null && HandleShortcut(key, shift, fromPage: false))
        {
            e.Handled = true;
        }
    }

    /// <summary>Runs the Mac app's single-key shortcut for `key`. Returns false if there is none.</summary>
    private bool HandleShortcut(string key, bool shift, bool fromPage)
    {
        Func<Task>? action = (key.ToLowerInvariant(), shift) switch
        {
            // The page sends Space only when it's already scrolled to the bottom.
            (" ", false) => fromPage ? GoToNextUnreadAsync : ScrollOrGoToNextUnreadAsync,
            ("n", _) or ("+", _) => GoToNextUnreadAsync,
            ("-", _) => GoToPreviousUnreadAsync,
            ("r", _) or ("u", _) => ToggleReadAsync,
            ("s", _) => ToggleStarredAsync,
            ("k", _) => MarkAllAsReadAsync,
            ("m", _) => MarkUnreadAndGoToNextUnreadAsync,
            ("l", _) => async () => { await MarkAllAsReadAsync(); await GoToNextUnreadAsync(); },
            ("b", _) or ("enter", _) => OpenInBrowserAsync,
            _ => null
        };
        if (action is null)
        {
            return false;
        }
        _ = RunAsync(action);
        return true;
    }

    private async Task RunAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (CoreException e)
        {
            ShowError(e);
        }
    }

    // MARK: - Button handlers

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RunAsync(RefreshAsync);
    private async void AddFeed_Click(object sender, RoutedEventArgs e) => await RunAsync(() => AddFeedAsync());
    private async void NewFolder_Click(object sender, RoutedEventArgs e) => await RunAsync(NewFolderAsync);
    private async void MarkAllAsRead_Click(object sender, RoutedEventArgs e) => await RunAsync(MarkAllAsReadAsync);
    private async void ToggleRead_Click(object sender, RoutedEventArgs e) => await RunAsync(ToggleReadAsync);
    private async void ToggleStarred_Click(object sender, RoutedEventArgs e) => await RunAsync(ToggleStarredAsync);
    private async void NextUnread_Click(object sender, RoutedEventArgs e) => await RunAsync(GoToNextUnreadAsync);
    private async void OpenInBrowser_Click(object sender, RoutedEventArgs e) => await RunAsync(OpenInBrowserAsync);
    private async void ImportOpml_Click(object sender, RoutedEventArgs e) => await RunAsync(ImportOpmlAsync);
    private async void Settings_Click(object sender, RoutedEventArgs e) => await RunAsync(ShowSettingsAsync);
    private async void Accounts_Click(object sender, RoutedEventArgs e) => await RunAsync(ShowAccountsAsync);
    private async void ExportOpml_Click(object sender, RoutedEventArgs e) => await RunAsync(ExportOpmlAsync);

    // MARK: - Dialogs

    private async Task<string?> PromptAsync(string title, string label, string text, string action)
    {
        var box = new TextBox { Header = label, Text = text, MinWidth = 360 };
        box.SelectAll();
        var dialog = new ContentDialog
        {
            Title = title,
            Content = box,
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? box.Text : null;
    }

    private async Task ShowAlertAsync(string title, string message)
    {
        var dialog = new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", XamlRoot = Content.XamlRoot };
        await dialog.ShowAsync();
    }

    private void ShowError(CoreException e) => StatusText.Text = $"Error: {e.Message}";

    // MARK: - Self-test hooks

    /// <summary>Selects the article in the timeline, as a click would, and waits for WebView2 to render it.</summary>
    internal async Task<bool> ShowArticleForSelfTestAsync(ArticleReference article) => await articleView.ShowArticleAndWaitAsync(article);

    internal Task<string> EvaluateInArticleAsync(string script) => articleView.EvaluateAsync(script);

    /// <summary>The focused element's type, such as ListView.</summary>
    internal string? FocusedElementForSelfTest() =>
        FocusManager.GetFocusedElement(Content.XamlRoot)?.GetType().Name;

    /// <summary>Presses a single-key shortcut as the keyboard would, then waits for the article to load.</summary>
    internal async Task<(string? SelectedTitle, bool? SelectedIsRead)> PressShortcutForSelfTestAsync(string key)
    {
        HandleShortcut(key, shift: false, fromPage: false);
        for (var i = 0; i < 50 && SelectedArticles.Count == 0; i++)
        {
            await Task.Delay(100);
        }
        await Task.Delay(500);
        var selected = SelectedArticles.FirstOrDefault();
        return (selected?.Title, selected?.IsRead);
    }

    /// <summary>Moves a feed into a folder the way a drop does, through the core. Returns where the sidebar shows it after.</summary>
    internal async Task<string?> MoveFeedToNewFolderForSelfTestAsync(string feedKey, string folderName)
    {
        var folder = await SwiftCore.AddFolderAsync(folderName);
        await Sidebar.ReloadAsync();
        if (Sidebar.Find(feedKey) is not { Feed: { } feed } node)
        {
            return null;
        }
        await SwiftCore.MoveFeedAsync(feed.AccountID, feed.FeedID, node.Folder?.FolderID, folder.FolderID);
        await Sidebar.ReloadAsync();
        var moved = Sidebar.AllNodes.FirstOrDefault(n => n.Feed?.FeedID == feed.FeedID);
        var parent = Sidebar.AllNodes.FirstOrDefault(n => n.Children.Contains(moved!));
        // Put it back, so the rest of the self-test sees the usual sidebar.
        await SwiftCore.MoveFeedAsync(feed.AccountID, feed.FeedID, folder.FolderID, null);
        await SwiftCore.DeleteFolderAsync(feed.AccountID, folder.FolderID);
        await Sidebar.ReloadAsync();
        return parent?.Name;
    }

    /// <summary>Chooses a sort as the Sort menu does and waits for the rows to be re-sorted. Returns the titles in order and the selected one.</summary>
    internal async Task<(List<string> Titles, string? SelectedTitle, string? ShownTitle)> SortForSelfTestAsync(string key, bool ascending, bool groupByFeed)
    {
        ChangeSort(key, ascending, groupByFeed);
        for (var i = 0; i < 50 && (Timeline.Sort != AppSettings.Current.Sort || isResorting); i++)
        {
            await Task.Delay(100);
        }
        await Task.Delay(200);
        var shown = await EvaluateInArticleAsync("document.querySelector('.articleTitle')?.textContent?.trim() ?? null");
        return (Timeline.Items.Select(item => item.Title).ToList(), SelectedArticles.FirstOrDefault()?.Title, shown);
    }

    /// <summary>The Sort menu's items as opening it builds them: text, and * when checked, - when disabled.</summary>
    internal List<string> SortMenuForSelfTest()
    {
        SortMenu_Opening(SortMenu, EventArgs.Empty);
        return SortMenu.Items.Select(item => item switch
        {
            RadioMenuFlyoutItem radio => radio.Text + (radio.IsChecked ? "*" : ""),
            ToggleMenuFlyoutItem toggle => toggle.Text + (toggle.IsChecked ? "*" : "") + (toggle.IsEnabled ? "" : "-"),
            _ => "|",
        }).ToList();
    }

    /// <summary>
    /// What a link dropped on a sidebar row does: the Add Feed dialog, filled in. Returns its URL and folder, then cancels it.
    /// </summary>
    internal async Task<(string? URL, int? FolderID)> DropLinkForSelfTestAsync(string link, string nodeKey)
    {
        addFeedURLForSelfTest = null;
        var url = FeedURL(link);
        if (url is null)
        {
            return (null, null);
        }
        var adding = AddFeedAsync(url, DropFolderID(Sidebar.Find(nodeKey)));
        for (var i = 0; i < 50 && addFeedURLForSelfTest is null; i++)
        {
            await Task.Delay(100);
        }
        await Task.Delay(500);
        PressDialogButtonForSelfTest("Cancel");
        await adding;
        return addFeedURLForSelfTest is { } shown ? (shown.URL, shown.FolderID) : (null, null);
    }

    /// <summary>Opens Get Info for a feed, types a name, and presses Save. Returns the name the sidebar shows after.</summary>
    internal async Task<string?> RenameInGetInfoForSelfTestAsync(string feedKey, string name)
    {
        if (Sidebar.Find(feedKey) is not { } node)
        {
            return null;
        }
        var showing = ShowFeedInfoAsync(node);
        for (var i = 0; i < 50 && feedInfoDialogForSelfTest is null; i++)
        {
            await Task.Delay(100);
        }
        await Task.Delay(500);
        if (feedInfoDialogForSelfTest is not { } open)
        {
            return null;
        }
        open.NameBox.Text = name;
        PressDialogButtonForSelfTest("Save");
        await showing;
        await Sidebar.ReloadAsync();
        return Sidebar.AllNodes.FirstOrDefault(n => n.Feed?.FeedID == node.Feed?.FeedID)?.Name;
    }

    /// <summary>
    /// Adds an account through the dialog with a server that doesn't exist: returns the service names offered,
    /// the error shown, and whether the dialog stayed open for a fix. Then cancels it.
    /// </summary>
    internal async Task<(List<string> Services, string? Error, bool StayedOpen)> AddAccountWithUnreachableServerForSelfTestAsync(string serviceName, string apiURL)
    {
        var adding = AddAccountAsync();
        for (var i = 0; i < 50 && addAccountDialogForSelfTest is null; i++)
        {
            await Task.Delay(100);
        }
        await Task.Delay(300);
        if (addAccountDialogForSelfTest is not { } open)
        {
            return ([], null, false);
        }
        var services = (open.Type.ItemsSource as IEnumerable<string>)?.ToList() ?? [];
        open.Type.SelectedIndex = services.IndexOf(serviceName);
        open.ApiURL.Text = apiURL;
        open.Username.Text = "self-test";
        open.Password.Password = "not-a-real-password";
        PressDialogButtonForSelfTest("Sign In");
        for (var i = 0; i < 300 && open.Error.Text.Length == 0; i++)
        {
            await Task.Delay(100);
        }
        var error = open.Error.Text;
        var stayedOpen = addAccountDialogForSelfTest is not null;
        PressDialogButtonForSelfTest("Cancel");
        await adding;
        return (services, error, stayedOpen);
    }

    /// <summary>Presses a button in the open dialog through UI Automation, as Narrator or a click would.</summary>
    private void PressDialogButtonForSelfTest(string text)
    {
        foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Content.XamlRoot))
        {
            if (FindButton(popup.Child, text) is { } button)
            {
                (new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button) as Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider).Invoke();
                return;
            }
        }

        static Button? FindButton(DependencyObject? parent, string text)
        {
            if (parent is null)
            {
                return null;
            }
            if (parent is Button { Content: string content } button && content == text)
            {
                return button;
            }
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            {
                if (FindButton(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i), text) is { } found)
                {
                    return found;
                }
            }
            return null;
        }
    }

    internal async Task SelectSidebarItemForSelfTestAsync(string key)
    {
        if (Sidebar.Find(key) is { } node)
        {
            SidebarTree.SelectedItem = node;
            for (var i = 0; i < 50 && Timeline.Selection != node.Selection; i++)
            {
                await Task.Delay(100);
            }
        }
    }

    private static T? FindDescendant<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is T match || FindDescendant<T>(child) is { } nested && (match = nested) is not null)
            {
                return match;
            }
        }
        return null;
    }

    // MARK: - Title bar

    /// <summary>The search box takes clicks; the rest of the title bar drags the window.</summary>
    private void UpdateTitleBarRegions()
    {
        if (AppTitleBar.XamlRoot is null)
        {
            return;
        }
        var scale = AppTitleBar.XamlRoot.RasterizationScale;
        AppTitleBar.Padding = new Thickness(16, 0, AppWindow.TitleBar.RightInset / scale, 0);

        var transform = SearchBox.TransformToVisual(null);
        var bounds = transform.TransformBounds(new global::Windows.Foundation.Rect(0, 0, SearchBox.ActualWidth, SearchBox.ActualHeight));
        var rect = new global::Windows.Graphics.RectInt32(
            (int)Math.Round(bounds.X * scale), (int)Math.Round(bounds.Y * scale),
            (int)Math.Round(bounds.Width * scale), (int)Math.Round(bounds.Height * scale));
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, [rect]);
    }
}
