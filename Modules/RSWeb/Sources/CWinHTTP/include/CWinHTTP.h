//
//  CWinHTTP.h
//  RSWeb
//
//  WinHTTP, which Swift's WinSDK module doesn't include. Used by WinHTTPClient,
//  the Windows transport. Empty on other platforms.
//

#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#endif
