{# ─────────────────────────────────────────────────────────────────────────────
   join_metrics(models, filters=[])

   Cross-model metric query with automatic join inference.

   Each entry in `models` selects metrics and/or dimensions from one dbt model:
     { 'name': '<model>', 'metrics': [...], 'dimensions': [...] }

   A join is inferred when two consecutive models share an entity name in their
   MetricFlow semantic model definitions:
     - foreign → primary / unique  →  INNER JOIN (many_to_one)
     - primary → foreign           →  INNER JOIN (one_to_many)
     - primary → primary (unique)  →  INNER JOIN (one_to_one)
     - foreign → foreign           →  error (many_to_many unsupported; use a bridge)

   If no shared entity exists the macro raises a compile-time error listing the
   entities available on each side so the user knows what to add.

   Generated SQL uses one CTE per model that pre-aggregates metrics inside their
   own scope (eliminating cross-table column ambiguity), then joins the CTEs:

     with
     a as (
       select semester_id, department_name, sum(total_enrollments) as total_course_enrollments
       from "db"."schema"."course_performance_summary"
       group by 1, 2
     ),
     b as (
       select semester_id, semester_name
       from "db"."schema"."semester_enrollment_trends"
       group by 1, 2
     )
     select a.department_name, b.semester_name, a.total_course_enrollments
     from a
     join b on a.semester_id = b.semester_id

   Usage:
     {{ dbt_simple_metrics.join_metrics([
         {'name': 'course_performance_summary',
          'metrics': ['total_course_enrollments'],
          'dimensions': ['department_name']},
         {'name': 'semester_enrollment_trends',
          'dimensions': ['semester_name', 'semester_type']}
     ]) }}

   Optional `filters` list applies a WHERE clause to the final outer query:
     filters=["a.academic_year = '2024-2025'"]
─────────────────────────────────────────────────────────────────────────────── #}

{% macro join_metrics(models, filters=[]) %}
{% if execute %}

    {%- set alpha = ['a', 'b', 'c', 'd', 'e', 'f'] -%}
    {%- set ns = namespace(infos=[]) -%}

    {# ── 1. Resolve each model: semantic model, entities, metrics, dimensions ── #}
    {%- for spec in models -%}
        {%- set mname = spec['name'] -%}
        {%- set alias = alpha[loop.index0] -%}

        {%- set ns_sm = namespace(sm=none) -%}
        {%- for sm_id, sm in (graph.semantic_models | default({})).items() -%}
            {%- if mname in (sm.model | string) -%}
                {%- set ns_sm.sm = sm -%}
            {%- endif -%}
        {%- endfor -%}

        {%- if ns_sm.sm is none -%}
            {{ exceptions.raise_compiler_error(
                "join_metrics: No semantic model found for model '" ~ mname ~ "'.\n"
                ~ "  join_metrics requires a MetricFlow semantic_model with entities: defined.\n"
                ~ "  Add a semantic_model block referencing ref('" ~ mname ~ "') to your YAML."
            ) }}
        {%- endif -%}

        {# Build entity dict — handle both entities: list and legacy primary_entity: string #}
        {%- set entities = {} -%}
        {%- if ns_sm.sm.entities is defined and ns_sm.sm.entities -%}
            {%- for ent in ns_sm.sm.entities -%}
                {%- do entities.update({ent.name: {'type': ent.type, 'expr': ent.get('expr') or ent.name}}) -%}
            {%- endfor -%}
        {%- elif ns_sm.sm.primary_entity is defined and ns_sm.sm.primary_entity -%}
            {%- set pk = ns_sm.sm.primary_entity -%}
            {%- do entities.update({pk: {'type': 'primary', 'expr': pk}}) -%}
        {%- endif -%}

        {%- if entities | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                "join_metrics: Semantic model for '" ~ mname ~ "' has no entities defined.\n"
                ~ "  Add an entities: list with at least one primary/foreign entity."
            ) }}
        {%- endif -%}

        {%- set mf = dbt_simple_metrics._get_mf_metrics(mname) -%}

        {%- set ns.infos = ns.infos + [{
            'name':        mname,
            'alias':       alias,
            'entities':    entities,
            'metrics_dict': mf.metrics,
            'dims_dict':   mf.dimensions,
            'req_metrics': spec.get('metrics', []),
            'req_dims':    spec.get('dimensions', [])
        }] -%}
    {%- endfor -%}

    {# ── 2. Find join conditions between consecutive model pairs ── #}
    {%- set ns_j = namespace(joins=[]) -%}

    {%- for i in range(ns.infos | length - 1) -%}
        {%- set L = ns.infos[i] -%}
        {%- set R = ns.infos[i + 1] -%}
        {%- set ns_m = namespace(found=false, l_expr='', r_expr='', rel='') -%}

        {%- for ent_name, ent_l in L.entities.items() -%}
            {%- if ent_name in R.entities and not ns_m.found -%}
                {%- set ent_r = R.entities[ent_name] -%}
                {%- set ns_m.found  = true -%}
                {%- set ns_m.l_expr = ent_l['expr'] -%}
                {%- set ns_m.r_expr = ent_r['expr'] -%}
                {%- if ent_l['type'] in ['primary', 'unique'] and ent_r['type'] in ['primary', 'unique'] -%}
                    {%- set ns_m.rel = 'one_to_one' -%}
                {%- elif ent_l['type'] in ['primary', 'unique'] -%}
                    {%- set ns_m.rel = 'one_to_many' -%}
                {%- elif ent_r['type'] in ['primary', 'unique'] -%}
                    {%- set ns_m.rel = 'many_to_one' -%}
                {%- else -%}
                    {%- set ns_m.rel = 'many_to_many' -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}

        {%- if not ns_m.found -%}
            {{ exceptions.raise_compiler_error(
                "join_metrics: No join defined between '"
                ~ L.name ~ "' and '" ~ R.name ~ "'.\n"
                ~ "  Entities in '" ~ L.name ~ "': ["
                ~ (L.entities.keys() | list | join(', ')) ~ "]\n"
                ~ "  Entities in '" ~ R.name ~ "': ["
                ~ (R.entities.keys() | list | join(', ')) ~ "]\n"
                ~ "  Hint: a join exists when both semantic models share an entity name.\n"
                ~ "  Add a matching entity (e.g. foreign key) to one of the semantic models."
            ) }}
        {%- endif -%}

        {%- if ns_m.rel == 'many_to_many' -%}
            {{ exceptions.raise_compiler_error(
                "join_metrics: Cannot join '" ~ L.name ~ "' to '" ~ R.name ~ "'.\n"
                ~ "  Both sides have the shared entity as a foreign key (many_to_many).\n"
                ~ "  Cube.js and direct SQL JOINs do not support many_to_many natively.\n"
                ~ "  Introduce a bridge/junction model to resolve this relationship."
            ) }}
        {%- endif -%}

        {%- set ns_j.joins = ns_j.joins + [{
            'l_alias': L.alias, 'r_alias': R.alias, 'r_name': R.name,
            'l_expr':  ns_m.l_expr, 'r_expr': ns_m.r_expr, 'rel': ns_m.rel
        }] -%}
    {%- endfor -%}

    {# ── 3. Build one CTE per model: entity key(s) + requested dims + aggregated metrics ── #}
    {%- set ns_ctes = namespace(ctes=[]) -%}

    {%- for info in ns.infos -%}

        {# Collect the entity columns this model must expose for joining #}
        {%- set ns_ent = namespace(exprs=[]) -%}
        {%- for jc in ns_j.joins -%}
            {%- if jc['l_alias'] == info['alias'] and jc['l_expr'] not in ns_ent.exprs -%}
                {%- set ns_ent.exprs = ns_ent.exprs + [jc['l_expr']] -%}
            {%- endif -%}
            {%- if jc['r_alias'] == info['alias'] and jc['r_expr'] not in ns_ent.exprs -%}
                {%- set ns_ent.exprs = ns_ent.exprs + [jc['r_expr']] -%}
            {%- endif -%}
        {%- endfor -%}

        {# Validate requested dimensions #}
        {%- for dim in info['req_dims'] -%}
            {%- if dim not in (info['dims_dict'] | default({})) -%}
                {{ exceptions.raise_compiler_error(
                    "join_metrics: Dimension '" ~ dim ~ "' not defined for model '"
                    ~ info['name'] ~ "'.\n  Available: "
                    ~ ((info['dims_dict'] | default({})).keys() | list | join(', '))
                ) }}
            {%- endif -%}
        {%- endfor -%}

        {# Validate requested metrics #}
        {%- for mname in info['req_metrics'] -%}
            {%- if mname not in (info['metrics_dict'] | default({})) -%}
                {{ exceptions.raise_compiler_error(
                    "join_metrics: Metric '" ~ mname ~ "' not defined for model '"
                    ~ info['name'] ~ "'.\n  Available: "
                    ~ ((info['metrics_dict'] | default({})).keys() | list | join(', '))
                ) }}
            {%- endif -%}
        {%- endfor -%}

        {# Build SELECT cols and GROUP BY positions #}
        {%- set ns_sel = namespace(cols=[], gb=[], n=0) -%}

        {# Entity columns first (needed for the outer JOIN) #}
        {%- for expr in ns_ent.exprs -%}
            {%- set ns_sel.n   = ns_sel.n + 1 -%}
            {%- set ns_sel.cols = ns_sel.cols + [expr] -%}
            {%- set ns_sel.gb   = ns_sel.gb + [ns_sel.n | string] -%}
        {%- endfor -%}

        {# Requested dimensions (skip if already added as an entity column) #}
        {%- for dim in info['req_dims'] -%}
            {%- if dim not in ns_ent.exprs -%}
                {%- set ns_sel.n   = ns_sel.n + 1 -%}
                {%- set ns_sel.cols = ns_sel.cols + [dim] -%}
                {%- set ns_sel.gb   = ns_sel.gb + [ns_sel.n | string] -%}
            {%- endif -%}
        {%- endfor -%}

        {# Requested metrics — already aggregated SQL expressions #}
        {%- for mname in info['req_metrics'] -%}
            {%- set mdef = (info['metrics_dict'] | default({}))[mname] -%}
            {%- set raw  = dbt_simple_metrics._resolve_metric_expression(mdef['sql'], info['metrics_dict']) -%}
            {%- set agg  = dbt_simple_metrics._wrap_aggregation(mdef['type'], raw) -%}
            {%- set ns_sel.cols = ns_sel.cols + [agg ~ ' as ' ~ mname] -%}
        {%- endfor -%}

        {%- set gb_clause = ns_sel.gb | join(', ') -%}
        {%- set cols_str  = ns_sel.cols | join(',\n        ') -%}

        {%- set cte_body %}{{ info['alias'] }} as (
    select
        {{ cols_str }}
    from {{ ref(info['name']) }}{% if gb_clause %}
    group by {{ gb_clause }}{% endif %}
)
{%- endset -%}
        {%- set ns_ctes.ctes = ns_ctes.ctes + [cte_body] -%}

    {%- endfor -%}

    {# ── 4. Outer SELECT: alias-qualified dims and metrics only (entity cols hidden) ── #}
    {%- set ns_out = namespace(cols=[]) -%}
    {%- for info in ns.infos -%}
        {%- for dim in info['req_dims'] -%}
            {%- set ns_out.cols = ns_out.cols + [info['alias'] ~ '.' ~ dim] -%}
        {%- endfor -%}
        {%- for mname in info['req_metrics'] -%}
            {%- set ns_out.cols = ns_out.cols + [info['alias'] ~ '.' ~ mname] -%}
        {%- endfor -%}
    {%- endfor -%}

with {{ ns_ctes.ctes | join(',\n') }}
select
    {{ ns_out.cols | join(',\n    ') }}
from {{ ns.infos[0]['alias'] }}
{%- for jc in ns_j.joins %}
join {{ jc['r_alias'] }} on {{ jc['l_alias'] }}.{{ jc['l_expr'] }} = {{ jc['r_alias'] }}.{{ jc['r_expr'] }}
{%- endfor %}
{%- if filters | length > 0 %}
where
    {%- for f in filters %}
    {{ f }}{% if not loop.last %} and{% endif %}
    {%- endfor %}
{%- endif %}

{% else %}

{# Parse-time stub: registers ref() calls for all models so dbt builds the correct DAG #}
select null as _stub
{%- for spec in models %}
{%- if loop.first %}
from {{ ref(spec['name']) }}
{%- else %}
join {{ ref(spec['name']) }} on true
{%- endif %}
{%- endfor %}

{% endif %}
{% endmacro %}
