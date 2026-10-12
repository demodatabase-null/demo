-- Optional reviewer comments: approvals/rejections work with an empty comment.
-- Keeps the existing recursion-safe teacher_can_update_enrollment policy.

create or replace function public.log_appeal_change() returns trigger
language plpgsql security definer set search_path = public, auth
as $$
declare e record;
begin
  select en.student_id,st.user_id as student_user_id,off.teacher_id,t.user_id as teacher_user_id,c.course_code
    into e from public.enrollments en join public.students st using(student_id)
    join public.course_offerings off using(offering_id) join public.teachers t using(teacher_id)
    join public.courses c using(course_id) where en.enrollment_id=new.enrollment_id;
  if tg_op='INSERT' then
    insert into public.appeal_status_history(appeal_id,changed_by,old_status,new_status)
      values(new.appeals_id,public.app_user_id(),null,'pending');
    insert into public.notifications(appeal_id,user_id,massage)
      select new.appeals_id,u.user_id,'มีคำร้องใหม่ #'||new.appeals_id||' วิชา '||e.course_code||' รอเจ้าหน้าที่ยืนยัน' from public.users u where u.role='staff';
    insert into public.notifications(appeal_id,user_id,massage)
      values(new.appeals_id,e.teacher_user_id,'มีคำร้องใหม่ #'||new.appeals_id||' วิชา '||e.course_code||' รอเจ้าหน้าที่ยืนยัน');
  elsif old.status is distinct from new.status then
    insert into public.appeal_status_history(appeal_id,changed_by,old_status,new_status)
      values(new.appeals_id,public.app_user_id(),old.status,new.status);
    insert into public.notifications(appeal_id,user_id,massage)
      values(new.appeals_id,e.student_user_id,'สถานะคำร้อง #'||new.appeals_id||' เปลี่ยนเป็น '||new.status||case when new.staff_comment is distinct from old.staff_comment and new.staff_comment is not null then E'\nความคิดเห็นจากเจ้าหน้าที่: '||new.staff_comment when new.teacher_comment is distinct from old.teacher_comment and new.teacher_comment is not null then E'\nความคิดเห็นจากอาจารย์: '||new.teacher_comment else '' end);
    if new.status='reviewing' then
      insert into public.notifications(appeal_id,user_id,massage)
        values(new.appeals_id,e.teacher_user_id,'คำร้อง #'||new.appeals_id||' วิชา '||e.course_code||' รอพิจารณา');
    end if;
  end if;
  return new;
end $$;

create or replace function public.staff_respond_appeal(p_appeal_id bigint,p_decision text,p_comment text) returns void
language plpgsql security definer set search_path = public, auth
as $$
declare a public.grade_appeals%rowtype;
begin
  if not public.is_staff() or p_decision not in ('reviewing','rejected') then raise exception 'ไม่มีสิทธิ์ดำเนินการคำร้อง'; end if;
  select * into a from public.grade_appeals where appeals_id=p_appeal_id for update;
  if not found or a.status<>'pending' then raise exception 'คำร้องนี้ไม่ได้รอเจ้าหน้าที่ยืนยัน'; end if;
  update public.grade_appeals set status=p_decision,staff_comment=nullif(btrim(coalesce(p_comment,'')),'') where appeals_id=a.appeals_id;
end $$;
revoke all on function public.staff_respond_appeal(bigint,text,text) from public;
grant execute on function public.staff_respond_appeal(bigint,text,text) to authenticated;

create or replace function public.review_appeal(p_appeal_id bigint,p_decision text,p_new_grade text,p_comment text) returns void
language plpgsql security definer set search_path = public, auth
as $$
declare a public.grade_appeals%rowtype; e public.enrollments%rowtype; teacher_user bigint;
begin
  if public.app_role()<>'teacher' or p_decision not in ('approved','rejected') then raise exception 'ไม่มีสิทธิ์พิจารณาคำร้อง'; end if;
  select * into a from public.grade_appeals where appeals_id=p_appeal_id for update;
  if not found or a.status<>'reviewing' then raise exception 'คำร้องนี้ไม่ได้อยู่ระหว่างพิจารณา'; end if;
  select en.* into e from public.enrollments en where en.enrollment_id=a.enrollment_id for update;
  select t.user_id into teacher_user from public.course_offerings o join public.teachers t using(teacher_id) where o.offering_id=e.offering_id;
  if teacher_user<>public.app_user_id() then raise exception 'พิจารณาได้เฉพาะรายวิชาที่สอน'; end if;
  if p_decision='approved' and p_new_grade not in ('A','B+','B','C+','C','D+','D','F') then raise exception 'เกรดไม่ถูกต้อง'; end if;
  insert into public.appeal_reviews(reviewer_id,appeal_id,decision,new_grade)
    values(public.app_user_id(),a.appeals_id,p_decision,case when p_decision='approved' then p_new_grade else e.grade end);
  if p_decision='approved' and e.grade is distinct from p_new_grade then
    update public.enrollments set grade=p_new_grade where enrollment_id=e.enrollment_id;
    insert into public.grade_history(appeal_id,enrollment_id,old_grade,new_grade,changed_by)
      values(a.appeals_id,e.enrollment_id,e.grade,p_new_grade,public.app_user_id());
  end if;
  update public.grade_appeals set status=p_decision,teacher_comment=nullif(btrim(coalesce(p_comment,'')),'') where appeals_id=a.appeals_id;
end $$;
revoke all on function public.review_appeal(bigint,text,text,text) from public;
grant execute on function public.review_appeal(bigint,text,text,text) to authenticated;
