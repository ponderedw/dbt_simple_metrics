{{ config(materialized='table') }}

{{ dbt_simple_metrics.metrics(
    'semester_enrollment_trends',
    ['semester_name', 'academic_year'],
    ['total_semester_headcount', 'average_semester_gpa', 'deans_list_rate', 'courses_per_student']
) }}
