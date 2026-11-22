/*
  Reading the current state from the WEBCON content database in Grafana (Microsoft SQL Server data source):
    - ActiveTasks                         - active tasks (top users by task count)
    - WFAvaiblePaths, WFSteps, WorkFlows, WFDefinitions - names of paths, steps, workflows and processes
      (dictionary for rankings from traces: PATH_STPID -> STP_ID, STP_WFID -> WF_ID, WF_WFDEFID -> DEF_ID)

  A separate read-only login (NOT the mssql exporter login): any dashboard editor can write queries in Grafana,
  and the exporter login has VIEW SERVER STATE (can see the query text of other sessions).
  The login gets only SELECT on the tables above - no db_datareader and no access to form data.

  Run by a DBA (sysadmin / securityadmin + db_owner in the content databases). The script is idempotent.
  Run it again after a WEBCON upgrade - the upgrade may recreate tables and remove the permissions.
*/
USE [master];
GO

DECLARE @login     sysname       = N'svc_obs_grafana_reader';   -- <== login name
DECLARE @databases nvarchar(max) = N'WEBCON_Content';           -- <== WEBCON content databases, comma-separated

-- Create the login (if it does not exist) - set the password manually and store it in C:\Observability\secrets (Set-SecretFile):
-- CREATE LOGIN [svc_obs_grafana_reader] WITH PASSWORD = N'<strong_password>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    RAISERROR(N'Login %s does not exist - create it (CREATE LOGIN above) and run the script again.', 16, 1, @login);
    RETURN;
END;

DECLARE @db sysname, @exec nvarchar(400), @sql nvarchar(max);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@databases, N',') WHERE LTRIM(RTRIM(value)) <> N'';
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
        RAISERROR(N'Database %s does not exist - skipped.', 10, 1, @db) WITH NOWAIT;
    ELSE
    BEGIN
        SET @exec = QUOTENAME(@db) + N'.sys.sp_executesql';
        SET @sql =
            N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(@login, '''') + N') ' +
            N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.ActiveTasks    TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFAvaiblePaths TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFSteps        TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WorkFlows      TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFDefinitions  TO ' + QUOTENAME(@login) + N';';
        EXEC @exec @sql;
        RAISERROR(N'Database %s: permissions granted.', 10, 1, @db) WITH NOWAIT;
    END;
    FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs;
DEALLOCATE dbs;
GO

/*
  Verification (as a DBA, in the content database) - the queries should return data, and the last one a permission error:

  USE [WEBCON_Content];
  EXECUTE AS LOGIN = 'svc_obs_grafana_reader';
      SELECT TOP 10 TSK_User, TSK_UserName, COUNT(*) AS tasks
      FROM dbo.ActiveTasks WHERE TSK_IsFinished = 0 AND TSK_IsDeleted = 0
      GROUP BY TSK_User, TSK_UserName ORDER BY tasks DESC;
      SELECT TOP 5 PATH_ID, PATH_Name FROM dbo.WFAvaiblePaths;
      SELECT TOP 1 * FROM dbo.WFElements;   -- expected error: The SELECT permission was denied
  REVERT;
*/
