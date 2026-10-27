@echo off
rem Builds Griefer Shield (with the packet size limit) into out\GrieferShield-<version>.zip on Windows.
rem Needs the .NET SDK (8 or newer) and WEBFISHING with GDWeave installed (for GDWeave.dll).
rem It looks in the r2modman profile "Modded" first, then the default Steam folder. For somewhere else, set GDWEAVE_PATH to its GDWeave folder first, for example:
rem    set GDWEAVE_PATH=D:\Games\WEBFISHING\GDWeave
setlocal
cd /d "%~dp0"

if "%GDWEAVE_PATH%"=="" set "GDWEAVE_PATH=%APPDATA%\r2modmanPlus-local\WEBFISHING\profiles\Modded\GDWeave"
if not exist "%GDWEAVE_PATH%\core\GDWeave.dll" set "GDWEAVE_PATH=C:\Program Files (x86)\Steam\steamapps\common\WEBFISHING\GDWeave"
if not exist "%GDWEAVE_PATH%\core\GDWeave.dll" (
    echo Could not find "%GDWEAVE_PATH%\core\GDWeave.dll".
    echo Set GDWEAVE_PATH to the GDWeave folder of your WEBFISHING install and run this again.
    pause
    exit /b 1
)

for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content thunderstore\manifest.json -Raw | ConvertFrom-Json).version_number"`) do set "VERSION=%%v"
echo Building Griefer Shield %VERSION%

if exist build rmdir /s /q build
dotnet build source\GrieferShield.Patch\GrieferShield.Patch.csproj -c Release -o build\dll "-p:GDWeaveCore=%GDWEAVE_PATH%\core"
if errorlevel 1 (
    echo The build failed, see the messages above.
    pause
    exit /b 1
)
if not exist build\dll\GrieferShield.dll (
    echo GrieferShield.dll was not made.
    pause
    exit /b 1
)

set "STAGE=build\stage"
mkdir "%STAGE%\GDWeave\mods\GrieferShield"
copy /y thunderstore\manifest.json "%STAGE%\" >nul
copy /y thunderstore\README.md "%STAGE%\" >nul
copy /y thunderstore\CHANGELOG.md "%STAGE%\" >nul
copy /y thunderstore\icon.png "%STAGE%\" >nul
copy /y LICENSE "%STAGE%\" >nul
copy /y package\GrieferShield\manifest.json "%STAGE%\GDWeave\mods\GrieferShield\" >nul
copy /y package\GrieferShield\GrieferShield.pck "%STAGE%\GDWeave\mods\GrieferShield\" >nul
copy /y build\dll\GrieferShield.dll "%STAGE%\GDWeave\mods\GrieferShield\" >nul

if not exist out mkdir out
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-zip.ps1" -Stage "%CD%\%STAGE%" -Zip "%CD%\out\GrieferShield-%VERSION%.zip"
if errorlevel 1 (
    echo Could not make the zip.
    pause
    exit /b 1
)

echo.
echo Done: %CD%\out\GrieferShield-%VERSION%.zip
pause
