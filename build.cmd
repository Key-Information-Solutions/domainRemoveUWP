@echo off
setlocal
rem Builds dist\removeUWP.exe from host.cs with removeUWP.ps1 embedded inside,
rem then publishes it to the folder root + stamps installs.py (postbuild.ps1).
rem Uses the C# compiler that ships with Windows (.NET Framework 4.x) -- no
rem toolchain to install. Edit removeUWP.ps1, double-click this, done.
rem NOTE: capture %~dp0 before cd -- it re-expands wrongly after cd when this
rem script is invoked via a relative path.
set "HERE=%~dp0"
cd /d "%HERE%"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: csc.exe not found. .NET Framework 4.x is required.
    pause
    exit /b 1
)

if not exist dist mkdir dist
"%CSC%" /nologo /target:exe /out:dist\removeUWP.exe /win32manifest:app.manifest /resource:removeUWP.ps1,removeUWP.ps1 host.cs
if errorlevel 1 (
    echo.
    echo BUILD FAILED
    pause
    exit /b 1
)

echo.
echo Built dist\removeUWP.exe
if not exist "%HERE%postbuild.ps1" (
    echo POST-BUILD FAILED - postbuild.ps1 not found next to build.cmd
    pause
    exit /b 1
)
rem Clear PSModulePath so Windows PowerShell rebuilds its own default -- an
rem inherited PowerShell 7 module path breaks 5.1 cmdlet auto-loading when
rem this script is launched from a pwsh terminal. (setlocal keeps this local.)
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%postbuild.ps1"
if errorlevel 1 (
    echo.
    echo POST-BUILD FAILED - exe was built but not published/stamped
    pause
    exit /b 1
)
echo.
echo Done. The exe at the folder root is live on the portal once OneDrive syncs.
pause
exit /b 0
