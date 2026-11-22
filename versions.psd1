@{
    # Pinned component versions. Changing a version = edit this file + run Install-ObservabilityStack.ps1 again.
    # {0} in the URL is replaced with the version (without the "v" prefix).
    # Exe = executable file name, searched recursively after extraction.
    # ChecksumUrl = SHA256 checksum file (format "<hash>  <file name>") or a single hash; missing = warning only.

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
        # 2.10.x on purpose: 3.0 changes the architecture and configuration (ingester/compactor sections removed).
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

    # Community dashboards downloaded from grafana.com during installation (download error = warning, installation continues).
    CommunityDashboards = @(
        @{ Id = 19924; File = 'aspnetcore.json';          Folder = 'dotnet' }
        @{ Id = 19925; File = 'aspnetcore-endpoint.json'; Folder = 'dotnet' }
        # 19957 (windows_exporter) removed - incompatible with windows_exporter in Alloy 1.17; replaced by dashboards\host\windows-host.json
    )
}
