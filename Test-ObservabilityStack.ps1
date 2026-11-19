#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test stosu: usługi, gotowość, przepływ OTLP end-to-end (trace -> Tempo, log -> Loki, metryka -> Prometheus)
    oraz obecność danych z WEBCON.

.EXAMPLE
    .\Test-ObservabilityStack.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Observability',
    [string]$OtlpHttp = 'http://127.0.0.1:4318',
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking

$fail = 0
function Fail([string]$m) { Write-Warn $m; $script:fail++ }

function New-HexId([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Invoke-Json([string]$Uri, $Body) {
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 10 | Out-Null
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ---------------------------------------------------------------------
Write-Step 'Wersja'
$installed = Get-InstallSettings -Root $Root
$testRelease = $null
try { $testRelease = Get-StackRelease -SourceRoot $PSScriptRoot } catch { }
if ($installed -and $installed.StackVersion) {
    $commitText = ''
    if ($installed.StackCommit) { $commitText = " ($($installed.StackCommit))" }
    $when = $installed.InstalledAt
    if ($when -is [datetime]) { $when = $when.ToString('yyyy-MM-dd HH:mm') }
    Write-Ok "Wersja stosu: $($installed.StackVersion)$commitText, zainstalowana $when"
    if ($testRelease -and $testRelease.Version -ne $installed.StackVersion) {
        Write-Warn "Test z innej wersji ($($testRelease.Version)) - użyj $(Join-Path $Root 'app')\Test-ObservabilityStack.ps1"
    }
} elseif ($installed) {
    Write-Info 'Wersja stosu: instalacja sprzed wydań (bez numeru wersji)'
} else {
    Write-Info "Brak $Root\config\install-settings.json"
}

# ---------------------------------------------------------------------
Write-Step 'Usługi'
foreach ($id in 'obs-prometheus', 'obs-loki', 'obs-tempo', 'obs-alloy', 'obs-grafana') {
    $s = Get-Service -Name $id -ErrorAction SilentlyContinue
    if (-not $s) { Fail "$id - brak usługi" }
    elseif ($s.Status -ne 'Running') { Fail "$id - status $($s.Status)" }
    else { Write-Ok "$id - Running" }
}

Write-Step 'Gotowość'
$ready = [ordered]@{
    Prometheus = 'http://127.0.0.1:9090/-/ready'
    Loki       = 'http://127.0.0.1:3100/ready'
    Tempo      = 'http://127.0.0.1:3200/ready'
    Alloy      = 'http://127.0.0.1:12345/-/ready'
    Grafana    = 'http://127.0.0.1:3000/api/health'
}
foreach ($k in $ready.Keys) {
    if (Wait-HttpReady -Url $ready[$k] -TimeoutSec 10) { Write-Ok $k; continue }
    # Loki: pattern ingester (wzorce logów w Grafana Logs Drilldown) bywa "not ready" długo po starcie (zaobserwowane ~2 h),
    # choć przyjmowanie i odczyt logów działają - te sprawdza test end-to-end niżej
    $body = ''
    try { $null = Invoke-WebRequest $ready[$k] -UseBasicParsing -TimeoutSec 5 } catch { $body = "$($_.ErrorDetails.Message)" }
    if ($k -eq 'Loki' -and $body -match 'Pattern Ingester') {
        Write-Warn "Loki: pattern ingester jeszcze nie gotowy ($($body.Trim())) - wzorce logów chwilowo niedostępne"
    } else { Fail "$k nie odpowiada ($($ready[$k]))" }
}

# ---------------------------------------------------------------------
Write-Step 'Przepływ OTLP end-to-end'
$traceId = New-HexId 16
$spanId  = New-HexId 8
$nowNs   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000
$resource = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'obs-smoketest' } }) }

try {
    Invoke-Json "$OtlpHttp/v1/traces" @{ resourceSpans = @(@{ resource = $resource; scopeSpans = @(@{
        scope = @{ name = 'smoketest' }
        # webcon.db.cs: atrybut z sekretem, który Alloy musi usunąć (otelcol.processor.attributes "webcon_secrets")
        # webcon.path.id na "workflow.execute": Alloy zmienia nazwę na webcon.workflow.path.id (otelcol.processor.transform "webcon_cardinality")
        spans = @(@{ traceId = $traceId; spanId = $spanId; name = 'smoketest'; kind = 2
                     startTimeUnixNano = [string]($nowNs - 50000000); endTimeUnixNano = [string]$nowNs
                     attributes = @(@{ key = 'webcon.db.cs'; value = @{ stringValue = 'Data Source=smoketest' } }) },
                  @{ traceId = $traceId; spanId = (New-HexId 8); parentSpanId = $spanId; name = 'webcon.elements_management.workflow.execute'; kind = 1
                     startTimeUnixNano = [string]($nowNs - 40000000); endTimeUnixNano = [string]($nowNs - 10000000)
                     attributes = @(@{ key = 'webcon.path.id'; value = @{ intValue = '1' } }) })
    }) }) }
    # Kopia logu z zasobem "unknown_service:WebCon.*" - Alloy musi ją odrzucić (otelcol.processor.filter "webcon_log_duplicates")
    $dupResource = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'unknown_service:WebCon.Smoketest.exe' } }) }
    Invoke-Json "$OtlpHttp/v1/logs" @{ resourceLogs = @(@{ resource = $dupResource; scopeLogs = @(@{
        scope = @{ name = 'smoketest' }
        logRecords = @(@{ timeUnixNano = [string]$nowNs; severityText = 'INFO'; severityNumber = 9
                          body = @{ stringValue = "smoketest duplicate $traceId" }; traceId = $traceId; spanId = $spanId })
    }) }) }
    Invoke-Json "$OtlpHttp/v1/logs" @{ resourceLogs = @(@{ resource = $resource; scopeLogs = @(@{
        scope = @{ name = 'smoketest' }
        logRecords = @(@{ timeUnixNano = [string]$nowNs; severityText = 'INFO'; severityNumber = 9
                          body = @{ stringValue = "smoketest $traceId" }; traceId = $traceId; spanId = $spanId })
    }) }) }
    Invoke-Json "$OtlpHttp/v1/metrics" @{ resourceMetrics = @(@{ resource = $resource; scopeMetrics = @(@{
        scope = @{ name = 'smoketest' }
        metrics = @(@{ name = 'obs_smoketest_value'; gauge = @{ dataPoints = @(@{ asDouble = 1; timeUnixNano = [string]$nowNs }) } })
    }) }) }
    Write-Ok "Wysłano trace/log/metrykę testową (traceId $traceId)"
} catch {
    Fail "Wysyłka OTLP do $OtlpHttp nie powiodła się: $($_.Exception.Message)"
}

$traceJson = $null
if (Wait-Until {
        $script:traceJson = (Invoke-WebRequest "http://127.0.0.1:3200/api/traces/$traceId" -UseBasicParsing -TimeoutSec 5).Content
        $script:traceJson -match 'smoketest'
    } $TimeoutSec) {
    Write-Ok 'Tempo: ślad testowy odnaleziony'
    if ($traceJson -match 'webcon\.db\.cs') { Fail 'Tempo: atrybut webcon.db.cs (dane połączenia z bazą) NIE został usunięty przez Alloy' }
    else { Write-Ok 'Tempo: atrybut webcon.db.cs usunięty' }
    if ($traceJson -match '"webcon\.path\.id"' -or $traceJson -notmatch '"webcon\.workflow\.path\.id"') {
        Fail 'Tempo: webcon.path.id na spanie workflow.execute NIE został przemianowany na webcon.workflow.path.id'
    } else { Write-Ok 'Tempo: webcon.path.id na workflow.execute przemianowany (kardynalność spanmetrics)' }
} else { Fail 'Tempo: brak śladu testowego' }

# TraceQL metrics po (prawie) całym zakresie dashboardu WEBCON – Utrzymanie. Uszkodzony indeks bloków Tempo (rozmiar bloku
# różny od pliku data.parquet) psuje każde zapytanie obejmujące blok: "reading parquet file metadata: missing required field".
# 166 h: Tempo wyrównuje zakres do kroku, a limit to query_frontend.metrics.max_duration = 169h.
$endS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$metricsQuery = [Uri]::EscapeDataString('{ } | count_over_time()')
try {
    $null = Invoke-RestMethod "http://127.0.0.1:3200/api/metrics/query_range?q=$metricsQuery&start=$($endS - 166 * 3600)&end=$endS&step=3600" -TimeoutSec 60
    Write-Ok 'Tempo: TraceQL metrics (7 dni)'
} catch {
    $msg = "$($_.ErrorDetails.Message)"
    if (-not $msg) { $msg = $_.Exception.Message }
    if ($msg -match 'parquet') { Fail "Tempo: TraceQL metrics - $($msg.Trim()). Uszkodzony indeks bloków - naprawa: README, sekcja Diagnostyka" }
    else { Fail "Tempo: TraceQL metrics - $($msg.Trim())" }
}

$startNs = $nowNs - 600000000000
$lokiQuery = [Uri]::EscapeDataString('{service_name="obs-smoketest"}')
if (Wait-Until {
        $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query_range?query=$lokiQuery&start=$startNs&limit=50" -TimeoutSec 5
        @($r.data.result).Count -gt 0
    } $TimeoutSec) {
    Write-Ok 'Loki: log testowy odnaleziony'
    # Log właściwy już jest, więc kopia (wysłana w tym samym żądaniu) też byłaby już widoczna
    $dupQuery = [Uri]::EscapeDataString('{service_name=~"unknown_service:WebCon.+"} |= "' + $traceId + '"')
    $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query_range?query=$dupQuery&start=$startNs&limit=5" -TimeoutSec 5
    if (@($r.data.result).Count -gt 0) { Fail 'Loki: kopia logu unknown_service:WebCon.* NIE została odrzucona' }
    else { Write-Ok 'Loki: kopia logu unknown_service:WebCon.* odrzucona' }
} else { Fail 'Loki: brak logu testowego' }

if (Wait-Until {
        $r = Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/query?query=obs_smoketest_value' -TimeoutSec 5
        @($r.data.result).Count -gt 0
    } $TimeoutSec) {
    Write-Ok 'Prometheus: metryka testowa odnaleziona'
} else { Fail 'Prometheus: brak metryki testowej' }

# ---------------------------------------------------------------------
Write-Step 'Dane z WEBCON i hosta (informacyjnie)'
function Get-PromCount([string]$Query) {
    try {
        $r = Invoke-RestMethod ("http://127.0.0.1:9090/api/v1/query?query=" + [Uri]::EscapeDataString($Query)) -TimeoutSec 5
        # przecinek: bez niego PS 5.1 rozwija jednoelementową tablicę do PSCustomObject (brak .Count)
        return ,@($r.data.result)
    } catch { return ,@() }
}
$jobs = Get-PromCount 'count by (job) (target_info)'
if ($jobs.Count) { $jobs | ForEach-Object { Write-Ok "OTLP źródło: $($_.metric.job)" } } else { Write-Warn 'Brak usług wysyłających metryki OTLP (target_info) - skonfiguruj WEBCON (scripts\Set-WebconTelemetry.ps1).' }
if ((Get-PromCount 'count({__name__=~"webcon_.+"})').Count) { Write-Ok 'Metryki webcon_* obecne' } else { Write-Warn 'Brak metryk webcon_*' }
# Stałe nazwy usług WEBCON (Portal / WebCon.WorkFlow) - docs/projekt/projekt-nazwy-uslug-webcon.md
$odd = Get-PromCount 'count by (job) (target_info{job=~"(?i).*webcon.*",job!~"Portal|WebCon[.]WorkFlow"})'
foreach ($j in $odd) {
    Write-Warn "Usługa WEBCON o niestandardowej nazwie '$($j.metric.job)' - dashboardy i alerty jej nie widzą. Uruchom scripts\Set-WebconTelemetry.ps1 (znacznik webcon.component) albo instalator z -WebconPortalServiceName / -WebconServiceServiceName."
}
$noTag = Get-PromCount 'count by (job) (target_info{job=~"Portal|WebCon[.]WorkFlow",webcon_component=""})'
foreach ($j in $noTag) {
    Write-Warn "$($j.metric.job): telemetria bez znacznika webcon.component - nazwa z appsettings / mapowania po nazwie; uruchom scripts\Set-WebconTelemetry.ps1."
}
if ((Get-PromCount 'target_info{job=~"Portal|WebCon[.]WorkFlow",webcon_component!=""}').Count -and -not $odd.Count) {
    Write-Ok 'Nazwy usług WEBCON znormalizowane (webcon.component)'
}
if ((Get-PromCount 'up{job="integrations/windows"} == 1').Count) { Write-Ok 'windows_exporter: up' } else { Fail 'windows_exporter: brak danych' }
$mssql = Get-PromCount 'up{job="integrations/mssql"}'
if ($mssql.Count) {
    if ($mssql[0].value[1] -eq '1') {
        Write-Ok 'mssql exporter: up'
        # metryka z rozszerzonego query_config (mssql-queries.yaml)
        if ((Get-PromCount 'mssql_wait_time_seconds_total').Count) { Write-Ok 'mssql: rozszerzone metryki (mssql-queries.yaml) obecne' }
        else { Fail 'mssql: brak rozszerzonych metryk (mssql_wait_time_seconds_total) - sprawdź mssql-queries.yaml' }
    } else { Fail 'mssql exporter: down (sprawdź login / logi Alloy)' }
} else { Write-Info 'mssql exporter: nie skonfigurowany' }

# Metryki z bazy treści WEBCON (docs/projekt/projekt-dostepnosc-i-metryki-bazy.md) - brak uprawnień = ostrzeżenie (D5)
$webconDb = Get-PromCount 'up{job="integrations/mssql-webcon"}'
if ($webconDb.Count) {
    $dbMetrics = Get-PromCount 'count by (__name__) ({__name__=~"webcon_db_.+"})'
    if ($webconDb[0].value[1] -eq '1' -and $dbMetrics.Count -ge 4) { Write-Ok "Metryki z bazy WEBCON: $($dbMetrics.Count) metryk webcon_db_*" }
    elseif ($webconDb[0].value[1] -eq '1') { Write-Warn "Metryki z bazy WEBCON: $($dbMetrics.Count) z 4 metryk - brak uprawnień kolumnowych? DBA: sql\grant-webcon-db-metrics.sql" }
    else { Write-Warn 'Metryki z bazy WEBCON: exporter down - uprawnienia (sql\grant-webcon-db-metrics.sql) / Dziennik zdarzeń, źródło Alloy' }
} else { Write-Info 'Metryki z bazy WEBCON: nie skonfigurowane (-WebconDbMetrics $true)' }

# Sondy dostępności (Portal z powiązań IIS, -ProbeUrl)
$probes = Get-PromCount 'probe_success{job="integrations/blackbox"}'
foreach ($p in $probes) {
    $code = Get-PromCount "probe_http_status_code{job=`"integrations/blackbox`",instance=`"$($p.metric.instance)`"}"
    $codeText = ''
    if ($code.Count) { $codeText = " (HTTP $($code[0].value[1]))" }
    if ($p.value[1] -eq '1') { Write-Ok "Dostępność ($($p.metric.probe)): $($p.metric.instance)$codeText" }
    else { Fail "Dostępność ($($p.metric.probe)): $($p.metric.instance) niedostępny$codeText" }
}
if (-not $probes.Count) { Write-Info 'Sondy dostępności: brak (Portal nie wykryty w IIS, -PortalProbe $false lub tryb zdalny bez agenta WEBCON)' }

# Źródło danych Grafany "WEBCON SQL" (dashboard WEBCON – Utrzymanie) - health check przez API Grafany
$settings = Get-InstallSettings -Root $Root
if ($settings -and $settings.WebconSqlReaderLogin) {
    $adminPwd = $null
    try { $adminPwd = [IO.File]::ReadAllText((Join-Path $Root 'secrets\grafana-admin.txt'), [Text.Encoding]::UTF8) } catch { }
    if ($adminPwd) {
        $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPwd"))
        try {
            $h = Invoke-RestMethod 'http://127.0.0.1:3000/api/datasources/uid/webcon-sql/health' -Headers @{ Authorization = $auth } -TimeoutSec 20
            if ($h.status -eq 'OK') { Write-Ok "Grafana: źródło 'WEBCON SQL' odpowiada" } else { Fail "Grafana: źródło 'WEBCON SQL' - $($h.message)" }
        } catch {
            Fail "Grafana: źródło 'WEBCON SQL' - $($_.Exception.Message) (sprawdź sql\grant-webcon-reader-permissions.sql i sekret grafana-sql-reader.txt)"
        }
    } else { Write-Info "Grafana: źródło 'WEBCON SQL' nie sprawdzone - brak dostępu do hasła admina (uruchom jako administrator)" }
} else { Write-Info "Grafana: źródło 'WEBCON SQL' nie skonfigurowane" }

# ---------------------------------------------------------------------
# Tryb zdalny: dane od agentów na hostach WEBCON / SQL (Install-ObservabilityAgent.ps1 z paczki agent-bundle)
if ($settings -and ($settings.WebconHost -or $settings.SqlHost)) {
    Write-Step 'Agenci zdalni'
    foreach ($h in (@($settings.SqlHost, $settings.WebconHost) | Where-Object { $_ } | Select-Object -Unique)) {
        $short = $h.Split('.')[0]
        if ((Get-PromCount "windows_os_info{instance=~`"(?i)$short([.].*)?`"}").Count) { Write-Ok "$h - metryki hosta (windows_exporter)" }
        else { Fail "$h - brak metryk hosta: agent nie zainstalowany albo brak łączności (skrypty z $Root\agent-bundle)" }
    }
    if ($settings.SqlHost -and -not $mssql.Count) { Fail "$($settings.SqlHost) - brak metryk mssql (rola Sql agenta)" }
    if ($settings.WebconHost) {
        if ((Get-PromCount 'target_info{job=~"Portal|WebCon.WorkFlow"}').Count) { Write-Ok "$($settings.WebconHost) - telemetria WEBCON (Portal / Serwis)" }
        else { Write-Warn "$($settings.WebconHost) - brak telemetrii WEBCON (Set-WebconTelemetry.ps1 w roli Webcon; metryki co 60 s)" }
    }
    $agentQuery = [Uri]::EscapeDataString('sum by (host_name) (count_over_time({service_name="obs-agent-test"}[7d]))')
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query?query=$agentQuery" -TimeoutSec 10
        $agentHosts = @($r.data.result | ForEach-Object { $_.metric.host_name })
        if ($agentHosts.Count) { Write-Ok "Log testowy agenta (OTLP przez agenta) z: $($agentHosts -join ', ')" }
        else { Fail 'Brak logu testowego agenta (service_name="obs-agent-test") z ostatnich 7 dni' }
    } catch { Fail "Loki: zapytanie o log testowy agenta - $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------
# Alerty Grafany (provisioning\alerting, docs/projekt/projekt-alerty.md)
Write-Step 'Alerty'
$adminPwd = $null
try { $adminPwd = [IO.File]::ReadAllText((Join-Path $Root 'secrets\grafana-admin.txt'), [Text.Encoding]::UTF8) } catch { }
if ($adminPwd) {
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPwd"))
    try {
        # Invoke-WebRequest + jawne UTF-8: Invoke-RestMethod w PS 5.1 psuje polskie znaki w nazwach reguł
        $raw = (Invoke-WebRequest 'http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules' -Headers @{ Authorization = $auth } -UseBasicParsing -TimeoutSec 20).RawContentStream.ToArray()
        $rules = @(([Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json).data.groups | ForEach-Object { $_.rules })
        if ($rules.Count) { Write-Ok "Reguły alertów załadowane: $($rules.Count)" } else { Fail 'Brak reguł alertów - sprawdź config\grafana\provisioning\alerting i log Grafany (Failed to provision alerting)' }
        # Błąd sprzed startu Grafany = stan odtworzony z bazy ("Warming state cache"), np. z oceny reguł w trakcie
        # zatrzymywania stosu - nie jest bieżącym problemem; Grafana oceni regułę ponownie w ciągu interwału (1 min).
        $grafanaStart = Get-Process -Name 'grafana', 'grafana-server' -ErrorAction SilentlyContinue |
            Sort-Object StartTime | Select-Object -First 1 -ExpandProperty StartTime
        $restored = 0
        foreach ($rule in $rules | Where-Object { $_.health -eq 'error' }) {
            $lastEval = $null
            if ($rule.lastEvaluation -is [datetime]) { $lastEval = $rule.lastEvaluation.ToLocalTime() }
            else { try { $lastEval = ([DateTimeOffset]::Parse([string]$rule.lastEvaluation, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { } }
            if ($grafanaStart -and $lastEval -and $lastEval -lt $grafanaStart) { $restored++ }
            else { Fail "Alert '$($rule.name)': błąd ewaluacji - $($rule.lastError)" }
        }
        if ($restored) { Write-Info "Alerty: $restored reguł z błędem sprzed restartu Grafany (stan odtworzony, jeszcze nie oceniony ponownie) - powtórz test za 1 min" }
        foreach ($rule in $rules | Where-Object { $_.state -eq 'firing' }) {
            $what = @($rule.alerts | Where-Object { $_.state -eq 'Alerting' } | ForEach-Object { $_.annotations.summary }) -join '; '
            Write-Warn "Alert aktywny: $($rule.name) - $what"
        }
        if (-not @($rules | Where-Object { $_.state -eq 'firing' }).Count) { Write-Ok 'Brak aktywnych alertów' }
    } catch { Fail "Grafana: lista reguł alertów - $($_.Exception.Message)" }
} else { Write-Info 'Alerty nie sprawdzone - brak dostępu do hasła admina Grafany (uruchom jako administrator)' }

Write-Host ''
if ($fail -gt 0) { Write-Host "Wynik: $fail problem(ów)" -ForegroundColor Yellow; exit 1 }
Write-Host 'Wynik: OK' -ForegroundColor Green
