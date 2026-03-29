{{ config(materialized='table') }}

{{ dbt_simple_metrics.metrics(
    'course_performance_summary',
    ['course_code', 'course_name', 'academic_year'],
    ['average_course_gpa', 'total_course_enrollments', 'total_passing_students', 'enrollment_pass_rate']
) }}
