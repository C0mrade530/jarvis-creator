@echo off
setlocal DisableDelayedExpansion
set "PYTHONUTF8=1"

py -3 -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 goto launcher
python -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 goto python

echo Jarvis Creator requires Python 3.10 or newer. 1>&2
echo Install Python from https://www.python.org/downloads/windows/ 1>&2
if "%~1"=="" pause
exit /b 1

:launcher
if "%~1"=="" (
    py -3 "%~dp0scripts\creator.py" start
    goto finish
)
py -3 "%~dp0scripts\creator.py" %*
goto finish

:python
if "%~1"=="" (
    python "%~dp0scripts\creator.py" start
    goto finish
)
python "%~dp0scripts\creator.py" %*

:finish
set "jarvis_exit=%errorlevel%"
if "%~1"=="" if not "%jarvis_exit%"=="0" pause
exit /b %jarvis_exit%
