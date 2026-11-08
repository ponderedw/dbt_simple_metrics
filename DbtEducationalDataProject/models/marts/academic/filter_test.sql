{{ config(materialized='table') }}

{{ dbt_simple_metrics.join_metrics([
    {
        'name': 'course_performance_summary',
        'metrics': ['total_course_enrollments', 'high_performance_enrollments'],
        'dimensions': ['department_name']
    },
    {
        'name': 'semester_enrollment_trends',
        'dimensions': ['semester_name']
    }
]) }}
