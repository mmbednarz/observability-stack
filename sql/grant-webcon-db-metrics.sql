/*
  Permissions of the mssql exporter login (svc_obs_mssql_exporter) for metrics from the WEBCON content database
  (config-templates/alloy/webcon-db-queries.yaml, installer: -WebconDbMetrics).

    - a database user for the login in the content database (sys.partitions / sys.tables - queue and log table sizes from metadata;
      metadata visibility comes from VIEW ANY DEFINITION in sql/grant-sql-exporter-permissions.sql)
    - SELECT only on the columns used in the queries: IDs, statuses, counters and dates -
      no email, form or log content (no db_datareader)

  Run by a DBA (sysadmin / securityadmin + db_owner in the content database). The script is idempotent.
  Run it again after a WEBCON upgrade - the upgrade may recreate tables and remove the permissions.
  Run sql/grant-sql-exporter-permissions.sql first (login + VIEW SERVER STATE, VIEW ANY DEFINITION).
*/
USE [master];
GO

DECLARE @login     sysname       = N'svc_obs_mssql_exporter';   -- <== exporter login
DECLARE @databases nvarchar(max) = N'WEBCON_Content';           -- <== WEBCON content databases, comma-separated

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    RAISERROR(N'Login %s does not exist - run sql/grant-sql-exporter-permissions.sql first.', 16, 1, @login);
    RETURN;
END;

DECLARE @db sysname, @exec nvarchar(400), @sql nvarchar(max), @u nvarchar(300);
SET @u = QUOTENAME(@login);
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
            N'CREATE USER ' + @u + N' FOR LOGIN ' + @u + N';' +
            -- webcon_db_mails
            N'GRANT SELECT (MAIL_AttemptsNumber) ON dbo.WFMails TO ' + @u + N';' +
            -- webcon_db_recurrent_actions_overdue
            N'GRANT SELECT (RAS_TimeLastFailure, RAS_TimeLastSuccess, RAS_ServiceName, RAS_Status, RAS_NextLaunch) ON dbo.WFRecurrentActionsStats TO ' + @u + N';' +
            -- webcon_db_timeouts_overdue
            N'GRANT SELECT (ETM_TIMID, ETM_ServiceName, ETM_Status, ETM_ExpireTime, ETM_OccurrenceErrorsCount, ETM_OccurrenceCount, ETM_LastAttemptTime, ETM_AttemptsNumber) ON dbo.WFElementTimeouts TO ' + @u + N';' +
            N'GRANT SELECT (TIM_ID, TIM_STPID, TIM_IsNightOnly, TIM_RepeatCount) ON dbo.WFTimeouts TO ' + @u + N';' +
            N'GRANT SELECT (STP_ID, STP_WFID) ON dbo.WFSteps TO ' + @u + N';' +
            N'GRANT SELECT (WF_ID, WF_WFDEFID) ON dbo.WorkFlows TO ' + @u + N';' +
            N'GRANT SELECT (DEF_ID, DEF_EnableTimeouts) ON dbo.WFDefinitions TO ' + @u + N';';
        EXEC @exec @sql;
        RAISERROR(N'Database %s: permissions granted.', 10, 1, @db) WITH NOWAIT;
    END;
    FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs;
DEALLOCATE dbs;
GO

/*
  Verification (as a DBA, in the content database) - the first query should return a number, the second a permission error:

  USE [WEBCON_Content];
  EXECUTE AS LOGIN = 'svc_obs_mssql_exporter';
      SELECT COUNT(MAIL_AttemptsNumber) FROM dbo.WFMails;
      SELECT TOP 1 * FROM dbo.WFMails;              -- expected error: The SELECT permission was denied
  REVERT;
*/
