{# safe_divide(numerator, denominator) — divides two SQL expressions, returning NULL when denominator is 0 #}
{% macro safe_divide(numerator, denominator) %}
    {{ numerator }} / nullif({{ denominator }}, 0)
{%- endmacro %}
