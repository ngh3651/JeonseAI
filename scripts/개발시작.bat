@echo off
rem 전세AI프 개발 한 번에 켜기 — 더블클릭. 자세한 건 dev-start.ps1 맨 위 설명.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev-start.ps1"
pause
