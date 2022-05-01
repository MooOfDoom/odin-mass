@echo off

IF NOT EXIST C:\development\odin-mass\build mkdir C:\development\odin-mass\build
pushd C:\development\odin-mass\build
odin build ..\code -out=mass.exe -debug
if %errorlevel% neq 0 (
	echo Error building mass: %errorlevel%
	popd
	exit /b 1
)
odin build ..\code\test -out=mass_test.exe -debug
if %errorlevel% neq 0 (
	echo Error building mass: %errorlevel%
	popd
	exit /b 1
)
popd

pushd C:\development\odin-mass
build\mass_test
build\mass code\fixtures\exit_code.mass
build\test
echo Exit Code (Macro):  %errorlevel%
build\test_parsed
echo Exit Code (Parsed): %errorlevel%
build\test_cli
echo Exit Code (CLI):    %errorlevel%
build\hello_world
echo:
build\parsed_hello_world
echo:
popd