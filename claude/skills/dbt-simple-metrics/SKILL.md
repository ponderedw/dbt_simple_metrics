---
name: dbt-simple-metrics
description: How to use dbt_simple_metrics macros to aggregate metrics defined in model YAML inside dbt SQL — covers metrics(), join_metrics(), metric types, sql field resolution, Format 3 inline MetricFlow, and field placement rules
---

# dbt_simple_metrics

A dbt package that turns metric definitions from your model YAML into aggregated SQL. Define metrics once in `config.meta.metrics` or inline MetricFlow format, then call them from any dbt model with a macro. Metric types are compatible with Cube measure types.

Requires v1.0.9+. Works with dbt 1.9+ and dbt-fusion 2.x.

## Installation

```yaml
# packages.yml
packages:
  - git: "https://github.com/ponderedw/dbt_simple_metrics.git"
    revision: v1.0.9
```

```bash
dbt deps
```

---

## `metrics()` — single-model aggregation

Generates a `SELECT … GROUP BY` from one model's metric definitions.

```sql
{{ dbt_simple_metrics.metrics(
    'orders',
    ['region', 'sales_channel'],
    ['total_revenue', 'order_count', 'avg_order_value']
) }}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `model_name` | string | dbt model name |
| `dimensions` | list[string] | columns to `SELECT` and `GROUP BY` |
| `metrics` | list[string] | metric names from `config.meta.metrics` |

Compile-time validation confirms every dimension exists under `columns:` and every metric exists under `config.meta.metrics`. Missing names raise a clear error listing what's available.

---

## `join_metrics()` — cross-model aggregation

Generates one CTE per model (pre-aggregated within that model's scope), then joins them on shared entity keys.

```sql
{{ dbt_simple_metrics.join_metrics([
    {
        'name': 'orders',
        'metrics': ['total_revenue', 'order_count'],
        'dimensions': ['region']
    },
    {
        'name': 'customers',
        'dimensions': ['customer_tier', 'signup_cohort']
    }
]) }}
```

An optional `filters` list adds WHERE clauses on the outer query:

```sql
{{ dbt_simple_metrics.join_metrics([...], filters=["b.status = 'active'"]) }}
```

**Join inference:** a join is generated between two models when their semantic model definitions share an entity name. The cardinality comes from the entity `type` on each side:

| Left type | Right type | Relationship |
|-----------|-----------|--------------|
| `foreign` | `primary` / `unique` | `many_to_one` |
| `primary` / `unique` | `foreign` | `one_to_many` |
| `primary` / `unique` | `primary` / `unique` | `one_to_one` |
| `foreign` | `foreign` | compile error — many-to-many unsupported |

If no shared entity exists, the macro raises an error naming the entities available on each side.

---

## Defining metrics in YAML

**Default: use Format 3 (inline MetricFlow, dbt 1.9+ / dbt-fusion 2.x).** Use `config.meta.metrics` (Format 1) only when the project is on an older dbt version or has not adopted inline MetricFlow.

### Format 3 — inline MetricFlow (preferred)

Metrics are listed directly under `metrics:` on the model. Columns carry their `entity:` or `dimension:` roles.

```yaml
models:
  - name: orders
    description: "One row per order."

    semantic_model:
      enabled: true

    agg_time_dimension: created_at

    columns:
      - name: order_id
        entity:
          type: primary
        config:
          meta:
            primary-key: true

      - name: customer_id
        entity:
          type: foreign

      - name: created_at
        granularity: day
        dimension:
          type: time

      - name: region
        description: "Sales region."
        dimension:
          type: categorical
        config:
          meta:
            label: "Region"

      - name: order_amount
        description: "Order total in USD."

    metrics:
      - name: total_revenue
        label: "Total Revenue"
        description: "Sum of all order amounts."
        type: simple
        agg: sum
        expr: order_amount

      - name: order_count
        label: "Order Count"
        description: "Number of orders."
        type: simple
        agg: count
        expr: order_id

      - name: return_rate
        label: "Return Rate"
        description: "Returned orders as a share of total orders."
        type: ratio
        numerator: returned_orders
        denominator: order_count
        config:
          meta:
            format: "percent"
```

### Format 1 — `config.meta.metrics` (legacy / older dbt versions)

Metrics live under `config.meta.metrics`. Each key is the metric name.

```yaml
models:
  - name: orders
    columns:
      - name: region
        description: "Sales region."
      - name: order_amount
        description: "Order total in USD."

    config:
      meta:
        metrics:
          total_revenue:
            type: sum
            label: "Total Revenue"
            description: "Sum of all order amounts."
            sql: ${order_amount}

          order_count:
            type: count
            label: "Order Count"
            description: "Number of orders."

          return_rate:
            type: number
            label: "Return Rate"
            description: "Returned orders divided by total orders."
            sql: ${returned_orders} / nullif(${order_count}, 0)
```

**`sql` field resolution:**
- `${name}` where `name` is a column → the column name
- `${name}` where `name` is another metric → that metric's full aggregation SQL (supports chaining)
- `[[ macro_call(...) ]]` → evaluated as Jinja2 after `${}` resolution (use this instead of `{{ }}` because dbt renders `{{ }}` in YAML at parse time)
- Circular references are detected at compile time

The package ships `dbt_simple_metrics.safe_divide(num, den)` as a ready-to-use utility.

---

## Metric types

### Aggregation types

| Type | SQL generated |
|------|--------------|
| `sum` | `SUM(expr)` |
| `avg` / `average` | `AVG(expr)` |
| `min` | `MIN(expr)` |
| `max` | `MAX(expr)` |
| `count` | `COUNT(*)` |
| `count_distinct` | `COUNT(DISTINCT expr)` |
| `count_distinct_approx` | `APPROX_COUNT_DISTINCT(expr)` |

### Passthrough types (no wrapping aggregate)

| Type | Use for |
|------|---------|
| `number` | arithmetic over other metrics |
| `number_agg` | custom aggregate functions |
| `string` / `boolean` / `time` | aggregated non-numeric expressions |

---

## Format 3 — inline MetricFlow (dbt 1.9+ / dbt-fusion 2.x)

Both macros also work when metrics are defined inline on the model using the native MetricFlow format instead of `config.meta.metrics`.

**Field placement rules for Format 3:**

| Field | Placement | Reason |
|-------|-----------|--------|
| `label` on a metric | directly on the metric | native dbt field, compiled into the manifest |
| `label` on a column | `config.meta.label` | placing it directly on a column raises a dbt deprecation warning |
| `description` | directly on metric or column | native dbt field |
| `format` | `config.meta.format` | custom field, not native dbt — `"percent"` or `"currency"` |
| `filter` on a metric | directly on the metric | native MetricFlow field — `{{ Dimension('entity__col') }} = 'val'` |

```yaml
metrics:
  - name: active_orders
    label: "Active Orders"
    description: "Orders in an active state."
    type: simple
    agg: count
    expr: 1
    filter: "{{ Dimension('order__status') }} = 'active'"   # top-level, native MetricFlow

columns:
  - name: region
    description: "Sales region."
    dimension:
      type: categorical
    config:
      meta:
        label: "Region"
```

**Entity definition for `join_metrics`:**

```yaml
columns:
  - name: order_id
    entity:
      type: primary
      name: order           # logical entity name used for join detection

  - name: customer_id
    entity:
      type: foreign
      name: customer        # matches the primary entity named 'customer' on another model
```

**Native metric types in Format 3:**

```yaml
# simple
- name: total_orders
  type: simple
  agg: count
  expr: 1

# ratio
- name: return_rate
  type: ratio
  numerator: returned_orders
  denominator: total_orders

# derived
- name: revenue_per_order
  type: derived
  expr: total_revenue / total_orders
  input_metrics:
    - name: total_revenue
    - name: total_orders

# cumulative (running total)
- name: cumulative_revenue
  type: cumulative
  input_metric: total_revenue
```

---

## Rules

- Every metric must have a `label:` and a `description:`. They appear in BI tools and power semantic search.
- Use `config.meta.metrics` (Format 1) unless the project is on dbt 1.9+ and has adopted inline MetricFlow.
- Do not mix top-level `semantic_models:` blocks with Format 3 inline metrics in the same project under dbt-fusion — migrate all to inline first.
