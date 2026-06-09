@echo off
echo.
echo ========================================
echo   ZapShare Website - Local Test Server
echo ========================================
echo.
echo Starting local web server on port 8080...
echo.
echo Open your browser and go to:
echo   http://localhost:8080
echo.
echo Press Ctrl+C to stop the server
echo.
echo ========================================
echo.

cd /d "%~dp0zapshare-website"
python -m http.server 8080
