/*
  Minimalne uprawnienia dla loginu używanego przez prometheus.exporter.mssql (Grafana Alloy).
  Uruchamia DBA (sysadmin / securityadmin). Zastąp nazwę loginu.
  Test-SqlExporterLogin.ps1 weryfikuje te uprawnienia po podaniu loginu.
*/
USE [master];
GO

DECLARE @login sysname = N'svc_obs_mssql_exporter';   -- <== nazwa loginu

-- Utworzenie loginu (jeśli nie istnieje) - hasło ustaw ręcznie:
-- CREATE LOGIN [svc_obs_mssql_exporter] WITH PASSWORD = N'<silne_haslo>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];

DECLARE @sql nvarchar(max) =
    N'GRANT VIEW SERVER STATE TO ' + QUOTENAME(@login) + N';' +
    N'GRANT VIEW ANY DEFINITION TO ' + QUOTENAME(@login) + N';';
EXEC sys.sp_executesql @sql;

-- SQL Server 2022+: VIEW SERVER STATE obejmuje VIEW SERVER PERFORMANCE STATE.
-- Login NIE potrzebuje dostępu do baz WEBCON ani roli sysadmin.
GO
