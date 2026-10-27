-- Keep the query identical across iterations. Durations are inclusive and may
-- overlap across workers or nested stages; their sum is not wall-clock time.
WITH measured AS (
  SELECT s.*, EXTRACT_ARG(arg_set_id, 'debug.component') AS component,
    EXTRACT_ARG(arg_set_id, 'debug.operation') AS operation,
    EXTRACT_ARG(arg_set_id, 'debug.thread') AS physical_thread
  FROM slice s WHERE category = 'ss' AND dur >= 0
), ranked AS (
  SELECT operation, component, name, COUNT(*) AS calls,
    SUM(dur) AS inclusive_ns, PERCENTILE(dur, 50) AS p50_ns,
    PERCENTILE(dur, 95) AS p95_ns, MAX(dur) AS max_ns,
    COUNT(DISTINCT physical_thread) AS threads
  FROM measured WHERE component != 'operation'
  GROUP BY operation, component, name
), operations AS (
  SELECT operation, name, dur,
    EXTRACT_ARG(arg_set_id, 'debug.parent') AS parent,
    EXTRACT_ARG(arg_set_id, 'debug.version') AS version,
    EXTRACT_ARG(arg_set_id, 'debug.outcome') AS outcome
  FROM measured WHERE component = 'operation'
)
SELECT json_object(
  'operations', json((SELECT json_group_array(json_object(
    'operation', operation, 'name', name, 'parent', parent, 'version', version,
    'outcome', outcome, 'duration_ns', dur)) FROM operations)),
  'hotspots', json((SELECT json_group_array(json_object(
    'operation', operation, 'component', component, 'name', name, 'calls', calls,
    'inclusive_ns', inclusive_ns, 'p50_ns', p50_ns, 'p95_ns', p95_ns,
    'max_ns', max_ns, 'threads', threads))
    FROM (SELECT * FROM ranked ORDER BY operation, inclusive_ns DESC)))
) AS hotspots;
