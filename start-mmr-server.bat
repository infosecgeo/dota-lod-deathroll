@echo off
REM Starts the LOD Deathroll local MMR server (http://localhost:3000)
cd /d "%~dp0mmr-server"
if not exist node_modules (
	echo Installing dependencies first...
	call npm install
)
npm start
pause
