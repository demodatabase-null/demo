-- Staff-only reset for the dedicated demo student account.
-- It preserves accounts, courses, and enrollments; only demo appeal data is removed.

create or replace function public.reset_demo_student_data() returns integer
language plpgsql security definer set search_path = public, auth
as $$
declare
  demo_student_id bigint;
  demo_user_id bigint;
  demo_appeal_ids bigint[];
  removed_count integer;
begin
  if not public.is_staff() then raise exception 'รีเซ็ตได้เฉพาะบัญชีเจ้าหน้าที่'; end if;

  select u.user_id,s.student_id into demo_user_id,demo_student_id
    from public.users u join public.students s using(user_id)
    where u.username='student' and u.role='student';
  if demo_student_id is null then raise exception 'ไม่พบบัญชีนักศึกษาทดลอง'; end if;

  select coalesce(array_agg(a.appeals_id),array[]::bigint[])
    into demo_appeal_ids
    from public.grade_appeals a join public.enrollments e using(enrollment_id)
    where e.student_id=demo_student_id;
  removed_count := cardinality(demo_appeal_ids);

  delete from public.grade_history where appeal_id=any(demo_appeal_ids);
  delete from public.appeal_status_history where appeal_id=any(demo_appeal_ids);
  delete from public.appeal_reviews where appeal_id=any(demo_appeal_ids);
  delete from public.appeal_attachments where appeal_id=any(demo_appeal_ids);
  delete from public.notifications where appeal_id=any(demo_appeal_ids);
  delete from public.grade_appeals where appeals_id=any(demo_appeal_ids);

  update public.enrollments e set grade=case c.course_code
      when 'CS101' then 'B'
      when 'CS201' then 'C+'
      when 'CPE210' then 'B+'
      when 'MA101' then 'D'
      when 'CS305' then null
      when 'ENG101' then null
      else e.grade
    end
    from public.course_offerings o join public.courses c using(course_id)
    where e.offering_id=o.offering_id and e.student_id=demo_student_id
      and c.course_code in ('CS101','CS201','CPE210','MA101','CS305','ENG101');

  return coalesce(removed_count,0);
end $$;
revoke all on function public.reset_demo_student_data() from public;
grant execute on function public.reset_demo_student_data() to authenticated;

-- Allow staff to remove storage objects only when they belong to the demo student's appeals.
drop policy if exists "staff_delete_demo_evidence" on storage.objects;
create policy "staff_delete_demo_evidence" on storage.objects for delete to authenticated using (
  bucket_id='appeal-evidence' and public.is_staff() and exists(
    select 1 from public.appeal_attachments aa
    join public.grade_appeals a on a.appeals_id=aa.appeal_id
    join public.enrollments e on e.enrollment_id=a.enrollment_id
    join public.students s on s.student_id=e.student_id
    join public.users u on u.user_id=s.user_id
    where aa.storage_path=storage.objects.name and u.username='student' and u.role='student'
  )
);
