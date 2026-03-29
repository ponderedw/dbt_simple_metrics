# dbt_simple_metrics

A dbt package that generates aggregated SQL from metric definitions in your model YAML files. Define your metrics once in `models.yml`, then reuse them across models with a single macro call.

Metric types are compatible with [Cube](https://cube.dev/) measure types.

## Installation

Add to your project's `packages.yml`:

```yaml
packages:
  - local: ..            # local path
  # or from git:
  # - git: "https://github.com/ponderedw/dbt_simple_metrics.git"
  #   revision: main
```

Then run:

```bash
dbt deps
```

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

## How It Works

The macro uses dbt's `graph` context variable (available during execution) to look up the target model's YAML metadata:

1. Finds the model node in `graph.nodes` by name
2. Reads `columns` for dimension validation
3. Reads `config.meta.metrics` for metric definitions
4. Validates all requested dimensions and metrics exist
5. Generates a `SELECT` with proper aggregation functions and `GROUP BY`

During the DAG resolution phase (`execute=False`), a stub query with `ref()` is returned so dbt can correctly resolve model dependencies.
