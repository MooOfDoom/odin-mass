@echo off

IF NOT EXIST C:\development\odin-mass\build mkdir C:\development\odin-mass\build
pushd C:\development\odin-mass\build
odin build ..\code -out=mass.exe -debug
if %errorlevel% neq 0 (
	popd
	exit /b 1
)
mass
popd
