# Structural signature of a nextpnr --report file: key sets only, no values and
# no clock or resource names. Two reports with equal signatures share a schema.
#   jq -c -f tool/flow/report_schema.jq <report.json>
{
  top: keys,
  fmax_value_keys: (.fmax | to_entries | .[0].value | keys),
  utilization_value_keys: (.utilization | to_entries | .[0].value | keys),
  critical_path_keys: (.critical_paths | .[0] | keys),
  step_types: ([.critical_paths[].path[].type] | unique),
  step_keys: ([.critical_paths[].path[] | {type, k: (keys)}] | group_by(.type) | map({(.[0].type): (map(.k) | unique)}) | add),
  net_timing_keys: (.detailed_net_timings | .[0] | keys),
  net_timing_endpoint_keys: ([.detailed_net_timings[].endpoints[]? | keys] | unique)
}
