@echo off
rem Gympath IMU debug viewer launcher — double-click to run.
rem Extra args pass through, e.g.:  run_viewer.bat --replay logs\imu_log_....csv
"%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%~dp0imu_debug_viewer.py" %*
pause
