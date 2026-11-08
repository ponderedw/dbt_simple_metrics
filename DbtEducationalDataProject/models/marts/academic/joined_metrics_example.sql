{{ config(materialized='table') }}

{#
  Demonstrates join_metrics: combines metrics from course_performance_summary
  with dimensions from semester_enrollment_trends, joined on the shared
  semester_id entity (foreign → primary = many_to_one).

  Generated SQL:
    with
    a as (
      select semester_id, department_name, sum(total_enrollments) as total_course_enrollments, avg(avg_grade_points) as average_course_gpa
      from "db"."public"."course_performance_summary"
      group by 1, 2
    ),
    b as (
      select semester_id, semester_name, semester_type
      from "db"."public"."semester_enrollment_trends"
      group by 1, 2, 3
    )
    select a.department_name, a.total_course_enrollments, a.average_course_gpa, b.semester_name, b.semester_type
    from a
    join b on a.semester_id = b.semester_id
#}

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
