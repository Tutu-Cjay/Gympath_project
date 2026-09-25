@echo off
rem Gympath backend test server — double-click to run.
rem Binds to 0.0.0.0 so your phone (same Wi-Fi) can reach it at http://<PC-IP>:8000
set PY=%LOCALAPPDATA%\Programs\Python\Python312\python.exe
cd /d "%~dp0"
echo Starting Gympath API on http://0.0.0.0:8000  (docs at /docs)
"%PY%" -m uvicorn app.main:app --host 0.0.0.0 --port 8000
pause
