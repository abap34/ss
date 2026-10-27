WITH measured AS (
  SELECT s.*, EXTRACT_ARG(s.arg_set_id, 'debug.component') AS component,
         EXTRACT_ARG(s.arg_set_id, 'debug.operation') AS operation
  FROM slice s WHERE s.category = 'ss'
), operations AS (
  SELECT name, operation,
    EXTRACT_ARG(arg_set_id, 'debug.parent') AS parent,
    EXTRACT_ARG(arg_set_id, 'debug.revision') AS revision,
    EXTRACT_ARG(arg_set_id, 'debug.version') AS version,
    EXTRACT_ARG(arg_set_id, 'debug.request') AS request,
    EXTRACT_ARG(arg_set_id, 'debug.outcome') AS outcome,
    ts, dur FROM measured WHERE component = 'operation'
), stages AS (
  SELECT component AS category, name, operation, COUNT(*) AS calls,
    SUM(dur) AS inclusive_ns, MAX(dur) AS max_ns
  FROM measured WHERE component != 'operation' AND dur >= 0
  GROUP BY component, name, operation
), samples AS (
  SELECT t.name, MAX(c.value) AS maximum, MIN(c.value) AS minimum, COUNT(*) AS count
  FROM counter c JOIN track t ON t.id = c.track_id GROUP BY t.name
), threads AS (
  SELECT operation, COUNT(DISTINCT EXTRACT_ARG(arg_set_id, 'debug.thread')) AS count
  FROM measured GROUP BY operation
), loss AS (
  SELECT name, value, severity FROM stats WHERE value > 0 AND
    (severity = 'error' OR name GLOB '*discard*' OR name GLOB '*overwrit*' OR name = 'traced_buf_trace_writer_packet_loss')
)
SELECT json_object(
  'operations', json((SELECT json_group_array(json_object(
    'name',name,'operation',operation,'parent',parent,'revision',revision,'version',version,
    'request',request,'outcome',outcome,'start_ns',ts,'duration_ns',dur)) FROM operations)),
  'stages', json((SELECT json_group_array(json_object('category',category,'name',name,
    'operation',operation,'calls',calls,'inclusive_ns',inclusive_ns,'max_ns',max_ns)) FROM stages)),
  'samples', json((SELECT json_group_array(json_object('name',name,'maximum',maximum,'minimum',minimum,'count',count)) FROM samples)),
  'threads', json((SELECT json_group_array(json_object('operation',operation,'count',count)) FROM threads)),
  'loss', json((SELECT json_group_array(json_object('name',name,'value',value,'severity',severity)) FROM loss)),
  'slices', (SELECT COUNT(*) FROM measured),
  'unfinished_slices', (SELECT COUNT(*) FROM measured WHERE dur < 0),
  'mismatched_slices', (SELECT COUNT(*) FROM measured
    WHERE EXTRACT_ARG(arg_set_id, 'debug.duration_ns') IS NOT NULL
    AND dur != EXTRACT_ARG(arg_set_id, 'debug.duration_ns'))
) AS summary;
