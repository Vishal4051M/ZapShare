@echo off
REM Register io.supabase.zapshare:// protocol for ZapShare development

echo Registering io.supabase.zapshare:// protocol...

REM Get the path to the Flutter executable
set "FLUTTER_EXE=%~dp0build\windows\x64\runner\Debug\zap_share.exe"

REM Register the protocol
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare" /ve /d "URL:ZapShare OAuth Callback" /f
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare" /v "URL Protocol" /d "" /f
reg add "HKEY_CURRENT_USER\Software\Classes\io.supabase.zapshare\shell\open\command" /ve /d "\"%FLUTTER_EXE%\" \"%%1\"" /f

echo.
echo Protocol registered successfully!
echo Deep links like io.supabase.zapshare://login-callback will now open ZapShare
echo.
pause
