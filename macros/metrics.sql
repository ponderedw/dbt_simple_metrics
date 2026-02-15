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

    {# ── 2. Extract columns and metrics definitions ── #}
    {%- set model_columns = ns.model_node.columns -%}
    {%- set model_meta = ns.model_node.config.get('meta', {}) -%}
    {%- set model_metrics = model_meta.get('metrics', {}) -%}

    {%- if model_metrics | length == 0 -%}
        {{ exceptions.raise_compiler_error(
            "dbt_simple_metrics: Model '" ~ model_name ~ "' has no metrics defined in config.meta.metrics."
        ) }}
    {%- endif -%}

    {# ── 3. Validate requested dimensions exist in columns ── #}
    {%- for dim in dimensions -%}
        {%- if dim not in model_columns -%}
            {{ exceptions.raise_compiler_error(
                "dbt_simple_metrics: Dimension '" ~ dim ~ "' is not defined in the columns of model '" ~ model_name ~ "'. "
                ~ "Available columns: " ~ (model_columns.keys() | list | join(', '))
            ) }}
        {%- endif -%}
    {%- endfor -%}

    {# ── 4. Validate requested metrics exist ── #}
    {%- for metric_name in metrics -%}
        {%- if metric_name not in model_metrics -%}
            {{ exceptions.raise_compiler_error(
                "dbt_simple_metrics: Metric '" ~ metric_name ~ "' is not defined in the metrics of model '" ~ model_name ~ "'. "
                ~ "Available metrics: " ~ (model_metrics.keys() | list | join(', '))
            ) }}
        {%- endif -%}
    {%- endfor -%}

    {# ── 5. Generate SQL ── #}
select
    {%- for dim in dimensions %}
    {{ dim }}{% if not loop.last or metrics | length > 0 %},{% endif %}
    {%- endfor %}
    {%- for metric_name in metrics %}
    {%- set metric_def = model_metrics[metric_name] %}
    {%- set resolved_sql = dbt_simple_metrics._resolve_metric_expression(metric_def.sql) %}
    {{ dbt_simple_metrics._wrap_aggregation(metric_def.type, resolved_sql) }} as {{ metric_name }}{% if not loop.last %},{% endif %}
    {%- endfor %}
from {{ ref(model_name) }}
    {%- if dimensions | length > 0 %}
group by {% for i in range(1, dimensions | length + 1) %}{{ i }}{% if not loop.last %}, {% endif %}{% endfor %}
    {%- endif %}

{% else %}

{# ── Compile-time fallback: graph is not yet available ── #}
{# Produces a valid ref-based stub so dbt can resolve the DAG #}
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


{# ── Helper: Resolve ${column_name} references in metric SQL expressions ── #}

{% macro _resolve_metric_expression(sql_expr) %}
    {%- set resolved = sql_expr | string | replace('${', '') | replace('}', '') -%}
    {{ return(resolved) }}
{% endmacro %}


{# ── Helper: Wrap expression with aggregation function based on Cube measure type ── #}

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
