@echo off
rem Gympath guided IMU rotation test — double-click to run.
rem Follow the on-screen instructions (rotate / hold still / translate).
"%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%~dp0imu_rotation_test.py" %*
pause
