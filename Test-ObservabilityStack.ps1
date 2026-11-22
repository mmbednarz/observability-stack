#Requires -Version 5.1
<#
.SYNOPSIS
    Stack smoke test: services, readiness, end-to-end OTLP flow (trace -> Tempo, log -> Loki, metric -> Prometheus)
    and presence of WEBCON data.

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
Write-Step 'Version'
$installed = Get-InstallSettings -Root $Root
$testRelease = $null
try { $testRelease = Get-StackRelease -SourceRoot $PSScriptRoot } catch { }
if ($installed -and $installed.StackVersion) {
    $commitText = ''
    if ($installed.StackCommit) { $commitText = " ($($installed.StackCommit))" }
    $when = $installed.InstalledAt
    if ($when -is [datetime]) { $when = $when.ToString('yyyy-MM-dd HH:mm') }
    Write-Ok "Stack version: $($installed.StackVersion)$commitText, installed $when"
    if ($testRelease -and $testRelease.Version -ne $installed.StackVersion) {
        Write-Warn "Test from a different version ($($testRelease.Version)) - use $(Join-Path $Root 'app')\Test-ObservabilityStack.ps1"
    }
} elseif ($installed) {
    Write-Info 'Stack version: installation predates releases (no version number)'
} else {
    Write-Info "$Root\config\install-settings.json not found"
}

# ---------------------------------------------------------------------
Write-Step 'Services'
foreach ($id in 'obs-prometheus', 'obs-loki', 'obs-tempo', 'obs-alloy', 'obs-grafana') {
    $s = Get-Service -Name $id -ErrorAction SilentlyContinue
    if (-not $s) { Fail "$id - service not found" }
    elseif ($s.Status -ne 'Running') { Fail "$id - status $($s.Status)" }
    else { Write-Ok "$id - Running" }
}

Write-Step 'Readiness'
$ready = [ordered]@{
    Prometheus = 'http://127.0.0.1:9090/-/ready'
    Loki       = 'http://127.0.0.1:3100/ready'
    Tempo      = 'http://127.0.0.1:3200/ready'
    Alloy      = 'http://127.0.0.1:12345/-/ready'
    Grafana    = 'http://127.0.0.1:3000/api/health'
}
foreach ($k in $ready.Keys) {
    if (Wait-HttpReady -Url $ready[$k] -TimeoutSec 10) { Write-Ok $k; continue }
    # Loki: the pattern ingester (log patterns in Grafana Logs Drilldown) can stay "not ready" long after startup (observed ~2 h),
    # even though log ingestion and queries work - those are checked by the end-to-end test below
    $body = ''
    try { $null = Invoke-WebRequest $ready[$k] -UseBasicParsing -TimeoutSec 5 } catch { $body = "$($_.ErrorDetails.Message)" }
    if ($k -eq 'Loki' -and $body -match 'Pattern Ingester') {
        Write-Warn "Loki: pattern ingester not ready yet ($($body.Trim())) - log patterns temporarily unavailable"
    } else { Fail "$k not responding ($($ready[$k]))" }
}

# ---------------------------------------------------------------------
Write-Step 'End-to-end OTLP flow'
$traceId = New-HexId 16
$spanId  = New-HexId 8
$nowNs   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000
$resource = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'obs-smoketest' } }) }

try {
    Invoke-Json "$OtlpHttp/v1/traces" @{ resourceSpans = @(@{ resource = $resource; scopeSpans = @(@{
        scope = @{ name = 'smoketest' }
        # webcon.db.cs: attribute with a secret that Alloy must remove (otelcol.processor.attributes "webcon_secrets")
        # webcon.path.id on "workflow.execute": Alloy renames it to webcon.workflow.path.id (otelcol.processor.transform "webcon_cardinality")
        spans = @(@{ traceId = $traceId; spanId = $spanId; name = 'smoketest'; kind = 2
                     startTimeUnixNano = [string]($nowNs - 50000000); endTimeUnixNano = [string]$nowNs
                     attributes = @(@{ key = 'webcon.db.cs'; value = @{ stringValue = 'Data Source=smoketest' } }) },
                  @{ traceId = $traceId; spanId = (New-HexId 8); parentSpanId = $spanId; name = 'webcon.elements_management.workflow.execute'; kind = 1
                     startTimeUnixNano = [string]($nowNs - 40000000); endTimeUnixNano = [string]($nowNs - 10000000)
                     attributes = @(@{ key = 'webcon.path.id'; value = @{ intValue = '1' } }) })
    }) }) }
    # Log copy with resource "unknown_service:WebCon.*" - Alloy must drop it (otelcol.processor.filter "webcon_log_duplicates")
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
    Write-Ok "Sent test trace/log/metric (traceId $traceId)"
} catch {
    Fail "OTLP send to $OtlpHttp failed: $($_.Exception.Message)"
}

$traceJson = $null
if (Wait-Until {
        $script:traceJson = (Invoke-WebRequest "http://127.0.0.1:3200/api/traces/$traceId" -UseBasicParsing -TimeoutSec 5).Content
        $script:traceJson -match 'smoketest'
    } $TimeoutSec) {
    Write-Ok 'Tempo: test trace found'
    if ($traceJson -match 'webcon\.db\.cs') { Fail 'Tempo: attribute webcon.db.cs (database connection data) was NOT removed by Alloy' }
    else { Write-Ok 'Tempo: attribute webcon.db.cs removed' }
    if ($traceJson -match '"webcon\.path\.id"' -or $traceJson -notmatch '"webcon\.workflow\.path\.id"') {
        Fail 'Tempo: webcon.path.id on the workflow.execute span was NOT renamed to webcon.workflow.path.id'
    } else { Write-Ok 'Tempo: webcon.path.id on workflow.execute renamed (spanmetrics cardinality)' }
} else { Fail 'Tempo: test trace not found' }

# TraceQL metrics over (almost) the whole time range of the WEBCON – Operations dashboard. A corrupted Tempo block index (block size
# different from the data.parquet file) breaks every query covering the block: "reading parquet file metadata: missing required field".
# 166 h: Tempo aligns the range to the step, and the limit is query_frontend.metrics.max_duration = 169h.
$endS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$metricsQuery = [Uri]::EscapeDataString('{ } | count_over_time()')
try {
    $null = Invoke-RestMethod "http://127.0.0.1:3200/api/metrics/query_range?q=$metricsQuery&start=$($endS - 166 * 3600)&end=$endS&step=3600" -TimeoutSec 60
    Write-Ok 'Tempo: TraceQL metrics (7 days)'
} catch {
    $msg = "$($_.ErrorDetails.Message)"
    if (-not $msg) { $msg = $_.Exception.Message }
    if ($msg -match 'parquet') { Fail "Tempo: TraceQL metrics - $($msg.Trim()). Corrupted block index - fix: docs\installation\07-troubleshooting.md, section 'Corrupted Tempo index'" }
    else { Fail "Tempo: TraceQL metrics - $($msg.Trim())" }
}

$startNs = $nowNs - 600000000000
$lokiQuery = [Uri]::EscapeDataString('{service_name="obs-smoketest"}')
if (Wait-Until {
        $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query_range?query=$lokiQuery&start=$startNs&limit=50" -TimeoutSec 5
        @($r.data.result).Count -gt 0
    } $TimeoutSec) {
    Write-Ok 'Loki: test log found'
    # The actual log is already there, so the copy (sent in the same request) would be visible by now as well
    $dupQuery = [Uri]::EscapeDataString('{service_name=~"unknown_service:WebCon.+"} |= "' + $traceId + '"')
    $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query_range?query=$dupQuery&start=$startNs&limit=5" -TimeoutSec 5
    if (@($r.data.result).Count -gt 0) { Fail 'Loki: log copy unknown_service:WebCon.* was NOT dropped' }
    else { Write-Ok 'Loki: log copy unknown_service:WebCon.* dropped' }
} else { Fail 'Loki: test log not found' }

if (Wait-Until {
        $r = Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/query?query=obs_smoketest_value' -TimeoutSec 5
        @($r.data.result).Count -gt 0
    } $TimeoutSec) {
    Write-Ok 'Prometheus: test metric found'
} else { Fail 'Prometheus: test metric not found' }

# ---------------------------------------------------------------------
Write-Step 'WEBCON and host data (informational)'
function Get-PromCount([string]$Query) {
    try {
        $r = Invoke-RestMethod ("http://127.0.0.1:9090/api/v1/query?query=" + [Uri]::EscapeDataString($Query)) -TimeoutSec 5
        # comma: without it PS 5.1 unrolls a single-element array to a PSCustomObject (no .Count)
        return ,@($r.data.result)
    } catch { return ,@() }
}
$jobs = Get-PromCount 'count by (job) (target_info)'
if ($jobs.Count) { $jobs | ForEach-Object { Write-Ok "OTLP source: $($_.metric.job)" } } else { Write-Warn 'No services sending OTLP metrics (target_info) - configure WEBCON (scripts\Set-WebconTelemetry.ps1).' }
if ((Get-PromCount 'count({__name__=~"webcon_.+"})').Count) { Write-Ok 'webcon_* metrics present' } else { Write-Warn 'No webcon_* metrics' }
# Fixed WEBCON service names (Portal / WebCon.WorkFlow) - docs/projekt/projekt-nazwy-uslug-webcon.md
$odd = Get-PromCount 'count by (job) (target_info{job=~"(?i).*webcon.*",job!~"Portal|WebCon[.]WorkFlow"})'
foreach ($j in $odd) {
    Write-Warn "WEBCON service with a non-standard name '$($j.metric.job)' - dashboards and alerts do not see it. Run scripts\Set-WebconTelemetry.ps1 (webcon.component marker) or the installer with -WebconPortalServiceName / -WebconServiceServiceName."
}
$noTag = Get-PromCount 'count by (job) (target_info{job=~"Portal|WebCon[.]WorkFlow",webcon_component=""})'
foreach ($j in $noTag) {
    Write-Warn "$($j.metric.job): telemetry without the webcon.component marker - name from appsettings / name-based mapping; run scripts\Set-WebconTelemetry.ps1."
}
if ((Get-PromCount 'target_info{job=~"Portal|WebCon[.]WorkFlow",webcon_component!=""}').Count -and -not $odd.Count) {
    Write-Ok 'WEBCON service names normalized (webcon.component)'
}
if ((Get-PromCount 'up{job="integrations/windows"} == 1').Count) { Write-Ok 'windows_exporter: up' } else { Fail 'windows_exporter: no data' }
$mssql = Get-PromCount 'up{job="integrations/mssql"}'
if ($mssql.Count) {
    if ($mssql[0].value[1] -eq '1') {
        Write-Ok 'mssql exporter: up'
        # metric from the extended query_config (mssql-queries.yaml)
        if ((Get-PromCount 'mssql_wait_time_seconds_total').Count) { Write-Ok 'mssql: extended metrics (mssql-queries.yaml) present' }
        else { Fail 'mssql: extended metrics missing (mssql_wait_time_seconds_total) - check mssql-queries.yaml' }
    } else { Fail 'mssql exporter: down (check the login / Alloy logs)' }
} else { Write-Info 'mssql exporter: not configured' }

# WEBCON content database metrics (docs/projekt/projekt-dostepnosc-i-metryki-bazy.md) - missing permissions = warning (D5)
$webconDb = Get-PromCount 'up{job="integrations/mssql-webcon"}'
if ($webconDb.Count) {
    $dbMetrics = Get-PromCount 'count by (__name__) ({__name__=~"webcon_db_.+"})'
    if ($webconDb[0].value[1] -eq '1' -and $dbMetrics.Count -ge 4) { Write-Ok "WEBCON database metrics: $($dbMetrics.Count) webcon_db_* metrics" }
    elseif ($webconDb[0].value[1] -eq '1') { Write-Warn "WEBCON database metrics: $($dbMetrics.Count) of 4 metrics - missing column permissions? DBA: sql\grant-webcon-db-metrics.sql" }
    else { Write-Warn 'WEBCON database metrics: exporter down - permissions (sql\grant-webcon-db-metrics.sql) / event log, source Alloy' }
} else { Write-Info 'WEBCON database metrics: not configured (-WebconDbMetrics $true)' }

# Availability probes (Portal: -PortalUrl / IIS binding with a host name, instance = Portal address; -ProbeUrl)
$probes = Get-PromCount 'probe_success{job="integrations/blackbox"}'
foreach ($p in $probes) {
    $code = Get-PromCount "probe_http_status_code{job=`"integrations/blackbox`",instance=`"$($p.metric.instance)`"}"
    $codeText = ''
    if ($code.Count) { $codeText = " (HTTP $($code[0].value[1]))" }
    if ($p.value[1] -eq '1') { Write-Ok "Availability ($($p.metric.probe)): $($p.metric.instance)$codeText" }
    else { Fail "Availability ($($p.metric.probe)): $($p.metric.instance) unavailable$codeText" }
}
if (-not $probes.Count) { Write-Info 'Availability probes: none (Portal not detected in IIS, bindings without a host name and no -PortalUrl, -PortalProbe $false or remote mode without a WEBCON agent)' }

# Grafana data source "WEBCON SQL" (WEBCON – Operations dashboard) - health check through the Grafana API
$settings = Get-InstallSettings -Root $Root
if ($settings -and $settings.WebconSqlReaderLogin) {
    $adminPwd = $null
    try { $adminPwd = [IO.File]::ReadAllText((Join-Path $Root 'secrets\grafana-admin.txt'), [Text.Encoding]::UTF8) } catch { }
    if ($adminPwd) {
        $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPwd"))
        try {
            $h = Invoke-RestMethod 'http://127.0.0.1:3000/api/datasources/uid/webcon-sql/health' -Headers @{ Authorization = $auth } -TimeoutSec 20
            if ($h.status -eq 'OK') { Write-Ok "Grafana: data source 'WEBCON SQL' responds" } else { Fail "Grafana: data source 'WEBCON SQL' - $($h.message)" }
        } catch {
            Fail "Grafana: data source 'WEBCON SQL' - $($_.Exception.Message) (check sql\grant-webcon-reader-permissions.sql and the grafana-sql-reader.txt secret)"
        }
    } else { Write-Info "Grafana: data source 'WEBCON SQL' not checked - no access to the admin password (run as administrator)" }
} else { Write-Info "Grafana: data source 'WEBCON SQL' not configured" }

# ---------------------------------------------------------------------
# Remote mode: data from agents on WEBCON / SQL hosts (Install-ObservabilityAgent.ps1 from the agent-bundle package)
if ($settings -and ($settings.WebconHost -or $settings.SqlHost)) {
    Write-Step 'Remote agents'
    foreach ($h in (@($settings.SqlHost, $settings.WebconHost) | Where-Object { $_ } | Select-Object -Unique)) {
        $short = $h.Split('.')[0]
        if ((Get-PromCount "windows_os_info{instance=~`"(?i)$short([.].*)?`"}").Count) { Write-Ok "$h - host metrics (windows_exporter)" }
        else { Fail "$h - no host metrics: agent not installed or no connectivity (scripts in $Root\agent-bundle)" }
    }
    if ($settings.SqlHost -and -not $mssql.Count) { Fail "$($settings.SqlHost) - no mssql metrics (agent Sql role)" }
    if ($settings.WebconHost) {
        if ((Get-PromCount 'target_info{job=~"Portal|WebCon.WorkFlow"}').Count) { Write-Ok "$($settings.WebconHost) - WEBCON telemetry (Portal / Service)" }
        else { Write-Warn "$($settings.WebconHost) - no WEBCON telemetry (Set-WebconTelemetry.ps1 in the Webcon role; metrics every 60 s)" }
    }
    $agentQuery = [Uri]::EscapeDataString('sum by (host_name) (count_over_time({service_name="obs-agent-test"}[7d]))')
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:3100/loki/api/v1/query?query=$agentQuery" -TimeoutSec 10
        $agentHosts = @($r.data.result | ForEach-Object { $_.metric.host_name })
        if ($agentHosts.Count) { Write-Ok "Agent test log (OTLP through the agent) from: $($agentHosts -join ', ')" }
        else { Fail 'No agent test log (service_name="obs-agent-test") in the last 7 days' }
    } catch { Fail "Loki: agent test log query - $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------
# Grafana alerts (provisioning\alerting, docs/projekt/projekt-alerty.md)
Write-Step 'Alerts'
$adminPwd = $null
try { $adminPwd = [IO.File]::ReadAllText((Join-Path $Root 'secrets\grafana-admin.txt'), [Text.Encoding]::UTF8) } catch { }
if ($adminPwd) {
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPwd"))
    try {
        # Invoke-WebRequest + explicit UTF-8: Invoke-RestMethod in PS 5.1 corrupts non-ASCII characters in rule names
        $raw = (Invoke-WebRequest 'http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules' -Headers @{ Authorization = $auth } -UseBasicParsing -TimeoutSec 20).RawContentStream.ToArray()
        $rules = @(([Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json).data.groups | ForEach-Object { $_.rules })
        if ($rules.Count) { Write-Ok "Alert rules loaded: $($rules.Count)" } else { Fail 'No alert rules - check config\grafana\provisioning\alerting and the Grafana log (Failed to provision alerting)' }
        # An error from before Grafana started = state restored from the database ("Warming state cache"), e.g. from rule evaluation
        # while the stack was stopping - not a current problem; Grafana re-evaluates the rule within its interval (1 min).
        $grafanaStart = Get-Process -Name 'grafana', 'grafana-server' -ErrorAction SilentlyContinue |
            Sort-Object StartTime | Select-Object -First 1 -ExpandProperty StartTime
        $restored = 0
        foreach ($rule in $rules | Where-Object { $_.health -eq 'error' }) {
            $lastEval = $null
            if ($rule.lastEvaluation -is [datetime]) { $lastEval = $rule.lastEvaluation.ToLocalTime() }
            else { try { $lastEval = ([DateTimeOffset]::Parse([string]$rule.lastEvaluation, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { } }
            if ($grafanaStart -and $lastEval -and $lastEval -lt $grafanaStart) { $restored++ }
            else { Fail "Alert '$($rule.name)': evaluation error - $($rule.lastError)" }
        }
        if ($restored) { Write-Info "Alerts: $restored rules with an error from before the Grafana restart (restored state, not re-evaluated yet) - repeat the test in 1 min" }
        foreach ($rule in $rules | Where-Object { $_.state -eq 'firing' }) {
            $what = @($rule.alerts | Where-Object { $_.state -eq 'Alerting' } | ForEach-Object { $_.annotations.summary }) -join '; '
            Write-Warn "Alert firing: $($rule.name) - $what"
        }
        if (-not @($rules | Where-Object { $_.state -eq 'firing' }).Count) { Write-Ok 'No firing alerts' }
    } catch { Fail "Grafana: alert rule list - $($_.Exception.Message)" }
} else { Write-Info 'Alerts not checked - no access to the Grafana admin password (run as administrator)' }

Write-Host ''
if ($fail -gt 0) { Write-Host "Result: $fail problem(s)" -ForegroundColor Yellow; exit 1 }
Write-Host 'Result: OK' -ForegroundColor Green
