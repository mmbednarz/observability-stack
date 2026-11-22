/*
  Minimum permissions for the login used by prometheus.exporter.mssql (Grafana Alloy).
  Run by a DBA (sysadmin / securityadmin). Replace the login name.
  Test-SqlExporterLogin.ps1 verifies these permissions for a given login.
*/
USE [master];
GO

DECLARE @login sysname = N'svc_obs_mssql_exporter';   -- <== login name

-- Create the login (if it does not exist) - set the password manually:
-- CREATE LOGIN [svc_obs_mssql_exporter] WITH PASSWORD = N'<strong_password>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];

DECLARE @sql nvarchar(max) =
    N'GRANT VIEW SERVER STATE TO ' + QUOTENAME(@login) + N';' +
    N'GRANT VIEW ANY DEFINITION TO ' + QUOTENAME(@login) + N';';
EXEC sys.sp_executesql @sql;

-- SQL Server 2022+: VIEW SERVER STATE includes VIEW SERVER PERFORMANCE STATE.
-- The login does NOT need access to WEBCON databases or the sysadmin role.
GO
