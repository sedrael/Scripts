@echo off
:: =====================================================================
::  Настройка Microsoft Edge для работы с порталами в режиме Internet Explorer
::  + создание ярлыков на рабочем столе.
::
::  Запуск:  двойной щелчок (скрипт сам запросит права администратора)
::  Проверка без изменений в системе:  Edge_IE_Setup.bat /selftest
::
::  Что исправлено по сравнению с исходной версией:
::   1) Убрана несуществующая политика InternetExplorerIntegrationLocalSiteListReloadAllow
::      (в Edge такой политики нет; вместо неё - InternetExplorerIntegrationSiteListRefreshInterval).
::   2) <open-in>IE100</open-in> заменено на <open-in>IE11</open-in> - только это значение
::      документировано Microsoft и понимается Edge при InternetExplorerIntegrationLevel=1.
::   3) XML-список генерируется детерминированно и проверяется на корректность (well-formed).
::   4) Ярлыки создаются одним вызовом PowerShell с обработкой ошибок.
::   5) Добавлены проверки, лог, корректная работа с кодировкой (UTF-8), отчёт об ошибках.
::   6) Добавлена политика HttpAllowlist для vat.gov.by и e-respondent.belstat.gov.by.
::      У этих серверов https не работает с современным TLS (ошибка ERR_SSL_PROTOCOL_ERROR),
::      а Edge с версии 120 сам "улучшает" http-адрес до https и показывает ошибку.
::      HttpAllowlist запрещает такое автоулучшение, поэтому порталы открываются по http
::      в режиме IE. Именно поэтому ярлыки ЭСЧФ и Статистика указывают на http:// - это не опечатка.
::   7) Список сайтов режима IE задаётся переменными SITE1..SITE_COUNT и генерируется
::      в цикле. Новый сайт = одна строка set "SITE<n>=домен" + увеличить SITE_COUNT.
::      Wildcard *.domain писать НЕ нужно: документация Microsoft ("Don't use wildcards"),
::      а запись "domain" применяется и к поддоменам этого домена.
::   8) Добавлен раздел "Надёжные сайты" (Trusted Sites): переменные TS1..TS_COUNT
::      пишутся в HKCU ZoneMap\Domains (запись домена + подключ "*" для поддоменов,
::      проверено API MapUrlToZone - даёт зону 2) и отключается требование "только HTTPS"
::      для зоны 2 (иначе http-порталы в надёжной зоне блокируются).
::      Этот раздел не требует прав администратора (пишется в HKCU).
::   9) XML-список сайтов хранится в папке пользователя (%USERPROFILE%), а не в ProgramData.
::  10) Добавлены настройки зоны 2 "Надёжные сайты" (ActiveX и сценарии, HKCU Zones\2):
::      13 значений - 1200, 1201, 1208, 1209, 120A, 120B, 1001, 1004, 1405,
::      2000, 2201, 2702, 270C. Нужны для ЭЦП-плагинов (AvCMXWebP и др.)
::      на legacy-порталах. 0 = включить, 1 = предлагать, 3 = отключить.
::      Пишется в HKCU - права администратора не нужны.
::  11) Добавлены legacy-параметры IE/WinINET (HKCU, права администратора не нужны):
::      SecureProtocols = 2784 (0xAE0) в Internet Settings - набор протоколов для
::      IE-движка/WinINET (биты TLS 1.0/1.1/1.2 и 0x40, как в рекомендациях для IE);
::      DOMStorage = 1 и XMLHTTP = 1 в Internet Explorer\Main - включают localStorage
::      и XMLHTTP в старом движке IE (нужны старым порталам).
:: =====================================================================

chcp 65001 >nul 2>&1
setlocal EnableExtensions
title Настройка Edge: ярлыки и режим Internet Explorer
cd /d "%~dp0"

:: ---------------------------- параметры ------------------------------
set "POLICY_KEY=HKLM\SOFTWARE\Policies\Microsoft\Edge"
set "SITE_LIST=%USERPROFILE%\Edge_IE_Sites.xml"
set "LOG=%~dp0\edge-setup.log"
set "ERRORS=0"

:: Ярлыки: имена и адреса передаются в PowerShell через переменные среды,
:: чтобы не было проблем с кодировкой кириллицы и кавычек.
set "SC_COUNT=4"
set "SC1_NAME=ЭСЧФ"
set "SC1_URL=http://vat.gov.by/"
set "SC2_NAME=Статистика"
set "SC2_URL=http://e-respondent.belstat.gov.by/belstat/"
set "SC3_NAME=ФСЗН"
set "SC3_URL=https://portal2.ssf.gov.by/"
set "SC4_NAME=ИМНС"
set "SC4_URL=https://lkfl.portal.nalog.gov.by/en/eds1"

:: Сайты режима IE - их генерация в XML-список в подпрограмме :write_site_list.
:: ДОБАВЛЕНИЕ САЙТА: добавьте строку SITE<n>=домен (n = SITE_COUNT+1 и т.д.)
:: и увеличьте SITE_COUNT на 1. Wildcard "*.domain" не нужен - пишите просто домен:
:: запись "domain" покрывает и поддомены (Microsoft: "Don't use wildcards").
set "SITE_COUNT=5"
set "SITE1=e-respondent.belstat.gov.by"
set "SITE2=e-respondent.belstat.gov.by/belstat"
set "SITE3=portal2.ssf.gov.by"
set "SITE4=vat.gov.by"
set "SITE5=lkfl.portal.nalog.gov.by/en/eds1"

:: Надёжные сайты (Trusted Sites, зона 2) - запись в HKCU ZoneMap\Domains,
:: подпрограмма :add_trusted_sites. Права администратора не нужны.
:: ДОБАВЛЕНИЕ САЙТА: строка TS<n>=*.домен (n = TS_COUNT+1 и т.д.) + увеличить TS_COUNT.
:: "*." = домен и все его поддомены.
:: ДЛЯ КАЖДОЙ TS-ЗАПИСИ *.X пишется ОДИН канонический ключ (значение "*" = 2,
:: формат как в экспорте реестра рабочих систем, проверено API MapUrlToZone):
::   корень = "домен зоны": для *.X.gov.by - последние 3 метки (X.gov.by),
::   иначе последние 2 метки (*.oauth.uas.nces.by -> корень nces.by);
::   - если X == корень: значение "*"=2 на самом корне (ключи вида vat.gov.by);
::   - иначе подключ "*.<промежуточные метки>" (корень берётся целиком,
::     метки между ним и хостом - внутрь подключа, с точками):
::       *.portal.nalog.gov.by      -> nalog.gov.by\*.portal
::       *.e-respondent.belstat.gov.by -> belstat.gov.by\*.e-respondent
::       *.oauth.uas.nces.by        -> nces.by\*.oauth.uas
::       *.ssf.gov.by               -> ssf.gov.by ("*"=2 на корне)
:: Вложенные пути длиннее двух сегментов (nalog.gov.by\portal\lkfl) IE НЕ
:: распознаёт - глубокие поддомены (lkfl.portal.nalog.gov.by) как раз
:: покрывает подключ "*.<промежуточные метки>".
:: Обратный порядок меток (by\gov\...) тоже не работает: сайт в диалог
:: "Надёжные сайты - Сайты" не попадает и в зону 2 не назначается.
:: HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains
set "TS_COUNT=7"
set "TS1=*.vat.gov.by"
set "TS2=*.e-respondent.belstat.gov.by"
set "TS3=*.portal2.ssf.gov.by"
set "TS4=*.oauth.uas.nces.by"
set "TS5=*.lk-portal2.ssf.gov.by"
set "TS6=*.ssf.gov.by"
set "TS7=*.portal.nalog.gov.by"

:: ------------------------ режим самопроверки -------------------------
if /i "%~1"=="/selftest" goto selftest
if /i "%~1"=="/elevated" shift

:: --------------------------- права админа ----------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo Запрос прав администратора...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '/elevated %*' -Verb RunAs } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo Не удалось получить права администратора. Запустите файл от имени администратора вручную.
        pause
    )
    exit /b
)

echo.
echo ===================== Настройка Microsoft Edge =====================
call :log "=== Запуск: %DATE% %TIME% ==="

:: ------------------------- 1. поиск Edge -----------------------------
call :find_edge
if not defined EdgePath (
    set /a ERRORS+=1
    call :log "ОШИБКА: Microsoft Edge не найден в папках Program Files. Установите Edge и повторите."
    goto finish
)
call :log "Edge найден: %EdgePath%"
set "SHORTCUT_EDGE=%EdgePath%"

:: ------------------------- 2. ярлыки ---------------------------------
call :create_shortcuts

:: ------------------------- 3. список сайтов ---------------------------
call :write_site_list

:: ------------------------- 4. политики --------------------------------
call :apply_policies

:: ------------------------- 5. надёжные сайты --------------------------
call :add_trusted_sites
call :apply_zone2_activex

:: ------------------------- 6. параметры IE (WinINET) -------------------
call :apply_ie_legacy

:: ------------------------- 7. перезапуск Edge --------------------------
choice /C YNНТ /N /T 20 /D Y /M "Закрыть Microsoft Edge сейчас, чтобы применить настройки? (Y/N, через 20 сек - Y) "
if errorlevel 4 goto :skip 
if errorlevel 2 (
     if not errorlevel 3 goto :skip
) 
    taskkill /f /im msedge.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    call :log "Microsoft Edge закрыт."

:skip
call :log "Edge не закрыт. Настройки применятся после перезапуска браузера."

:finish
echo.
echo ============================== ИТОГ ===============================
if "%ERRORS%"=="0" (
    call :log "Готово. Ошибок нет."
) else (
    call :log "Готово. Ошибок: %ERRORS% - подробности в логе."
)
echo.
echo   Ярлыки:  ЭСЧФ, Статистика, ФСЗН, ИМНС - на рабочем столе
echo   Список сайтов режима IE:  %SITE_LIST%  (сайтов: %SITE_COUNT%)
echo   Надёжные сайты (Trusted Sites): %TS_COUNT% записей в HKCU ZoneMap\Domains
echo   ActiveX и сценарии для зоны 2: 13 значений (HKCU Zones\2)
echo   Параметры IE (WinINET): SecureProtocols=0xAE0, DOMStorage=1, XMLHTTP=1
echo   Проверить политики в Edge:  edge://policy
echo   Лог:  %LOG%
echo.
echo   ВАЖНО: ЭСЧФ и Статистика открываются по http:// (не по https).
echo   Их серверы не поддерживают https с современным TLS, поэтому в ярлыках указан http,
echo   а политика HttpAllowlist запрещает Edge автоматически переводить эти адреса на https.
echo.
echo   Если сайт открылся в обычном Edge (а не в режиме IE) - нажмите F5
echo   или откройте ярлык ещё раз: список сайтов читается при запуске браузера.
echo.
echo   Перезапустите Microsoft Edge, чтобы изменения вступили в силу.
echo ===================================================================
pause
exit /b


:: =====================================================================
::                           ПОДПРОГРАММЫ
:: =====================================================================

:: Логирование: пишет и в консоль, и в файл
:log
>>"%LOG%" echo [%DATE% %TIME%] %~1
echo    %~1
goto :eof


:: Поиск msedge.exe
:find_edge
set "EdgePath=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if exist "%EdgePath%" goto :eof
set "EdgePath=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if exist "%EdgePath%" goto :eof
set "EdgePath="
goto :eof


:: Создание ярлыков (один вызов PowerShell, имена берутся из переменных среды)
:create_shortcuts
call :log "Создание ярлыков на рабочем столе..."
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $d=$env:SHORTCUT_DESKTOP; if(-not $d){$d=[Environment]::GetFolderPath('Desktop')}; if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d | Out-Null }; $w=New-Object -ComObject WScript.Shell; $fail=@(); foreach($i in 1..[int]$env:SC_COUNT){ $n=[Environment]::GetEnvironmentVariable('SC'+[string]$i+'_NAME'); $u=[Environment]::GetEnvironmentVariable('SC'+[string]$i+'_URL'); try { $s=$w.CreateShortcut((Join-Path $d ($n+'.lnk'))); $s.TargetPath=$env:SHORTCUT_EDGE; $s.Arguments=$u; $s.Save() } catch { $fail+=$n } }; if($fail.Count -gt 0){ 'FAIL: ' + ($fail -join ', '); exit 1 } else { 'OK' }"
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: не удалось создать часть ярлыков."
) else (
    call :log "Ярлыки созданы: %SC_COUNT% шт."
)
goto :eof


:: Создание и проверка XML-списка сайтов для режима IE
:: XML собирается из переменных SITE1..SITE_COUNT
:write_site_list
call :log "Создание списка сайтов режима IE: %SITE_LIST% - сайтов: %SITE_COUNT%"
setlocal EnableDelayedExpansion
(
echo ^<?xml version="1.0" encoding="utf-8"?^>
echo ^<site-list version="1"^>
for /l %%i in (1,1,%SITE_COUNT%) do echo   ^<site url="!SITE%%i!"^>^<compat-mode^>IE11^</compat-mode^>^<open-in^>IE11^</open-in^>^</site^>
echo ^</site-list^>
) > "%SITE_LIST%"

if errorlevel 1 (
    endlocal
    set /a ERRORS+=1
    call :log "ОШИБКА: не удалось записать файл %SITE_LIST%"
    goto :eof
)
endlocal
if not exist "%SITE_LIST%" (
    set /a ERRORS+=1
    call :log "ОШИБКА: файл %SITE_LIST% не создан."
    goto :eof
)

:: проверка, что XML корректен и содержит элементы site
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $x=New-Object System.Xml.XmlDocument; $x.Load($env:SITE_LIST); $n=$x.SelectNodes('//site').Count; if($n -lt 1){ throw 'no <site> elements' }; 'OK: sites = ' + $n } catch { 'XML ERROR: ' + $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: список сайтов не прошёл проверку XML."
) else (
    call :log "Список сайтов создан и проверен."
)
goto :eof


:: Применение политик Edge
:apply_policies
call :log "Применение политик режима Internet Explorer..."

:: 1 = Internet Explorer mode (0 = выключено, 2 = отдельное приложение IE11)
call :regset "%POLICY_KEY%" InternetExplorerIntegrationLevel REG_DWORD 1
:: Путь к списку сайтов
call :regset "%POLICY_KEY%" InternetExplorerIntegrationSiteList REG_SZ "%SITE_LIST:\=/%"
:: Как часто Edge перечитывает список сайтов (минуты, минимум 30) - замена несуществующей политики
call :regset "%POLICY_KEY%" InternetExplorerIntegrationSiteListRefreshInterval REG_DWORD 60
:: Разрешить пользователям открывать неперечисленные сайты в режиме IE кнопкой "Перезагрузить в режиме IE"
call :regset "%POLICY_KEY%" InternetExplorerIntegrationReloadInIEModeAllowed REG_DWORD 1
:: Показывать кнопку режима IE на панели инструментов
call :regset "%POLICY_KEY%" InternetExplorerModeToolbarButtonEnabled REG_DWORD 1

:: Сайты, которые нельзя автоматически переводить с http на https (политика HttpAllowlist,
:: Edge 120+). У vat.gov.by и e-respondent.belstat.gov.by сервер не поддерживает https
:: с современным TLS, а Edge сам "улучшает" http-адрес до https и показывает
:: ERR_SSL_PROTOCOL_ERROR. HttpAllowlist отключает такое автоулучшение только для этих сайтов.
call :apply_http_allowlist

:: Чистка значения, которое писала старая версия скрипта: политики с таким именем в Edge нет
reg delete "%POLICY_KEY%" /v InternetExplorerIntegrationLocalSiteListReloadAllow /f >nul 2>&1

goto :eof


:: Исключения авто-перехода http на https (политика HttpAllowlist)
:apply_http_allowlist
call :log "Исключения автоматического перехода http на https..."
reg add "%POLICY_KEY%\HttpAllowlist" /v 1 /t REG_SZ /d "vat.gov.by" /f >nul 2>&1
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: HttpAllowlist\1 не применён"
) else (
    call :log "OK: HttpAllowlist\1 = vat.gov.by"
)
reg add "%POLICY_KEY%\HttpAllowlist" /v 2 /t REG_SZ /d "e-respondent.belstat.gov.by" /f >nul 2>&1
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: HttpAllowlist\2 не применён"
) else (
    call :log "OK: HttpAllowlist\2 = e-respondent.belstat.gov.by"
)
goto :eof


:: Добавление сайтов в зону "Надёжные сайты" (Trusted Sites, зона 2)
:: Для каждой TS-записи *.X пишется один HKCU\...\ZoneMap\Domains-ключ
:: со значением "*" = 2 (канонический макет, как в экспорте реестра):
::   корень = домен зоны (*.X.gov.by -> последние 3 метки, иначе последние 2);
::   X == корень -> значение "*" на самом корне (vat.gov.by, ssf.gov.by),
::   иначе - подключ "*.<промежуточные метки>" (nalog.gov.by\*.portal,
::   nces.by\*.oauth.uas и т.д.) - покрывает поддомены любой глубины.
:: Ключи создаются через .NET Registry API, чтобы "*" с звёздочкой
:: не трактовалось как маска пути.
:: Проверено MapUrlToZone: голые домены, www.- и глубокие поддомены
:: (lkfl.portal.nalog.gov.by) = зона 2, посторонние домены = зона 1.
:: Также отключается требование "только HTTPS" для зоны 2 (Zones\2\2200 = 3),
:: иначе Edge блокирует http-сайты даже в надёжной зоне.
:add_trusted_sites
call :log "Надёжные сайты: добавление %TS_COUNT% записей в ZoneMap (HKCU)..."
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $base='Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains'; $rk=[Microsoft.Win32.Registry]::CurrentUser; $dk=$rk.CreateSubKey($base); $dk.SetValue('',[string]::Empty,[Microsoft.Win32.RegistryValueKind]::String); $dk.Close(); $n=[int]$env:TS_COUNT; $added=0; for($i=1;$i -le $n;$i++){ $e=[Environment]::GetEnvironmentVariable('TS'+$i); if(-not $e){continue}; $d=$e; if($d.StartsWith('*.')){$d=$d.Substring(2)}; $a=$d.Split('.'); if($a.Count -lt 2){ continue }; $rc=2; if($d.EndsWith('.gov.by') -and $a.Count -ge 3){$rc=3}; $root=($a[($a.Count-$rc)..($a.Count-1)] -join '.'); if($a.Count -eq $rc){ $rel=$root } else { $rel=$root+'\*.'+($a[0..($a.Count-$rc-1)] -join '.') }; $k=$rk.CreateSubKey($base+'\'+$rel); if($k -eq $null){ throw ('cannot create '+$rel) }; $k.SetValue('*',2,[Microsoft.Win32.RegistryValueKind]::DWord); $k.Close(); $added++ }; $zk=$rk.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\2'); $zk.SetValue('2200',3,[Microsoft.Win32.RegistryValueKind]::DWord); $zk.Close(); if($added -ne $n){ 'FAIL: added '+$added+' of '+$n; exit 1 }; 'OK: trusted sites = '+$added+' (1 key each)'"
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: не удалось добавить надёжные сайты"
) else (
    call :log "Надёжные сайты: %TS_COUNT% записей добавлено, зона 2: требование HTTPS-only отключено"
)
goto :eof


:: Настройки зоны 2 "Надёжные сайты": ActiveX и сценарии (HKCU, права админа не нужны).
:: Нужны для ЭЦП-плагинов (AvCMXWebP и др.), которые используют ActiveX на legacy-порталах.
:: Значения: 0 = включить, 1 = предлагать, 3 = отключить.
:apply_zone2_activex
call :log "Надёжные сайты: настройки ActiveX и сценариев для зоны 2 (HKCU)..."
set "Z2=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\2"

:: 1201 - Инициализация и сценарии элементов ActiveX, не помеченных как безопасные
call :regset_z2 1201 0 "инициализация и сценарии непомеченных ActiveX"
:: 2702 - Разрешить фильтрацию ActiveX
call :regset_z2 2702 3 "фильтрация ActiveX отключена"
:: 1200 - Запуск элементов ActiveX и модулей подключения
call :regset_z2 1200 0 "запуск ActiveX и модулей подключения"
:: 1405 - Выполнять сценарии элементов ActiveX, помеченные как безопасные
call :regset_z2 1405 0 "сценарии безопасных ActiveX"
:: 270C - Запускать антивредоносное ПО для элементов управления ActiveX
call :regset_z2 270C 0 "антивредоносная проверка ActiveX"
:: 2000 - Поведение двоичного кода и сценариев
call :regset_z2 2000 0 "поведение двоичного кода и сценариев"
:: 120A - Заменять ограничения на элементы ActiveX для отдельных сайтов
call :regset_z2 120A 0 "замена ограничений ActiveX для сайтов"
:: 120B - Переопределить ограничения на элементы ActiveX для отдельных сайтов
call :regset_z2 120B 0 "переопределение ограничений ActiveX для сайтов"
:: 1208 - Разрешить запуск элементов управления ActiveX, которые не использовались
call :regset_z2 1208 0 "запуск неиспользовавшихся ActiveX"
:: 1209 - Разрешить скриптлеты
call :regset_z2 1209 0 "разрешить скриптлеты"
:: 1004 - Скачивание неподписанных элементов ActiveX
call :regset_z2 1004 0 "скачивание неподписанных ActiveX"
:: 1001 - Скачивание подписанных элементов ActiveX
call :regset_z2 1001 0 "скачивание подписанных ActiveX"
:: 2201 - Автоматические запросы элементов управления ActiveX
call :regset_z2 2201 0 "автоматические запросы ActiveX"

goto :eof


:: Установка одного значения зоны 2 с проверкой результата
:: вызов: call :regset_z2 <имя> <значение> <описание>
:regset_z2
reg add "%Z2%" /v "%~1" /t REG_DWORD /d %~2 /f >nul 2>&1
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: зона 2, %~1 = %~2 (%~3) не применено"
) else (
    call :log "OK: зона 2, %~1 = %~2 (%~3)"
)
goto :eof


:: Legacy-параметры IE/WinINET (HKCU, права администратора не нужны).
:: SecureProtocols = 2784 (0xAE0) - набор протоколов TLS для IE-движка и WinINET;
:: DOMStorage/XMLHTTP = 1 - включают localStorage и XMLHTTP в старом движке IE.
:apply_ie_legacy
call :log "Параметры IE (WinINET): SecureProtocols, DOMStorage, XMLHTTP..."
set "IE_MAIN=HKCU\Software\Microsoft\Internet Explorer\Main"
call :regset_ie "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" SecureProtocols 2784 "0xAE0 - протоколы TLS 1.0/1.1/1.2"
call :regset_ie "%IE_MAIN%" DOMStorage 1 "включить DOM Storage в IE-движке"
call :regset_ie "%IE_MAIN%" XMLHTTP 1 "включить XMLHTTP в IE-движке"
goto :eof


:: Установка одного DWORD-значения с проверкой результата
:: вызов: call :regset_ie <ключ> <имя> <значение> <описание>
:regset_ie
reg add "%~1" /v "%~2" /t REG_DWORD /d %~3 /f >nul 2>&1
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: %~2 = %~3 (%~4) не применено"
) else (
    call :log "OK: %~2 = %~3 (%~4)"
)
goto :eof


:: Установка одного значения политики с проверкой результата
:: вызов: call :regset <ключ> <имя> <тип> <значение>
:regset
reg add "%~1" /v "%~2" /t %~3 /d "%~4" /f >nul 2>&1
if errorlevel 1 (
    set /a ERRORS+=1
    call :log "ОШИБКА: политика %~2 не применена"
) else (
    call :log "OK: %~2 = %~4"
)
goto :eof


:: =====================================================================
::  РЕЖИМ ПРОВЕРКИ: ничего в системе не меняет, показывает, что будет сделано
:: =====================================================================
:selftest
echo.
echo ==== РЕЖИМ ПРОВЕРКИ /selftest: изменения в систему не вносятся ====
echo.
set "SITE_LIST=%TEMP%\Edge_IE_Sites.selftest.xml"
set "SHORTCUT_DESKTOP=%TEMP%\edge-selftest-desktop"

call :find_edge
if defined EdgePath goto :st_edge_ok
echo [!!] Edge не найден - установите Microsoft Edge
goto :st_edge_done
:st_edge_ok
echo [OK] Edge: "%EdgePath%"
:st_edge_done
set "SHORTCUT_EDGE=%EdgePath%"
if not defined SHORTCUT_EDGE set "SHORTCUT_EDGE=%SystemRoot%\notepad.exe"

call :write_site_list
echo.
echo ---- Сгенерированный XML ----
type "%SITE_LIST%"
echo -----------------------------

call :create_shortcuts
if exist "%SHORTCUT_DESKTOP%" (
    echo ---- Созданные ярлыки ----
    dir /b "%SHORTCUT_DESKTOP%"
    rmdir /s /q "%SHORTCUT_DESKTOP%"
)

del /q "%SITE_LIST%" >nul 2>&1

echo.
echo ---- Политики, которые будут записаны в %POLICY_KEY% ----
echo   InternetExplorerIntegrationLevel                    = 1    - Internet Explorer mode
echo   InternetExplorerIntegrationSiteList                 = путь к Edge_IE_Sites.xml в папке пользователя
echo   InternetExplorerIntegrationSiteListRefreshInterval  = 60   - минут
echo   InternetExplorerIntegrationReloadInIEModeAllowed    = 1
echo   InternetExplorerModeToolbarButtonEnabled            = 1
echo   HttpAllowlist\1                                      = vat.gov.by                - не улучшать http до https
echo   HttpAllowlist\2                                      = e-respondent.belstat.gov.by - не улучшать http до https
echo   InternetExplorerIntegrationLocalSiteListReloadAllow  будет удалено - такой политики нет
echo.
echo ---- Надёжные сайты, которые будут добавлены (HKCU ZoneMap\Domains, зона 2) ----
setlocal EnableDelayedExpansion
for /l %%i in (1,1,%TS_COUNT%) do echo   !TS%%i!  -^> канонический ключ: корень зоны + *.промежуточные метки, значение "*", зона 2
endlocal
echo   Zones\2\2200 (только HTTPS для надёжных сайтов)    = 3    - отключено, иначе http блокируется
echo.
echo ---- Зона 2 "Надёжные сайты": ActiveX и сценарии (HKCU Zones\2, 13 значений) ----
echo   1200=0  1201=0  1208=0  1209=0  120A=0  120B=0  1001=0  1004=0  1405=0  2000=0  2201=0  2702=3  270C=0
echo   (0 = включить, 1 = предлагать, 3 = отключить)
echo.
echo ---- Параметры IE / WinINET (HKCU, 3 значения) ----
echo   Internet Settings\SecureProtocols = 2784 (0xAE0)  - протоколы TLS для IE-движка
echo   Internet Explorer\Main\DOMStorage = 1
echo   Internet Explorer\Main\XMLHTTP    = 1
echo.
echo   Ярлыки:
echo     ЭСЧФ        -^> http://vat.gov.by/
echo     Статистика  -^> http://e-respondent.belstat.gov.by/belstat/
echo     ФСЗН        -^> https://portal2.ssf.gov.by/
echo     ИМНС        -^> https://lkfl.portal.nalog.gov.by/en/eds1
echo.
if "%ERRORS%"=="0" (echo [OK] Проверка пройдена, ошибок нет.) else (echo [!!] Ошибок: %ERRORS%)
exit /b
