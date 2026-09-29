{{ config(materialized='table') }}

{{ dbt_simple_metrics.metrics(
    'stg_enrollments',
    ['grade_category', 'enrollment_status'],
    ['total_enrollments', 'avg_gpa', 'passing_enrollments', 'excellent_attendance_count']
) }}
