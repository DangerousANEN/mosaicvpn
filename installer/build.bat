@echo off
setlocal enabledelayedexpansion

echo ===================================================
echo   MosaicVPN Windows Release Build Pipeline
echo ===================================================

:: Resolve project root directory
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%.."
set "ROOT_DIR=%CD%"

echo Working Directory: %ROOT_DIR%

:: Step 1: Build Go Binaries
echo.
echo [1/4] Building Go binaries (CGO_ENABLED=0)...
set "CGO_ENABLED=0"
set "GOOS=windows"
set "GOARCH=amd64"

if not exist "%ROOT_DIR%\build" mkdir "%ROOT_DIR%\build"

echo   - Building mosaicd.exe (Go daemon)...
go build -v -ldflags="-s -w" -o "%ROOT_DIR%\build\mosaicd.exe" "%ROOT_DIR%\cmd\mosaicd"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to build mosaicd.exe
    exit /b %ERRORLEVEL%
)

echo   - Building mosaic.exe (Go CLI)...
go build -v -ldflags="-s -w" -o "%ROOT_DIR%\build\mosaic.exe" "%ROOT_DIR%\cmd\mosaic"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to build mosaic.exe
    exit /b %ERRORLEVEL%
)

:: Step 2: Build Flutter Release
echo.
echo [2/4] Building Flutter release...
set "FLUTTER_CMD=flutter"
where flutter >nul 2>nul
if %ERRORLEVEL% neq 0 (
    if exist "C:\Users\ANEN\flutter-sdk\bin\flutter.bat" (
        set "FLUTTER_CMD=C:\Users\ANEN\flutter-sdk\bin\flutter.bat"
    )
)

cd /d "%ROOT_DIR%\flutter"
call "%FLUTTER_CMD%" build windows --release
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to build Flutter release
    cd /d "%ROOT_DIR%"
    exit /b %ERRORLEVEL%
)
cd /d "%ROOT_DIR%"

:: Step 3: Prepare Staging Directory
echo.
echo [3/4] Staging files for installer...
set "STAGING_DIR=%ROOT_DIR%\dist\staging"
if exist "%STAGING_DIR%" rmdir /s /q "%STAGING_DIR%"
mkdir "%STAGING_DIR%"

:: Copy Go binaries
copy /y "%ROOT_DIR%\build\mosaicd.exe" "%STAGING_DIR%\" >nul
copy /y "%ROOT_DIR%\build\mosaic.exe" "%STAGING_DIR%\" >nul

:: Copy Flutter release contents
set "FLUTTER_RELEASE=%ROOT_DIR%\flutter\build\windows\x64\runner\Release"
if not exist "%FLUTTER_RELEASE%" (
    echo ERROR: Flutter release directory not found at %FLUTTER_RELEASE%
    exit /b 1
)

xcopy /s /e /y "%FLUTTER_RELEASE%\*" "%STAGING_DIR%\" >nul

:: Ensure mosaicvpn.exe exists in staging
if exist "%STAGING_DIR%\mosaic_vpn.exe" (
    copy /y "%STAGING_DIR%\mosaic_vpn.exe" "%STAGING_DIR%\mosaicvpn.exe" >nul
)

:: Copy app icon to staging
if exist "%ROOT_DIR%\assets\icon.ico" (
    copy /y "%ROOT_DIR%\assets\icon.ico" "%STAGING_DIR%\" >nul
)

:: Check for sing-box placeholder binary
if exist "%ROOT_DIR%\build\sing-box.exe" (
    copy /y "%ROOT_DIR%\build\sing-box.exe" "%STAGING_DIR%\" >nul
    echo   - Bundling sing-box.exe
) else (
    echo   - sing-box.exe not present (placeholder skipped)
)

:: Step 4: Run NSIS Compiler
echo.
echo [4/4] Compiling NSIS Installer...
set "MAKENSIS_CMD=makensis"
where makensis >nul 2>nul
if %ERRORLEVEL% neq 0 (
    if exist "C:\Program Files (x86)\NSIS\makensis.exe" (
        set "MAKENSIS_CMD=C:\Program Files (x86)\NSIS\makensis.exe"
    ) else if exist "C:\Program Files\NSIS\makensis.exe" (
        set "MAKENSIS_CMD=C:\Program Files\NSIS\makensis.exe"
    )
)

if not exist "%ROOT_DIR%\dist" mkdir "%ROOT_DIR%\dist"

"%MAKENSIS_CMD%" "%ROOT_DIR%\installer\mosaicvpn.nsi"
if %ERRORLEVEL% neq 0 (
    echo ERROR: NSIS compilation failed!
    exit /b %ERRORLEVEL%
)

echo.
echo ===================================================
echo   BUILD SUCCESSFUL
echo   Installer: %ROOT_DIR%\dist\MosaicVPN-0.5.0-Setup.exe
echo ===================================================

endlocal
