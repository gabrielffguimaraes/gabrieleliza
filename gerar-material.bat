@echo off
chcp 65001 >nul
title Gerador de Material - Gabriel & Liza
echo ===========================================
echo  Gerador de Material - Gabriel ^& Liza
echo  Gerando imagem e PDFs do site...
echo  (pode levar 1 a 2 minutos)
echo ===========================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gerar-material.ps1"
echo.
pause