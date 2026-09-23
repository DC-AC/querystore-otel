/*
  SQL Agent demo jobs for testing the Agent telemetry and dashboard.
  Creates four jobs in the "OTel Demo" category:

    OTel Demo - Steady        every 5 min, succeeds, runs 5-30 s
    OTel Demo - Flaky         every 5 min, fails ~30% of runs (1 retry)
    OTel Demo - Always Fails  every 15 min, divide-by-zero
    OTel Demo - Long Runner   every 10 min, runs ~3 min (shows running-duration metric)

  Re-runnable: existing demo jobs are dropped first.
  Cleanup: run the block at the bottom.
*/
USE msdb;
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM dbo.syscategories WHERE name = N'OTel Demo' AND category_class = 1)
    EXEC dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'OTel Demo';

DECLARE @jobs TABLE (name sysname, cmd nvarchar(max), every_min int, retries int);
INSERT @jobs VALUES
 (N'OTel Demo - Steady',
  N'DECLARE @s int = 5 + ABS(CHECKSUM(NEWID())) % 26;
DECLARE @d char(8) = CONVERT(char(8), DATEADD(second, @s, 0), 108);
WAITFOR DELAY @d;
SELECT COUNT(*) FROM AdventureWorks2019.Sales.SalesOrderDetail;', 5, 0),
 (N'OTel Demo - Flaky',
  N'WAITFOR DELAY ''00:00:05'';
IF ABS(CHECKSUM(NEWID())) % 10 < 3
    RAISERROR(N''Simulated intermittent failure (OTel demo)'', 16, 1);', 5, 1),
 (N'OTel Demo - Always Fails',
  N'SELECT 1 / 0 AS boom;', 15, 0),
 (N'OTel Demo - Long Runner',
  N'WAITFOR DELAY ''00:03:00'';', 10, 0);

DECLARE @name sysname, @cmd nvarchar(max), @every int, @retries int,
        @job_id uniqueidentifier, @sched sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name, cmd, every_min, retries FROM @jobs;
OPEN c;
FETCH NEXT FROM c INTO @name, @cmd, @every, @retries;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @name)
        EXEC dbo.sp_delete_job @job_name = @name, @delete_unused_schedule = 1;

    SET @job_id = NULL;
    EXEC dbo.sp_add_job @job_name = @name, @category_name = N'OTel Demo',
         @description = N'Demo job for SQL Agent OpenTelemetry collection', @job_id = @job_id OUTPUT;

    EXEC dbo.sp_add_jobstep @job_id = @job_id, @step_name = N'Run', @subsystem = N'TSQL',
         @database_name = N'master', @command = @cmd,
         @retry_attempts = @retries, @retry_interval = 1,
         @on_success_action = 1, @on_fail_action = 2;

    SET @sched = @name + N' schedule';
    EXEC dbo.sp_add_jobschedule @job_id = @job_id, @name = @sched,
         @freq_type = 4, @freq_interval = 1,                     -- daily
         @freq_subday_type = 4, @freq_subday_interval = @every,  -- every N minutes
         @active_start_time = 0;

    EXEC dbo.sp_add_jobserver @job_id = @job_id, @server_name = N'(local)';
    PRINT CONCAT('Created ', @name, ' (every ', @every, ' min)');

    FETCH NEXT FROM c INTO @name, @cmd, @every, @retries;
END
CLOSE c; DEALLOCATE c;

-- Start each once now so data appears immediately
EXEC dbo.sp_start_job @job_name = N'OTel Demo - Steady';
EXEC dbo.sp_start_job @job_name = N'OTel Demo - Flaky';
EXEC dbo.sp_start_job @job_name = N'OTel Demo - Always Fails';
EXEC dbo.sp_start_job @job_name = N'OTel Demo - Long Runner';
GO

/* ---- Cleanup (run manually when done) --------------------------------------
USE msdb;
DECLARE @n sysname;
DECLARE d CURSOR LOCAL FOR SELECT j.name FROM dbo.sysjobs j
    JOIN dbo.syscategories c ON c.category_id = j.category_id WHERE c.name = N'OTel Demo';
OPEN d; FETCH NEXT FROM d INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.sp_delete_job @job_name = @n, @delete_unused_schedule = 1; FETCH NEXT FROM d INTO @n; END
CLOSE d; DEALLOCATE d;
------------------------------------------------------------------------------ */
