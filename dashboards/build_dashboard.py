"""Builds sql-otel-grafana.json. Edit WS (or the workspace in Grafana after import) and re-run."""
import json, sys, os

WS = sys.argv[1] if len(sys.argv) > 1 else "/subscriptions/ee3cb3c0-3415-43ee-8e63-a0170716ee9e/resourceGroups/DefaultResourceGroup-EUS2/providers/Microsoft.OperationalInsights/workspaces/DefaultWorkspace-ee3cb3c0-3415-43ee-8e63-a0170716ee9e-EUS2"
DS = {"type": "grafana-azure-monitor-datasource", "uid": "${ds}"}
ATTRS = 'extend a = column_ifexists("LogAttributes", column_ifexists("Attributes", dynamic({})))'

QS = f"""OTelLogs
| where TimeGenerated between (($__timeFrom() - 1d) .. ($__timeTo() + 1d))
| {ATTRS}
| extend db_name        = tostring(a.db_name),
         object_name    = tostring(a.object_name),
         object_type    = tostring(a.object_type),
         query_id       = tolong(a.query_id),
         plan_id        = tolong(a.plan_id),
         interval_end   = todatetime(a.interval_end),
         execution_type = tostring(a.execution_type_desc),
         execs          = todouble(a.count_executions),
         avg_ms         = todouble(a.avg_duration_ms),
         max_ms         = todouble(a.max_duration_ms),
         cpu_ms         = todouble(a.avg_cpu_ms),
         reads          = todouble(a.avg_logical_io_reads),
         sql_text       = tostring(column_ifexists("Body", ""))
| where isnotempty(db_name) and $__contains(db_name, $db)
| where interval_end between ($__timeFrom() .. $__timeTo())
| summarize arg_max(TimeGenerated, *) by db_name, query_id, plan_id, interval_end, execution_type
| extend total_ms = avg_ms * execs, total_cpu_ms = cpu_ms * execs, total_reads = reads * execs
"""

AG = f"""OTelLogs
| where TimeGenerated between (($__timeFrom() - 1d) .. ($__timeTo() + 1d))
| {ATTRS}
| where tostring(a.event_source) == "mssql.agent"
| extend instance_id  = tolong(a.instance_id),
         job_name     = tostring(a.job_name),
         job_category = tostring(a.job_category),
         step_id      = toint(a.step_id),
         step_name    = tostring(a.step_name),
         run_status   = tostring(a.run_status),
         run_start    = todatetime(a.run_start_utc),
         duration_s   = todouble(a.duration_s),
         retries      = toint(a.retries_attempted),
         message      = tostring(column_ifexists("Body", ""))
| where $__contains(job_name, $job)
| where run_start between ($__timeFrom() .. $__timeTo())
| summarize arg_max(TimeGenerated, *) by instance_id
"""

pid = [0]
def target(base, q, fmt):
    query = q.replace("{BASE}", base) if "{BASE}" in q else base + q
    return {"refId": "A", "datasource": DS, "queryType": "Azure Log Analytics",
            "azureLogAnalytics": {"query": query, "resources": [WS], "resultFormat": fmt}}

def panel(kind, title, base, q, grid, fmt="table", unit=None, desc=None, custom=None, options=None):
    pid[0] += 1
    d = {"unit": unit} if unit else {}
    if custom: d["custom"] = custom
    p = {"id": pid[0], "type": kind, "title": title, "datasource": DS,
         "gridPos": dict(zip("xywh", grid)), "targets": [target(base, q, fmt)],
         "fieldConfig": {"defaults": d, "overrides": []}, "options": options or {}}
    if desc: p["description"] = desc
    return p

def stat(title, base, q, x, y, unit=None, color="blue", w=4):
    p = panel("stat", title, base, q, (x, y, w, 4), unit=unit or "short",
              options={"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                       "colorMode": "background", "graphMode": "none", "textMode": "value"})
    p["fieldConfig"]["defaults"]["color"] = {"mode": "fixed", "fixedColor": color}
    return p

def row(title, y):
    pid[0] += 1
    return {"id": pid[0], "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}

BARS = {"drawStyle": "bars", "fillOpacity": 80, "stacking": {"mode": "normal", "group": "A"}, "lineWidth": 1}

panels = [
    row("Query Store", 0),
    stat("Statement executions", QS, "| summarize value = sum(execs)", 0, 1),
    stat("Total duration", QS, "| summarize value = sum(total_ms)", 4, 1, "ms", "purple"),
    stat("Total CPU", QS, "| summarize value = sum(total_cpu_ms)", 8, 1, "ms", "orange"),
    stat("Procedures seen", QS, "| where object_type == 'SQL_STORED_PROCEDURE' | summarize value = dcount(object_name)", 12, 1),
    stat("Distinct queries", QS, "| summarize value = dcount(strcat(db_name, ':', query_id))", 16, 1),
    stat("Aborted / exception executions", QS, "| where execution_type != 'Regular' | summarize value = sum(execs)", 20, 1, None, "red"),

    panel("timeseries", "Duration by procedure (top 10)", QS, """let base = materialize({BASE}| where object_name !startswith "(");
let top10 = base | summarize t = sum(total_ms) by object_name | top 10 by t | project object_name;
base
| where object_name in (top10)
| summarize duration_ms = sum(total_ms) by interval_end, object_name
| order by interval_end asc""", (0, 5, 12, 9), fmt="time_series", unit="ms",
          desc="Total duration per Query Store interval for the 10 most expensive procedures."),
    panel("timeseries", "Executions by type", QS, """| summarize executions = sum(execs) by interval_end, execution_type
| order by interval_end asc""", (12, 5, 12, 9), fmt="time_series"),

    panel("table", "Top procedures", QS, """| where object_name !startswith "("
| summarize ['Executions'] = sum(execs),
            ['Total duration (ms)'] = sum(total_ms),
            ['Avg duration (ms)'] = sum(total_ms) / sum(execs),
            ['Total CPU (ms)'] = sum(total_cpu_ms),
            ['Logical reads'] = sum(total_reads),
            ['Queries'] = dcount(query_id),
            ['Plans'] = dcount(plan_id)
    by ['Database'] = db_name, ['Procedure'] = object_name
| top 50 by ['Total duration (ms)']""", (0, 14, 24, 10),
          desc="Statement-level stats rolled up per procedure. Executions count statements, not procedure calls."),
    panel("table", "Top queries", QS, """| summarize ['Executions'] = sum(execs),
            ['Total duration (ms)'] = sum(total_ms),
            ['Avg duration (ms)'] = sum(total_ms) / sum(execs),
            ['Max duration (ms)'] = max(max_ms),
            ['Total CPU (ms)'] = sum(total_cpu_ms),
            ['Plans'] = dcount(plan_id),
            sql = take_any(sql_text)
    by ['Database'] = db_name, ['Query ID'] = query_id, ['Object'] = object_name
| extend ['SQL'] = substring(sql, 0, 200)
| project-away sql
| top 50 by ['Total duration (ms)']""", (0, 24, 24, 10)),
    panel("table", "Queries with multiple plans (possible regressions)", QS, """| summarize ['Plans'] = dcount(plan_id),
            ['Plan IDs'] = make_set(plan_id),
            ['Avg duration (ms)'] = sum(total_ms) / sum(execs),
            ['Worst max (ms)'] = max(max_ms),
            sql = take_any(sql_text)
    by ['Database'] = db_name, ['Query ID'] = query_id, ['Object'] = object_name
| where ['Plans'] > 1
| extend ['SQL'] = substring(sql, 0, 200)
| project-away sql
| order by ['Worst max (ms)'] desc""", (0, 34, 24, 8)),

    row("SQL Agent jobs", 42),
    stat("Job runs", AG, "| where step_id == 0 | summarize value = count()", 0, 43),
    stat("Failed runs", AG, "| where step_id == 0 | summarize value = countif(run_status == 'Failed')", 4, 43, None, "red"),
    stat("Success rate", AG, "| where step_id == 0 | summarize value = round(100.0 * countif(run_status == 'Succeeded') / count(), 1)", 8, 43, "percent", "green"),
    stat("Avg job duration", AG, "| where step_id == 0 | summarize value = avg(duration_s)", 12, 43, "s", "purple"),
    stat("Longest run", AG, "| where step_id == 0 | summarize value = max(duration_s)", 16, 43, "s", "orange"),
    stat("Jobs with failures", AG, "| where step_id == 0 and run_status == 'Failed' | summarize value = dcount(job_name)", 20, 43, None, "red"),

    panel("timeseries", "Job outcomes per hour", AG, """| where step_id == 0
| summarize runs = count() by bin(run_start, 1h), run_status
| order by run_start asc""", (0, 47, 12, 9), fmt="time_series", custom=BARS),
    panel("timeseries", "Average job duration per hour", AG, """| where step_id == 0 and run_status in ("Succeeded", "Failed")
| summarize avg_duration_s = avg(duration_s) by bin(run_start, 1h), job_name
| order by run_start asc""", (12, 47, 12, 9), fmt="time_series", unit="s"),

    panel("table", "Job summary", AG, """| where step_id == 0
| summarize ['Runs'] = count(),
            ['Failed'] = countif(run_status == "Failed"),
            ['Success %'] = round(100.0 * countif(run_status == "Succeeded") / count(), 1),
            ['Avg (s)'] = round(avg(duration_s), 1),
            ['Max (s)'] = max(duration_s),
            arg_max(run_start, run_status)
    by ['Job'] = job_name, ['Category'] = job_category
| project-rename ['Last run (UTC)'] = run_start, ['Last status'] = run_status
| order by ['Failed'] desc, ['Runs'] desc""", (0, 56, 24, 9)),
    panel("table", "Recent failures and retries", AG, """| where run_status in ("Failed", "Retry")
| project ['Start (UTC)'] = run_start, ['Job'] = job_name, ['Step'] = step_name,
          ['Status'] = run_status, ['Duration (s)'] = duration_s,
          ['Error'] = tostring(a.sql_message_id), ['Message'] = message
| order by ['Start (UTC)'] desc
| take 100""", (0, 65, 24, 10),
          desc="Step-level and job-level failures with the Agent history message."),
]

def var_query(q):
    return {"refId": "A", "queryType": "Azure Log Analytics",
            "azureLogAnalytics": {"query": q, "resources": [WS]}}

dash = {
    "title": "SQL Server Query Store & Agent (OTel)",
    "uid": "sql-otel-azure",
    "tags": ["sql-server", "query-store", "sql-agent", "opentelemetry"],
    "timezone": "browser", "schemaVersion": 39, "version": 1, "editable": True,
    "refresh": "5m", "time": {"from": "now-24h", "to": "now"},
    "templating": {"list": [
        {"name": "ds", "label": "Data source", "type": "datasource",
         "query": "grafana-azure-monitor-datasource", "hide": 0, "current": {}},
        {"name": "db", "label": "Database", "type": "query", "datasource": DS,
         "query": var_query(f'OTelLogs\n| where TimeGenerated > ago(30d)\n| {ATTRS}\n| distinct db = tostring(a.db_name)\n| where isnotempty(db)\n| order by db asc'),
         "refresh": 2, "multi": True, "includeAll": True, "current": {"text": "All", "value": "$__all"}, "sort": 1, "hide": 0},
        {"name": "job", "label": "Agent job", "type": "query", "datasource": DS,
         "query": var_query(f'OTelLogs\n| where TimeGenerated > ago(30d)\n| {ATTRS}\n| where tostring(a.event_source) == "mssql.agent"\n| distinct job = tostring(a.job_name)\n| order by job asc'),
         "refresh": 2, "multi": True, "includeAll": True, "current": {"text": "All", "value": "$__all"}, "sort": 1, "hide": 0},
    ]},
    "panels": panels,
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sql-otel-grafana.json")
with open(out, "w") as f:
    json.dump(dash, f, indent=2)
print(f"Wrote {out} ({len(panels)} panels)")
