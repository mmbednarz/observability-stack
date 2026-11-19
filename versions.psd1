@{
    # Przypięte wersje komponentów. Zmiana wersji = edycja tego pliku + ponowne uruchomienie Install-ObservabilityStack.ps1.
    # {0} w URL zastępowane jest wersją (bez prefiksu "v").
    # Exe = nazwa pliku wykonywalnego szukana rekurencyjnie po rozpakowaniu.
    # ChecksumUrl = plik z sumami SHA256 (format "<hash>  <nazwa pliku>") lub pojedynczy hash; brak = tylko ostrzeżenie.

    WinSW = @{
        Version     = '2.12.0'
        Url         = 'https://github.com/winsw/winsw/releases/download/v{0}/WinSW-x64.exe'
        Exe         = 'WinSW-x64.exe'
        ChecksumUrl = $null
    }

    Alloy = @{
        Version     = '1.17.1'
        Url         = 'https://github.com/grafana/alloy/releases/download/v{0}/alloy-windows-amd64.exe.zip'
        Exe         = 'alloy-windows-amd64.exe'
        ChecksumUrl = 'https://github.com/grafana/alloy/releases/download/v{0}/SHA256SUMS'
    }

    Prometheus = @{
        Version     = '3.5.3'   # LTS
        Url         = 'https://github.com/prometheus/prometheus/releases/download/v{0}/prometheus-{0}.windows-amd64.zip'
        Exe         = 'prometheus.exe'
        ChecksumUrl = 'https://github.com/prometheus/prometheus/releases/download/v{0}/sha256sums.txt'
    }

    Tempo = @{
        # 2.10.x celowo: 3.0 zmienia architekturę i konfigurację (usunięte sekcje ingester/compactor).
        Version     = '2.10.7'
        Url         = 'https://github.com/grafana/tempo/releases/download/v{0}/tempo_{0}_windows_amd64.tar.gz'
        Exe         = 'tempo.exe'
        ChecksumUrl = 'https://github.com/grafana/tempo/releases/download/v{0}/SHA256SUMS'
    }

    Loki = @{
        Version     = '3.6.13'
        Url         = 'https://github.com/grafana/loki/releases/download/v{0}/loki-windows-amd64.exe.zip'
        Exe         = 'loki-windows-amd64.exe'
        ChecksumUrl = 'https://github.com/grafana/loki/releases/download/v{0}/SHA256SUMS'
    }

    Grafana = @{
        Version     = '12.4.3'
        Url         = 'https://dl.grafana.com/oss/release/grafana-{0}.windows-amd64.zip'
        Exe         = 'grafana.exe'
        ChecksumUrl = 'https://dl.grafana.com/oss/release/grafana-{0}.windows-amd64.zip.sha256'
    }

    # Dashboardy społecznościowe pobierane z grafana.com przy instalacji (błąd pobrania = ostrzeżenie, nie przerywa instalacji).
    CommunityDashboards = @(
        @{ Id = 19924; File = 'aspnetcore.json';          Folder = 'dotnet' }
        @{ Id = 19925; File = 'aspnetcore-endpoint.json'; Folder = 'dotnet' }
        # 19957 (windows_exporter) usunięty - niezgodny z windows_exporter w Alloy 1.17; zastąpiony dashboards\host\windows-host.json
    )
}
