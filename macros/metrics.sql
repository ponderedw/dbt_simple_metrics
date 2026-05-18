{% macro metrics(model_name, dimensions, metrics) %}

{% if execute %}

    {# ── 1. Find the model node in the dbt graph ── #}
    {%- set ns = namespace(model_node=none) -%}
    {%- for node in graph.nodes.values()
        | selectattr("resource_type", "equalto", "model")
        | selectattr("name", "equalto", model_name) -%}
        {%- set ns.model_node = node -%}
    {%- endfor -%}

    {%- if ns.model_node is none -%}
        {{ exceptions.raise_compiler_error(
            "dbt_simple_metrics: Model '" ~ model_name ~ "' not found in the dbt graph."
        ) }}
    {%- endif -%}

    {# ── 2. Source metrics: config.meta.metrics first, then MetricFlow ── #}
    {%- set model_meta = ns.model_node.config.get('meta', {}) -%}
    {%- set src = namespace(
        metrics=model_meta.get('metrics', {}),
        columns=ns.model_node.columns
    ) -%}

    {%- if src.metrics | length == 0 -%}
        {%- set mf = dbt_simple_metrics._get_mf_metrics(model_name) -%}
        {%- set src.metrics = mf.metrics -%}
        {%- set src.columns = mf.dimensions -%}
        {%- if src.metrics | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                "dbt_simple_metrics: No metrics found for model '" ~ model_name ~ "'. "
                ~ "Define metrics in config.meta.metrics or in a MetricFlow semantic_model."
            ) }}
        {%- endif -%}
    {%- endif -%}

    {# ── 3. Validate requested dimensions exist ── #}
    {%- for dim in dimensions -%}
        {%- if dim not in src.columns -%}
            {{ exceptions.raise_compiler_error(
                "dbt_simple_metrics: Dimension '" ~ dim ~ "' is not defined for model '"
                ~ model_name ~ "'. Available: " ~ (src.columns.keys() | list | join(', '))
            ) }}
        {%- endif -%}
    {%- endfor -%}

    {# ── 4. Validate requested metrics exist ── #}
    {%- for metric_name in metrics -%}
        {%- if metric_name not in src.metrics -%}
            {{ exceptions.raise_compiler_error(
                "dbt_simple_metrics: Metric '" ~ metric_name ~ "' is not defined for model '"
                ~ model_name ~ "'. Available: " ~ (src.metrics.keys() | list | join(', '))
            ) }}
        {%- endif -%}
    {%- endfor -%}

    {# ── 5. Generate SQL ── #}
select
    {%- for dim in dimensions %}
    {{ dim }}{% if not loop.last or metrics | length > 0 %},{% endif %}
    {%- endfor %}
    {%- for metric_name in metrics %}
    {%- set metric_def = src.metrics[metric_name] %}
    {%- set resolved_sql = dbt_simple_metrics._resolve_metric_expression(metric_def.sql, src.metrics) %}
    {{ dbt_simple_metrics._wrap_aggregation(metric_def.type, resolved_sql) }} as {{ metric_name }}{% if not loop.last %},{% endif %}
    {%- endfor %}
from {{ ref(model_name) }}
    {%- if dimensions | length > 0 %}
group by {% for i in range(1, dimensions | length + 1) %}{{ i }}{% if not loop.last %}, {% endif %}{% endfor %}
    {%- endif %}

{% else %}

{# Compile-time stub: graph is not yet available; produces a valid ref so dbt can resolve the DAG #}
select
    {%- for dim in dimensions %}
    {{ dim }}{% if not loop.last or metrics | length > 0 %},{% endif %}
    {%- endfor %}
    {%- for metric_name in metrics %}
    cast(null as numeric) as {{ metric_name }}{% if not loop.last %},{% endif %}
    {%- endfor %}
from {{ ref(model_name) }}
    {%- if dimensions | length > 0 %}
group by {% for i in range(1, dimensions | length + 1) %}{{ i }}{% if not loop.last %}, {% endif %}{% endfor %}
    {%- endif %}

{% endif %}

{% endmacro %}


{# ─────────────────────────────────────────────────────────────────────────────
   MetricFlow support
   Reads from graph.semantic_models / graph.metrics and produces a metrics dict
   with the same shape as config.meta.metrics so the rest of the pipeline is
   unchanged:  { metric_name: { type: 'number', sql: '<pre-resolved SQL>' } }
   The 'number' passthrough type means aggregations are already embedded in the
   SQL string, so _wrap_aggregation becomes a no-op for these entries.
───────────────────────────────────────────────────────────────────────────── #}

{% macro _get_mf_metrics(model_name) %}

    {# Find the semantic model referencing this dbt model #}
    {%- set ns = namespace(sm=none) -%}
    {%- for sm_id, sm in (graph.semantic_models | default({})).items() -%}
        {%- if model_name in (sm.model | string) -%}
            {%- set ns.sm = sm -%}
        {%- endif -%}
    {%- endfor -%}

    {%- if ns.sm is none -%}
        {{ return({'metrics': {}, 'dimensions': {}}) }}
    {%- endif -%}

    {# Measure lookup: name → measure object #}
    {%- set measure_by_name = {} -%}
    {%- for measure in (ns.sm.measures | default([])) -%}
        {%- do measure_by_name.update({measure.name: measure}) -%}
    {%- endfor -%}

    {# Collect MetricFlow metrics from the graph (skip old-style dbt metric types) #}
    {%- set all_mf_metrics = {} -%}
    {%- for metric_id, metric in (graph.metrics | default({})).items() -%}
        {%- if metric.type in ['simple', 'derived', 'ratio', 'cumulative'] -%}
            {%- do all_mf_metrics.update({metric.name: metric}) -%}
        {%- endif -%}
    {%- endfor -%}

    {# ── Build compat metrics dict ── #}
    {%- set compat_metrics = {} -%}

    {# Expose each raw measure directly so callers can reference measures by name #}
    {%- for measure_name, measure in measure_by_name.items() -%}
        {%- set agg  = measure.agg | default('sum') -%}
        {%- set expr = measure.get('expr') or measure_name -%}
        {%- do compat_metrics.update({
            measure_name: {
                'type': 'number',
                'sql': dbt_simple_metrics._wrap_aggregation(agg, expr)
            }
        }) -%}
    {%- endfor -%}

    {# Resolve MetricFlow metrics that can be satisfied by this model's measures.
       Metrics referencing measures from a different semantic model return '' and
       are silently skipped. #}
    {%- for metric_name, metric in all_mf_metrics.items() -%}
        {%- set resolved = dbt_simple_metrics._resolve_mf_metric(
            metric, all_mf_metrics, measure_by_name, []
        ) -%}
        {%- if resolved -%}
            {%- do compat_metrics.update({
                metric_name: {'type': 'number', 'sql': resolved}
            }) -%}
        {%- endif -%}
    {%- endfor -%}

    {# ── Build dimensions dict ── #}
    {# Seed with semantic model dimensions, then fill in all model columns so that
       any column present in the underlying table can be used as a dimension. #}
    {%- set compat_dims = {} -%}
    {%- for dim in (ns.sm.dimensions | default([])) -%}
        {%- do compat_dims.update({dim.name: dim}) -%}
    {%- endfor -%}
    {%- for node in graph.nodes.values()
        | selectattr("resource_type", "equalto", "model")
        | selectattr("name", "equalto", model_name) -%}
        {%- for col_name, col in node.columns.items() -%}
            {%- if col_name not in compat_dims -%}
                {%- do compat_dims.update({col_name: col}) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {{ return({'metrics': compat_metrics, 'dimensions': compat_dims}) }}

{% endmacro %}


{# Recursively resolve a single MetricFlow metric to a plain SQL string with
   aggregation functions already embedded.
   Returns '' when the metric cannot be resolved against measure_by_name
   (i.e. its base measure lives in a different semantic model). #}

{% macro _resolve_mf_metric(metric, all_metrics, measure_by_name, visited) %}

    {%- if metric.name in visited -%}
        {{ exceptions.raise_compiler_error(
            "dbt_simple_metrics: Circular MetricFlow metric reference at '" ~ metric.name ~ "'."
        ) }}
    {%- endif -%}
    {%- set visited     = visited + [metric.name] -%}
    {%- set tp          = metric.get('type_params') or {} -%}
    {%- set metric_type = metric.type | lower -%}

    {# simple / cumulative — wrap the base measure's expr with its aggregation #}
    {%- if metric_type in ['simple', 'cumulative'] -%}
        {%- set measure_ref  = tp.get('measure') -%}
        {%- set measure_name = (
            (measure_ref.get('name') if measure_ref is mapping else measure_ref) or ''
        ) | string -%}
        {%- set measure = measure_by_name.get(measure_name) -%}
        {%- if measure -%}
            {%- set expr = measure.get('expr') or measure_name -%}
            {{ return(dbt_simple_metrics._wrap_aggregation(measure.agg | default('sum'), expr)) }}
        {%- else -%}
            {{ return('') }}
        {%- endif -%}

    {# ratio — numerator / NULLIF(denominator, 0); both sides are metric names #}
    {%- elif metric_type == 'ratio' -%}
        {%- set num_ref  = tp.get('numerator') -%}
        {%- set den_ref  = tp.get('denominator') -%}
        {%- set num_name = (
            (num_ref.get('name') if num_ref is mapping else num_ref) or ''
        ) | string -%}
        {%- set den_name = (
            (den_ref.get('name') if den_ref is mapping else den_ref) or ''
        ) | string -%}
        {%- set num_metric = all_metrics.get(num_name) -%}
        {%- set den_metric = all_metrics.get(den_name) -%}
        {%- if num_metric and den_metric -%}
            {%- set num_sql = dbt_simple_metrics._resolve_mf_metric(num_metric, all_metrics, measure_by_name, visited) -%}
            {%- set den_sql = dbt_simple_metrics._resolve_mf_metric(den_metric, all_metrics, measure_by_name, visited) -%}
            {%- if num_sql and den_sql -%}
                {{ return(num_sql ~ ' / NULLIF(' ~ den_sql ~ ', 0)') }}
            {%- else -%}
                {{ return('') }}
            {%- endif -%}
        {%- else -%}
            {{ return('') }}
        {%- endif -%}

    {# derived — substitute each referenced metric name in the expr with its SQL #}
    {%- elif metric_type == 'derived' -%}
        {%- set ns = namespace(result=(tp.get('expr') or '') | string, ok=true) -%}
        {%- for ref in (tp.get('metrics') or []) -%}
            {%- set ref_name   = (
                (ref.get('name') if ref is mapping else ref) or ''
            ) | string -%}
            {%- set ref_metric = all_metrics.get(ref_name) -%}
            {%- if ref_metric -%}
                {%- set ref_sql = dbt_simple_metrics._resolve_mf_metric(
                    ref_metric, all_metrics, measure_by_name, visited
                ) -%}
                {%- if ref_sql -%}
                    {%- set ns.result = ns.result | replace(ref_name, '(' ~ ref_sql ~ ')') -%}
                {%- else -%}
                    {%- set ns.ok = false -%}
                {%- endif -%}
            {%- else -%}
                {%- set ns.ok = false -%}
            {%- endif -%}
        {%- endfor -%}
        {%- if ns.ok -%}
            {{ return(ns.result) }}
        {%- else -%}
            {{ return('') }}
        {%- endif -%}

    {%- else -%}
        {{ return('') }}
    {%- endif -%}

{% endmacro %}


{# ── Helper: Resolve ${...} references in metric SQL expressions ── #}
{# Used only for config.meta.metrics format; MetricFlow SQL is pre-resolved. #}

{% macro _resolve_metric_expression(sql_expr, model_metrics={}, _visited=[]) %}
    {%- set ns = namespace(result=sql_expr | string) -%}

    {# First pass: replace ${metric_name} with the wrapped aggregation of the referenced metric #}
    {%- for ref_name, ref_def in model_metrics.items() -%}
        {%- set placeholder = '${' ~ ref_name ~ '}' -%}
        {%- if placeholder in ns.result -%}
            {%- if ref_name in _visited -%}
                {{ exceptions.raise_compiler_error(
                    "dbt_simple_metrics: Circular measure reference detected involving '" ~ ref_name ~ "'."
                ) }}
            {%- endif -%}
            {%- set ref_sql = ref_def.sql | default('') -%}
            {%- set inner_sql = dbt_simple_metrics._resolve_metric_expression(
                ref_sql,
                model_metrics,
                _visited + [ref_name]
            ) -%}
            {%- set wrapped = dbt_simple_metrics._wrap_aggregation(ref_def.type, inner_sql) -%}
            {%- set ns.result = ns.result | replace(placeholder, wrapped) -%}
        {%- endif -%}
    {%- endfor -%}

    {# Second pass: strip any remaining bare ${column} references to plain column names #}
    {%- set ns.result = ns.result | replace('${', '') | replace('}', '') -%}

    {# Third pass: evaluate [[ macro(...) ]] calls embedded in the expression.
       [[ ]] is used instead of {{ }} so the YAML parser leaves it as a literal
       string; we convert it here at execution time when the full context is live. #}
    {%- if '[[' in ns.result -%}
        {%- set ns.result = ns.result | replace('[[', '{{') | replace(']]', '}}') -%}
        {%- set ns.result = render(ns.result) | trim -%}
    {%- endif -%}

    {{ return(ns.result) }}
{% endmacro %}


{# ── Helper: Wrap expression with aggregation function based on measure/metric type ── #}

{% macro _wrap_aggregation(metric_type, expression) %}
    {%- set type_lower = metric_type | lower | trim -%}

    {%- if type_lower == 'sum' -%}
        {{ return('sum(' ~ expression ~ ')') }}
    {%- elif type_lower in ['avg', 'average'] -%}
        {{ return('avg(' ~ expression ~ ')') }}
    {%- elif type_lower == 'min' -%}
        {{ return('min(' ~ expression ~ ')') }}
    {%- elif type_lower == 'max' -%}
        {{ return('max(' ~ expression ~ ')') }}
    {%- elif type_lower == 'count' -%}
        {{ return('count(*)') }}
    {%- elif type_lower == 'count_distinct' -%}
        {{ return('count(distinct ' ~ expression ~ ')') }}
    {%- elif type_lower == 'count_distinct_approx' -%}
        {{ return('approx_count_distinct(' ~ expression ~ ')') }}
    {%- elif type_lower in ['number', 'number_agg', 'string', 'boolean', 'time'] -%}
        {{ return(expression) }}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "dbt_simple_metrics: Unsupported metric type '" ~ metric_type ~ "'. "
            ~ "Supported types: sum, avg, average, min, max, count, count_distinct, "
            ~ "count_distinct_approx, number, number_agg, string, boolean, time."
        ) }}
    {%- endif -%}
{% endmacro %}
