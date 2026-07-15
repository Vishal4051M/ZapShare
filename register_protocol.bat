@echo off
REM Register io.supabase.zapshare:// protocol for ZapShare development

echo Registering io.supabase.zapshare:// protocol...

REM Get the path to the Flutter executable
set "FLUTTER_EXE=%~dp0build\windows\x64\runner\Debug\zap_share.exe"

REM Register the protocol
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare" /ve /d "URL:ZapShare OAuth Callback" /f
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare" /v "URL Protocol" /d "" /f
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare\shell\open\command" /ve /d "\"%FLUTTER_EXE%\" \"%%1\"" /f

REM Register Explorer Right-Click Context Menus
echo Registering Windows Explorer context menus...
reg add "HKEY_CURRENT_USER\Software\Classes\*\shell\ZapShareLocal" /ve /d "ZapShare - Local Share" /f
reg add "HKEY_CURRENT_USER\Software\Classes\*\shell\ZapShareLocal\command" /ve /d "\"%FLUTTER_EXE%\" \"%%1\" --local" /f

reg add "HKEY_CURRENT_USER\Software\Classes\*\shell\ZapShareRemote" /ve /d "ZapShare - Remote Share" /f
reg add "HKEY_CURRENT_USER\Software\Classes\*\shell\ZapShareRemote\command" /ve /d "\"%FLUTTER_EXE%\" \"%%1\" --remote" /f

reg add "HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\video\shell\ZapShareCast" /ve /d "ZapShare - Cast Video" /f
reg add "HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\video\shell\ZapShareCast\command" /ve /d "\"%FLUTTER_EXE%\" \"%%1\" --cast" /f

echo.
echo Protocol registered successfully!
echo Deep links like io.supabase.zapshare://login-callback will now open ZapShare
echo.
pause
