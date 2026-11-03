@echo off
setlocal
set GRADLE_HOME=%USERPROFILE%\.gradle\injaz-gradle-8.14
if not exist "%GRADLE_HOME%\gradle-8.14\bin\gradle.bat" (
  if not exist "%GRADLE_HOME%" mkdir "%GRADLE_HOME%"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://services.gradle.org/distributions/gradle-8.14-all.zip -OutFile '%GRADLE_HOME%\gradle.zip'"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force '%GRADLE_HOME%\gradle.zip' '%GRADLE_HOME%'"
)
call "%GRADLE_HOME%\gradle-8.14\bin\gradle.bat" %*
endlocal
