# dbt_simple_metrics

A dbt package that generates aggregated SQL from metric definitions in your model YAML files. Define your metrics once in `models.yml`, then reuse them across models with a single macro call.

Metric types are compatible with [Cube](https://cube.dev/) measure types.

## Installation

Add to your project's `packages.yml`:

```yaml
packages:
  - git: "https://github.com/ponderedw/dbt_simple_metrics.git"
    revision: v1.0.9
```

Then run:

```bash
dbt deps   # or: dbtf deps
```

### dbt version compatibility

| dbt version | Format 1 `config.meta.metrics` | Format 3 inline MetricFlow |
|-------------|-------------------------------|---------------------------|
| dbt 1.x | Yes | Yes (1.9+) |
| dbt-fusion 2.x | Yes | Yes (v1.0.9+) |

**dbt-fusion note:** both macros work with inline Format 3 (v1.0.9+). They will not
work if any YAML in the project retains a top-level `semantic_models:` block — migrate
those to inline Format 3.

## Quick Start

### 1. Define columns and metrics in your model's YAML

Metrics live under `config.meta.metrics` in your model's schema YAML file (e.g., `models/models.yml`). Columns defined under `columns` serve as the available dimensions.

```yaml
version: 2
models:
  - name: course_performance_summary
    columns:
      - name: course_code
        description: "Course code (e.g., CS101, MATH201)"
      - name: course_name
        description: "Full name of the course"
      - name: academic_year
        description: "Academic year of the course offering"
      - name: avg_grade_points
        description: "Average grade points achieved by students"
      - name: total_enrollments
        description: "Total number of students enrolled"

    config:
      meta:
        metrics:
          average_course_gpa:
            type: average
            label: "Average Course GPA"
            sql: ${avg_grade_points}
          total_course_enrollments:
            type: sum
            label: "Total Course Enrollments"
            sql: ${total_enrollments}
```

### 2. Call the macro from a model

```sql
-- models/marts/academic/course_metrics_example.sql
{{ config(materialized='table') }}

{{ dbt_simple_metrics.metrics(
    'course_performance_summary',
    ['course_code', 'course_name', 'academic_year'],
    ['average_course_gpa', 'total_course_enrollments']
) }}
```

### 3. Run dbt

```bash
dbt run --select course_metrics_example
```

Generated SQL:

```sql
select
    course_code,
    course_name,
    academic_year,
    avg(avg_grade_points) as average_course_gpa,
    sum(total_enrollments) as total_course_enrollments
from "education_dw"."public"."course_performance_summary"
group by 1, 2, 3
```

## Macro Reference

### `dbt_simple_metrics.join_metrics(models, filters=[])`

Cross-model metric query with automatic join inference. Select metrics and dimensions from multiple models — if the semantic models share an entity name, the join is generated automatically. If not, a compile-time error tells you exactly which entities are available on each side.

| Parameter | Type | Description |
|-----------|------|-------------|
| `models` | `list[dict]` | Each dict: `name` (model), `metrics` (list), `dimensions` (list) |
| `filters` | `list[string]` | Optional WHERE clauses on the outer query |

**Example:**

```sql
-- models/marts/academic/joined_metrics_example.sql
{{ config(materialized='table') }}

{{ dbt_simple_metrics.join_metrics([
    {
        'name': 'course_performance_summary',
        'metrics': ['total_course_enrollments', 'average_course_gpa'],
        'dimensions': ['department_name']
    },
    {
        'name': 'semester_enrollment_trends',
        'dimensions': ['semester_name', 'semester_type']
    }
]) }}
```

Generated SQL:

```sql
with
a as (
    select
        semester_id,
        department_name,
        sum(total_enrollments) as total_course_enrollments,
        avg(avg_grade_points) as average_course_gpa
    from "education_dw"."public"."course_performance_summary"
    group by 1, 2
),
b as (
    select
        semester_id,
        semester_name,
        semester_type
    from "education_dw"."public"."semester_enrollment_trends"
    group by 1, 2, 3
)
select
    a.department_name,
    a.total_course_enrollments,
    a.average_course_gpa,
    b.semester_name,
    b.semester_type
from a
join b on a.semester_id = b.semester_id
```

The macro uses one CTE per model that pre-aggregates within that model's scope, then joins the CTEs. This eliminates column ambiguity and ensures metrics are computed on the correct grain before joining.

**How joins are inferred:**

A join is created between two consecutive models when their semantic model definitions share an entity name. The relationship type is determined by the entity `type` on each side:

| Left entity type | Right entity type | Relationship |
|-----------------|------------------|--------------|
| `foreign` | `primary` / `unique` | `many_to_one` |
| `primary` / `unique` | `foreign` | `one_to_many` |
| `primary` / `unique` | `primary` / `unique` | `one_to_one` |
| `foreign` | `foreign` | error — `many_to_many` unsupported |

```yaml
# semantic_models.yml — the shared entity name drives join detection
semantic_models:
  - name: semantic_course_performance
    model: ref('course_performance_summary')
    entities:
      - name: course_id
        type: primary
      - name: semester_id      # ← foreign key; matches semantic_semester_enrollment's primary
        type: foreign

  - name: semantic_semester_enrollment
    model: ref('semester_enrollment_trends')
    entities:
      - name: semester_id      # ← primary key; shared name triggers join
        type: primary
```

**When no join is defined:**

```
Compilation Error
  join_metrics: No join defined between 'course_performance_summary' and 'student_grades'.
    Entities in 'course_performance_summary': [course_id, semester_id]
    Entities in 'student_grades': [student_id, section_id]
    Hint: a join exists when both semantic models share an entity name.
    Add a matching entity (e.g. foreign key) to one of the semantic models.
```

**Many-to-many (not supported):**

Both `foreign → foreign` joins cannot be expressed as a direct SQL `JOIN` without fan-out. The macro raises a compile-time error and tells you to introduce a bridge/junction model.

**Optional filters:**

```sql
{{ dbt_simple_metrics.join_metrics([
    {'name': 'course_performance_summary', 'metrics': ['total_course_enrollments'], 'dimensions': ['department_name']},
    {'name': 'semester_enrollment_trends', 'dimensions': ['semester_name']}
], filters=["b.semester_type = 'Fall'"]) }}
```

---

### `dbt_simple_metrics.metrics(model_name, dimensions, metrics)`

| Parameter    | Type           | Description                                          |
|-------------|----------------|------------------------------------------------------|
| `model_name` | `string`       | Name of the dbt model (must exist in the YAML file)  |
| `dimensions` | `list[string]` | Column names to `SELECT` and `GROUP BY`              |
| `metrics`    | `list[string]` | Metric names defined under `config.meta.metrics`     |

The macro validates at compile time that:
- The model exists in the dbt graph
- Every requested dimension is defined under `columns`
- Every requested metric is defined under `config.meta.metrics`

If validation fails, a clear compile-time error is raised listing the available options.

## Where to Write What

### Dimensions (columns)

Dimensions are the columns you want to group by. They are defined under the `columns` key of your model in the schema YAML:

```yaml
models:
  - name: my_model
    columns:                        # <-- dimensions come from here
      - name: department_name
        description: "..."
      - name: semester_name
        description: "..."
      - name: total_enrollments     # a column can be both a dimension and used in a metric
        description: "..."
```

Any column listed here can be passed as a dimension to the macro. You only select the ones you need per query.

### Metrics (measures)

Metrics define how columns are aggregated. They are defined under `config.meta.metrics` in the same YAML file:

```yaml
models:
  - name: my_model
    columns:
      # ...
    config:
      meta:
        metrics:                    # <-- metrics go here
          my_metric_name:
            type: sum               # aggregation type (see table below)
            label: "Human Label"    # display label (optional)
            format: "0.00"          # number format (optional)
            sql: ${column_name}     # expression to aggregate
```

### Metric `sql` field

The `sql` field uses `${name}` syntax. Each `${name}` is resolved as follows:

- If `name` matches another metric defined in the same model, it is replaced with that metric's fully-wrapped aggregation SQL.
- Otherwise it is treated as a column name from the model.

**Column reference:**
```yaml
sql: ${total_enrollments}          # becomes: total_enrollments
```

**Arithmetic expression:**
```yaml
sql: ${pass_rate_percentage} / 100 # becomes: pass_rate_percentage / 100
```

**Multi-column expression:**
```yaml
sql: (${avg_attendance} * 0.6 + ${avg_grade_points} * 25)
```

**Measure reference** — `${name}` where `name` is another metric:
```yaml
metrics:
  total_passing_students:
    type: sum
    sql: ${passing_grades}          # column reference → sum(passing_grades)

  total_course_enrollments:
    type: sum
    sql: ${total_enrollments}       # column reference → sum(total_enrollments)

  enrollment_pass_rate:
    type: number                    # passthrough — no outer aggregation
    sql: ${total_passing_students} / nullif(${total_course_enrollments}, 0)
    # resolves to: sum(passing_grades) / nullif(sum(total_enrollments), 0)
```

Circular measure references are detected at compile time and raise an error.

**Macro call** — `[[ macro_name(...) ]]` anywhere in the sql field:

`${...}` references are resolved first, then `[[ ]]` delimiters are converted to `{{ }}` and evaluated via dbt's Jinja renderer at execution time. This lets you call any dbt macro with already-resolved column or measure SQL as arguments.

> `[[ ]]` is used instead of `{{ }}` because dbt renders `{{ }}` in YAML values at parse time, before this macro runs, which means `{{ }}` expressions can't reference dbt macros reliably. `[[ ]]` is treated as a plain string by the YAML parser and is only evaluated later when the full macro context is available.

```yaml
metrics:
  enrollment_pass_rate:
    type: number
    sql: "[[ dbt_simple_metrics.safe_divide('${total_passing_students}', '${total_course_enrollments}') ]]"
    # resolves to: sum(passing_grades) / nullif(sum(total_enrollments), 0)
```

The package ships with `dbt_simple_metrics.safe_divide(numerator, denominator)` as a ready-to-use utility. You can also call any macro from your own project or installed packages the same way.

## Supported Metric Types

All types are compatible with [Cube measure types](https://cube.dev/docs/product/data-modeling/reference/types-and-formats#measure-types).

### Aggregation types

| Type                     | Generated SQL                          | Description                          |
|--------------------------|----------------------------------------|--------------------------------------|
| `sum`                    | `SUM(expression)`                      | Sum of values                        |
| `avg` / `average`        | `AVG(expression)`                      | Average of values                    |
| `min`                    | `MIN(expression)`                      | Minimum value                        |
| `max`                    | `MAX(expression)`                      | Maximum value                        |
| `count`                  | `COUNT(*)`                             | Row count                            |
| `count_distinct`         | `COUNT(DISTINCT expression)`           | Distinct value count                 |
| `count_distinct_approx`  | `APPROX_COUNT_DISTINCT(expression)`    | Approximate distinct count           |

### Passthrough types

These types pass the `sql` expression through without wrapping it in an aggregate function. Use them for pre-aggregated or custom expressions.

| Type         | Description                              |
|-------------|------------------------------------------|
| `number`     | Arbitrary aggregated numeric expression  |
| `number_agg` | Custom aggregate function                |
| `string`     | Aggregated string expression             |
| `boolean`    | Aggregated boolean expression            |
| `time`       | Aggregated timestamp expression          |

## Full YAML Example

```yaml
version: 2
models:
  - name: course_performance_summary
    columns:
      - name: course_id
        description: "Unique identifier for the course"
      - name: course_code
        description: "Course code (e.g., CS101, MATH201)"
      - name: course_name
        description: "Full name of the course"
      - name: department_name
        description: "Academic department offering the course"
      - name: academic_year
        description: "Academic year of the course offering"
      - name: total_enrollments
        description: "Total number of students enrolled"
      - name: avg_grade_points
        description: "Average grade points achieved by students"
      - name: avg_attendance
        description: "Average attendance percentage"
      - name: pass_rate_percentage
        description: "Percentage of students who passed"
      - name: performance_category
        description: "Overall performance category"

    config:
      meta:
        metrics:
          average_course_gpa:
            type: average
            label: "Average Course GPA"
            format: "0.00"
            sql: ${avg_grade_points}

          course_pass_rate:
            type: average
            label: "Course Pass Rate"
            format: "0.0%"
            sql: ${pass_rate_percentage} / 100

          total_course_enrollments:
            type: sum
            label: "Total Course Enrollments"
            sql: ${total_enrollments}

          student_engagement_score:
            type: average
            label: "Student Engagement Score"
            format: "0.0"
            sql: (${avg_attendance} * 0.6 + ${avg_grade_points} * 25)
```

## Validation Errors

The macro raises clear errors at compile time if something is wrong.

**Unknown dimension:**
```
dbt_simple_metrics: Dimension 'nonexistent' is not defined in the columns
of model 'course_performance_summary'.
Available columns: course_id, course_code, course_name, ...
```

**Unknown metric:**
```
dbt_simple_metrics: Metric 'bad_metric' is not defined in the metrics
of model 'course_performance_summary'.
Available metrics: average_course_gpa, course_pass_rate, ...
```

**No metrics defined:**
```
dbt_simple_metrics: Model 'my_model' has no metrics defined in config.meta.metrics.
```

## dbt v2 Native MetricFlow Format

dbt 1.6+ supports defining metrics and semantic models directly inline on a model, without `config.meta.metrics`. Both macros (`metrics` and `join_metrics`) support this format.

### Field placement rules

| Field | Where it goes | Reason |
|---|---|---|
| `label` on a **metric** | directly on the metric | native dbt MetricFlow field — compiled into the manifest |
| `label` on a **column** | `config.meta.label` | dbt does not support `label` as a native column field — raises a deprecation warning if placed directly |
| `description` | directly on metric or column | native dbt field |
| `format` | `config.meta.format` | custom field read by dbt-cube-sync, not a native dbt field |
| `filter` | `config.meta.filter` | custom field read by dbt-cube-sync, not a native dbt field |

```yaml
# Metrics — label goes directly on the metric
metrics:
  - name: total_revenue
    label: "Total Revenue (USD)"        # ← direct field on metric (valid)
    description: "Sum of all orders"
    type: simple
    agg: sum
    expr: order_amount
    config:
      meta:
        format: "currency"              # ← config.meta only

  - name: us_orders
    label: "US Orders"                  # ← direct field on metric (valid)
    description: "Orders from the US only"
    type: simple
    agg: count
    expr: 1
    config:
      meta:
        filter: "${CUBE}.country = 'US'"  # ← config.meta only

# Columns — label must go under config.meta
columns:
  - name: customer_segment
    description: "Business segment"
    dimension:
      type: categorical
    config:
      meta:
        label: "Customer Segment"       # ← config.meta (direct label on column raises deprecation warning)
```

Metrics with only a `label` and no `format`/`filter` need no `config.meta` block at all.

### Entities: primary and foreign keys

Entities are defined inline on columns using the `entity:` key. The `name` is the logical entity name used for join detection — it does not have to match the column name.

```yaml
models:
  - name: orders
    columns:
      - name: order_id
        entity:
          type: primary
          name: order         # logical entity name

      - name: customer_id
        entity:
          type: foreign
          name: customer      # matches customers.customer_id's primary entity

      - name: product_id
        entity:
          type: foreign
          name: product

  - name: customers
    columns:
      - name: customer_id
        entity:
          type: primary
          name: customer      # shared name 'customer' triggers the join
```

Entity types determine the join cardinality when using `join_metrics`:

| Left type | Right type | Relationship |
|---|---|---|
| `foreign` | `primary` / `unique` | `many_to_one` |
| `primary` / `unique` | `foreign` | `one_to_many` |
| `primary` / `unique` | `primary` / `unique` | `one_to_one` |
| `foreign` | `foreign` | error — `many_to_many` unsupported |

### Supported `format` values

| Value | Effect in Cube |
|---|---|
| `"currency"` | Renders as `$1,234.56` |
| `"percent"` | Renders as `12.3%` |

### Metric types in native format

```yaml
# Simple (single-model aggregation)
- name: total_orders
  type: simple
  agg: count      # sum | count | count_distinct | avg | min | max
  expr: 1

# Ratio (numerator / denominator, both must be defined metrics)
- name: return_rate
  type: ratio
  numerator: returned_orders
  denominator: total_orders

# Derived (expression over other metrics)
- name: revenue_per_customer
  type: derived
  expr: total_revenue / unique_customers
  input_metrics:
    - name: total_revenue
    - name: unique_customers

# Cumulative (running total over the agg_time_dimension)
- name: cumulative_revenue
  type: cumulative
  input_metric: total_revenue
```

---

## dbt-fusion 2.x compatibility

**v1.0.9** fixes Format 3 inline metrics under dbt-fusion 2.x. dbt-fusion renamed
`metric.type` → `metric.metric_type` in the Jinja graph context. All earlier versions
silently ignored this, causing filtered metrics (e.g. `us_orders` with
`filter: "{{ Dimension('order__country') }} = 'US'"`) to compile as bare `count(*)`
instead of `count(case when country = 'US' then 1 end)`.

The fix is backward compatible — `metric.type` is checked first, `metric.metric_type`
is the fallback.

## How It Works

Both macros use dbt's `graph` context variable (available during execution):

### `metrics` (single model)

1. Finds the model node in `graph.nodes` by name
2. Reads `columns` for dimension validation
3. Reads `config.meta.metrics` for metric definitions (falls back to MetricFlow `graph.semantic_models` / `graph.metrics` if `config.meta.metrics` is empty)
4. Validates all requested dimensions and metrics exist
5. Generates a `SELECT` with proper aggregation functions and `GROUP BY`

### `join_metrics` (multiple models)

1. For each model, locates its MetricFlow semantic model in `graph.semantic_models`
2. Reads the `entities:` list from each semantic model to build a join key index
3. Checks consecutive model pairs for a shared entity name — that shared name becomes the `ON` condition
4. Infers cardinality (`many_to_one`, `one_to_one`, etc.) from the entity `type` on each side
5. Generates one CTE per model that pre-aggregates metrics within that model's own scope
6. Joins the CTEs in the outer `SELECT`

During the DAG resolution phase (`execute=False`), a stub query with `ref()` calls for all models is returned so dbt can correctly resolve dependencies.
