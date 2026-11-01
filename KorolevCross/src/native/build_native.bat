@echo off
setlocal
if not defined VSDIR set "VSDIR=E:\Program Files\Microsoft Visual Studio\18\Community"
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
if not defined JAVA_HOME set "JAVA_HOME=E:\Program Files\Java\jdk-17"
if not defined CUDA_PATH set "CUDA_PATH=E:\CUDA"
set "OUT=%~dp0..\main\resources\native\Release"
if not exist "%OUT%" mkdir "%OUT%"
"%CUDA_PATH%\bin\nvcc.exe" -shared -o "%OUT%\korolev_native.dll" "%~dp0src\kv_native.cu" ^
  -I"%JAVA_HOME%\include" -I"%JAVA_HOME%\include\win32" ^
  -arch=sm_89 -std=c++17 --fmad=false -O3 -Xcompiler "/MD /O2 /EHsc"
if errorlevel 1 exit /b 1
echo built %OUT%\korolev_native.dll
