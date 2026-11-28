using System.Runtime.InteropServices;

namespace NetNewsWire.Windows.Core;

/// <summary>
/// P/Invoke declarations for NetNewsWireCore.dll (the Swift core; see Windows/Core/Sources/NetNewsWireCore/CoreAPI.swift).
/// Every char* the core hands over must be released with nnw_string_free.
/// </summary>
internal static unsafe partial class NativeMethods
{
    private const string Library = "NetNewsWireCore";

    [LibraryImport(Library)]
    internal static partial nint nnw_core_version();

    [LibraryImport(Library)]
    internal static partial void nnw_string_free(nint str);

    [LibraryImport(Library)]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static partial bool nnw_is_main_thread();

    [LibraryImport(Library)]
    internal static partial nint nnw_main_queue_handle();

    [LibraryImport(Library)]
    internal static partial void nnw_drain_main_queue();

    [LibraryImport(Library)]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static partial bool nnw_core_start(nint eventContext, delegate* unmanaged[Cdecl]<nint, nint, void> eventCallback);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void nnw_request(string method, string? paramsJson, nint context, delegate* unmanaged[Cdecl]<nint, nint, void> callback);

    /// <summary>Copies a core-owned UTF-8 string and frees it.</summary>
    internal static string? TakeString(nint str)
    {
        if (str == 0)
        {
            return null;
        }
        try
        {
            return Marshal.PtrToStringUTF8(str);
        }
        finally
        {
            nnw_string_free(str);
        }
    }
}
