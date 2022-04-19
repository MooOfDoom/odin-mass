@echo off

IF NOT EXIST C:\development\odin-mass\build mkdir C:\development\odin-mass\build
pushd C:\development\odin-mass\build
odin build ..\code -out=mass.exe -debug
if %errorlevel% neq 0 (
	popd
	exit /b 1
)
odin build ..\code\minimal -out=minimal.exe -opt:3 -no-crt -no-bounds-check -disable-assert
if %errorlevel% neq 0 (
	popd
	exit /b 1
)
popd

pushd C:\development\odin-mass
build\mass
build\test
echo Exit Code: %errorlevel%
popd