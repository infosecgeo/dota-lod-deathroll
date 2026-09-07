@echo off
setlocal
REM ============================================================
REM AI-LOD (dota-lod-deathroll) - plug-and-play installer (Windows)
REM Copies the addon into your Dota 2 Workshop Tools addons
REM folder and installs + starts the local MMR server.
REM
REM Usage: double-click install.bat, or run it from a terminal:
REM   install.bat "D:\Steam\steamapps\common\dota 2 beta"
REM ============================================================

set "DOTA_DIR=%~1"

if "%DOTA_DIR%"=="" (
	echo.
	echo  Drag your "dota 2 beta" folder onto this script,
	echo  or run: install.bat "C:\Program Files ^(x86^)\Steam\steamapps\common\dota 2 beta"
	echo.
	set /p DOTA_DIR="Paste the path to your 'dota 2 beta' folder and press Enter: "
)

if not exist "%DOTA_DIR%\game\dota_addons" (
	echo.
	echo ERROR: Could not find "%DOTA_DIR%\game\dota_addons".
	echo Make sure Dota 2 Workshop Tools are installed:
	echo   Steam -^> Dota 2 -^> DLC -^> check "Dota 2 Workshop Tools"
	pause
	exit /b 1
)

echo.
echo [1/3] Installing addon into %DOTA_DIR% ...

robocopy "%~dp0game" "%DOTA_DIR%\game\dota_addons\dota-lod-deathroll" /MIR /NFL /NDL /NJH /NJS >nul
if errorlevel 8 (
	echo ERROR: Failed to copy game files.
	pause
	exit /b 1
)

echo [2/3] Installing MMR server dependencies ...
pushd "%~dp0mmr-server"
where npm >nul 2>nul
if errorlevel 1 (
	echo ERROR: Node.js/npm not found. Install Node.js LTS 22.5+ from https://nodejs.org and re-run.
	popd
	pause
	exit /b 1
)
REM Require Node 22.5+ (built-in node:sqlite). No Visual Studio / node-gyp needed.
for /f "tokens=1 delims=v" %%V in ('node -v 2^>nul') do set "NODE_VER=%%V"
for /f "tokens=1,2 delims=." %%A in ("%NODE_VER%") do (
	set "NODE_MAJOR=%%A"
	set "NODE_MINOR=%%B"
)
if not defined NODE_MAJOR (
	echo ERROR: Could not read Node.js version. Install Node.js LTS 22.5+ from https://nodejs.org
	popd
	pause
	exit /b 1
)
if %NODE_MAJOR% LSS 22 (
	echo ERROR: Node.js %NODE_VER% is too old. Need 22.5 or newer ^(LTS recommended^).
	echo Download: https://nodejs.org
	popd
	pause
	exit /b 1
)
if %NODE_MAJOR% EQU 22 if %NODE_MINOR% LSS 5 (
	echo ERROR: Node.js %NODE_VER% is too old. Need 22.5 or newer ^(LTS recommended^).
	echo Download: https://nodejs.org
	popd
	pause
	exit /b 1
)
call npm install
if errorlevel 1 (
	echo ERROR: npm install failed.
	echo Tip: use Node.js LTS from https://nodejs.org — this project needs no C++ build tools.
	popd
	pause
	exit /b 1
)
popd

echo [3/3] Done!
echo.
echo ============================================================
echo  Addon installed to:
echo    %DOTA_DIR%\game\dota_addons\dota-lod-deathroll
echo.
echo  To play:
echo    1. Start the MMR server:  run start-mmr-server.bat
echo    2. Open Dota 2 Workshop Tools, select "dota-lod-deathroll"
echo    3. Press the "Play" button in Workshop Tools
echo ============================================================
pause
endlocal
