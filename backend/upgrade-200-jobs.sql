-- 기존 40종 버전을 설치한 프로젝트에서 실행하세요. 저장 기록은 삭제하지 않습니다.
begin;
alter table career_private.votes drop constraint if exists votes_job_check;
alter table career_private.votes add constraint votes_job_check check(job between 1 and 200);
create or replace function public.career_api(p_action text, p_data jsonb default '{}'::jsonb, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 teacher uuid; sid uuid; cid uuid; cls career_private.classes%rowtype; stu career_private.students%rowtype;
 out_data jsonb; rows_data jsonb; vote_data jsonb; creds jsonb := '[]';
 entry jsonb; field text; pin text; token text; nm text; n int; k int; q int;
 jid int; tid uuid; idx int; dest_idx int; ids uuid[]; candidates int[]; top_count int;
 items jsonb; submitted boolean; current_jobs int[]; next_jobs int[];
begin
 if octet_length(p_data::text)>50000 then return jsonb_build_object('error','입력 내용이 너무 큽니다.'); end if;
 select t.user_id into teacher from career_private.teachers t where t.user_id=auth.uid();
 if p_token is not null then
   select s.student_id into sid from career_private.sessions s
    where s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and s.expires>now();
 end if;

 if p_action='lookup' then
   select * into cls from career_private.classes where code=upper(trim(p_data->>'code'));
   if cls.id is null then return jsonb_build_object('error','참여 코드를 확인해 주세요.'); end if;
   select coalesce(jsonb_agg(jsonb_build_object('id',id,'no',no,'name',name) order by no),'[]') into rows_data from career_private.students where class_id=cls.id;
   return jsonb_build_object('id',cls.id,'name',cls.name,'students',rows_data);
 end if;
 if p_action='student_login' then
   select * into stu from career_private.students where id=(p_data->>'sid')::uuid and class_id=(p_data->>'classId')::uuid for update;
   if stu.id is null then return jsonb_build_object('error','이름과 접속 번호를 확인해 주세요.'); end if;
   if stu.locked_until>now() then return jsonb_build_object('error','여러 번 잘못 입력했어요. 5분 후 다시 시도하거나 선생님께 번호 재발급을 요청하세요.'); end if;
   if stu.pin_hash<>extensions.crypt(coalesce(p_data->>'pin',''),stu.pin_hash) then
     update career_private.students set failures=case when stu.locked_until is not null and stu.locked_until<=now() then 1 else failures+1 end,
       locked_until=case when (stu.locked_until is null or stu.locked_until>now()) and failures>=4 then now()+interval '5 minutes' else null end where id=stu.id;
     return jsonb_build_object('error','이름과 개인 접속 번호를 확인해 주세요.');
   end if;
   update career_private.students set failures=0,locked_until=null where id=stu.id;
   token=encode(extensions.gen_random_bytes(32),'hex');
   delete from career_private.sessions where expires<now();
   insert into career_private.sessions(token_hash,student_id) values(encode(extensions.digest(token,'sha256'),'hex'),stu.id);
   return jsonb_build_object('token',token,'sid',stu.id,'classId',stu.class_id,'role','student');
 end if;
 if teacher is null and sid is null then return jsonb_build_object('error','접속이 만료되었거나 권한이 없습니다. 다시 로그인해 주세요.'); end if;
 if p_action='logout' then
   delete from career_private.sessions where token_hash=encode(extensions.digest(p_token,'sha256'),'hex');
   return jsonb_build_object('ok',true);
 end if;
 if p_action='list' then
   if teacher is null then raise exception '교사만 사용할 수 있습니다.'; end if;
   select coalesce(jsonb_agg(x order by x->>'name'),'[]') into out_data from (
    select jsonb_build_object('id',c.id,'name',c.name,'stage',c.stage,'count',(select count(*) from career_private.students s where s.class_id=c.id)) x
    from career_private.classes c where c.owner_id=teacher) a;
   return out_data;
 end if;
 if p_action='create' then
   if teacher is null then raise exception '교사만 사용할 수 있습니다.'; end if;
   nm=trim(p_data->>'name');
   if nm is null or length(nm) not between 1 and 60 then raise exception '학급명은 1~60자로 입력하세요.'; end if;
   insert into career_private.classes(owner_id,name,code) values(teacher,nm,upper(encode(extensions.gen_random_bytes(5),'hex'))) returning * into cls;
   return jsonb_build_object('id',cls.id,'name',cls.name);
 end if;
 cid=(p_data->>'classId')::uuid;
 if cid is null and sid is not null then select class_id into cid from career_private.students where id=sid; end if;
 -- Mutations serialize at class level to keep stage transitions, roster and votes consistent.
 select * into cls from career_private.classes where id=cid for update;
 if cls.id is null then raise exception '학급을 찾을 수 없습니다.'; end if;
 if teacher is not null then
   if cls.owner_id<>teacher then raise exception '다른 교사의 학급에는 접근할 수 없습니다.'; end if;
 else
   select * into stu from career_private.students where id=sid;
   if stu.class_id<>cid then raise exception '다른 반에는 접근할 수 없습니다.'; end if;
 end if;
 if p_action='status' then return jsonb_build_object('stage',cls.stage); end if;
 if p_action='get' then
   select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'no',s.no,'name',s.name,
     'choice',case when teacher is not null or s.id=sid or (cls.stage>=2 and (s.choice->>'submitted')::boolean) then s.choice else null end,
     'research',case when teacher is not null or s.id=sid then s.research else null end) order by s.no),'[]') into rows_data
     from career_private.students s where s.class_id=cid;
   select coalesce(jsonb_agg(jsonb_build_object('from',case when teacher is not null or v.from_id=sid then v.from_id else null end,
     'to',v.to_id,'job',v.job,'reason',v.reason,'hidden',v.hidden)),'[]') into vote_data
     from career_private.votes v join career_private.students s on s.id=v.from_id
     where s.class_id=cid and (teacher is not null or v.from_id=sid or (cls.stage>=3 and v.to_id=sid and not v.hidden));
   return jsonb_build_object('id',cls.id,'name',cls.name,'code',cls.code,'stage',cls.stage,'quota',cls.quota,'links',cls.links,'students',rows_data,'votes',vote_data);
 end if;
 if p_action in ('roster','rename','reset_pin','stage','settings','moderate','delete','delete_student') then
   if teacher is null then raise exception '교사만 사용할 수 있습니다.'; end if;
   if p_action='roster' then
     if cls.stage<>1 then raise exception '학생 추가는 1단계에서만 가능합니다.'; end if;
     if exists(select 1 from career_private.votes v join career_private.students s on s.id=v.from_id where s.class_id=cid) then raise exception '추천 시작 후에는 명단을 추가할 수 없습니다.'; end if;
     if jsonb_typeof(p_data->'names') is distinct from 'array' then raise exception '명단 형식이 올바르지 않습니다.'; end if;
     select count(*),coalesce(max(no),0) into k,n from career_private.students where class_id=cid;
     if jsonb_array_length(p_data->'names')+k>40 then raise exception '학급당 최대 40명까지 등록할 수 있습니다.'; end if;
     for nm in select jsonb_array_elements_text(p_data->'names') loop
       nm=trim(nm); if length(nm) not between 1 and 40 then raise exception '학생 이름은 1~40자로 입력하세요.'; end if;
       n=n+1;pin=(10000000+(('x'||encode(extensions.gen_random_bytes(4),'hex'))::bit(32)::bigint % 90000000)::int)::text;
       insert into career_private.students(class_id,no,name,pin_hash) values(cid,n,nm,extensions.crypt(pin,extensions.gen_salt('bf')));
       creds=creds||jsonb_build_array(jsonb_build_object('no',n,'name',nm,'pin',pin));
     end loop;
     return creds;
   elsif p_action in ('rename','reset_pin') then
     select * into stu from career_private.students where id=(p_data->>'sid')::uuid and class_id=cid;
     if stu.id is null then raise exception '학생을 찾을 수 없습니다.'; end if;
     if p_action='rename' then
       nm=trim(p_data->>'name');if nm is null or length(nm) not between 1 and 40 then raise exception '학생 이름은 1~40자로 입력하세요.'; end if;
       update career_private.students set name=nm where id=stu.id;
     else
       pin=(10000000+(('x'||encode(extensions.gen_random_bytes(4),'hex'))::bit(32)::bigint % 90000000)::int)::text;
       update career_private.students set pin_hash=extensions.crypt(pin,extensions.gen_salt('bf')),failures=0,locked_until=null where id=stu.id;
       delete from career_private.sessions where student_id=stu.id;
       return jsonb_build_object('no',stu.no,'name',stu.name,'pin',pin);
     end if;
   elsif p_action='delete_student' then
     if cls.stage<>1 or exists(select 1 from career_private.votes v join career_private.students s on s.id=v.from_id where s.class_id=cid) then raise exception '명단 삭제는 추천 시작 전 1단계에서만 가능합니다.'; end if;
     delete from career_private.students where id=(p_data->>'sid')::uuid and class_id=cid;
   elsif p_action='stage' then
     n=(p_data->>'stage')::int;
     if n is null or n not between 1 and 5 then raise exception '잘못된 단계입니다.'; end if;
     if n=1 and exists(select 1 from career_private.votes v join career_private.students s on s.id=v.from_id where s.class_id=cid) then raise exception '추천 시작 후에는 희망 직업을 변경할 수 없습니다.'; end if;
     update career_private.classes set stage=n where id=cid;
   elsif p_action='settings' then
     q=(p_data->>'quota')::int;
     if q is null or q not between 1 and 39 or length(coalesce(p_data->>'links',''))>4000 then raise exception '설정 값을 확인하세요.'; end if;
     if q<>cls.quota and exists(select 1 from career_private.votes v join career_private.students s on s.id=v.from_id where s.class_id=cid) then raise exception '추천 시작 후에는 배정 수를 변경할 수 없습니다.'; end if;
     nm=coalesce(trim(p_data->>'name'),cls.name);
     if length(nm) not between 1 and 60 then raise exception '학급명은 1~60자로 입력하세요.'; end if;
     update career_private.classes set quota=q,links=coalesce(p_data->>'links',''),name=nm where id=cid;
   elsif p_action='moderate' then
     if not exists(select 1 from career_private.students where id=(p_data->>'from')::uuid and class_id=cid) then raise exception '학급 정보를 확인하세요.'; end if;
     update career_private.votes set hidden=coalesce((p_data->>'hidden')::boolean,false) where from_id=(p_data->>'from')::uuid and to_id=(p_data->>'to')::uuid;
   elsif p_action='delete' then delete from career_private.classes where id=cid;
   end if;
   return jsonb_build_object('ok',true);
 end if;
 if teacher is not null or sid is null then raise exception '학생으로 입장해 주세요.'; end if;
 submitted=coalesce((p_data->>'submitted')::boolean,false);
 if p_action in ('choice','vote') then
   jid=(p_data->>'job')::int;nm=p_data->>'reason';
   if jid is null or jid not between 1 and 200 or nm is null or length(nm)>500 then raise exception '직업과 이유를 확인해 주세요.'; end if;
   if (submitted or p_action='vote') and length(trim(nm))=0 then raise exception '이유를 작성해 주세요.'; end if;
 end if;
 if p_action='choice' then
   if cls.stage<>1 then raise exception '지금은 희망 직업을 수정할 수 없습니다.'; end if;
   update career_private.students set choice=jsonb_build_object('job',jid,'reason',nm,'submitted',submitted) where id=sid;
 elsif p_action='vote' then
   if cls.stage<>2 then raise exception '친구 추천 시간이 아닙니다.'; end if;
   tid=(p_data->>'to')::uuid;
   select array_agg(id order by no) into ids from career_private.students where class_id=cid;
   idx=array_position(ids,sid);dest_idx=array_position(ids,tid);n=array_length(ids,1);
   if tid=sid or dest_idx is null or mod(dest_idx-idx+n,n)>least(cls.quota,n-1) then raise exception '배정된 친구에게만 추천할 수 있습니다.'; end if;
   if not exists(select 1 from career_private.students where id=tid and (choice->>'submitted')::boolean) then raise exception '친구가 희망 직업을 먼저 제출해야 합니다.'; end if;
   insert into career_private.votes(from_id,to_id,job,reason) values(sid,tid,jid,nm)
     on conflict(from_id,to_id) do update set job=excluded.job,reason=excluded.reason;
 elsif p_action='research' then
   if cls.stage<>4 then raise exception '미래 탐구 작성 시간이 아닙니다.'; end if;
   if stu.choice is null or not coalesce((stu.choice->>'submitted')::boolean,false) then raise exception '희망 직업을 먼저 제출해 주세요.'; end if;
   items=p_data->'items';
   if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)<>2 then raise exception '두 직업을 선택해 주세요.'; end if;
   next_jobs=array[(items->0->>'job')::int,(items->1->>'job')::int];
   if next_jobs[1] is null or next_jobs[2] is null or next_jobs[1]=next_jobs[2] or next_jobs[1] not between 1 and 200 or next_jobs[2] not between 1 and 200 then raise exception '서로 다른 두 직업을 선택해 주세요.'; end if;
   for entry in select jsonb_array_elements(items) loop
     foreach field in array array['now','tech','future','evidence','prepare','source'] loop
       if jsonb_typeof(entry->field) is distinct from 'string' or length(entry->>field)>1000 then raise exception '탐구 항목별로 1,000자 이내로 작성하세요.'; end if;
       if submitted and length(trim(entry->>field))=0 then raise exception '두 직업의 모든 탐구 항목을 작성해 주세요.'; end if;
     end loop;
   end loop;
   if stu.research is not null then
     current_jobs=array[(stu.research->'items'->0->>'job')::int,(stu.research->'items'->1->>'job')::int];
     if current_jobs<>next_jobs then raise exception '확정한 탐구 직업은 변경할 수 없습니다.'; end if;
   else
     if next_jobs[1]<>(stu.choice->>'job')::int then raise exception '첫 번째 탐구 대상은 나의 희망 직업입니다.'; end if;
     select max(cnt) into top_count from (select count(*) cnt from career_private.votes where to_id=sid and not hidden and job<>next_jobs[1] group by job) x;
     if top_count is not null then
       select array_agg(job) into candidates from (select job from career_private.votes where to_id=sid and not hidden and job<>next_jobs[1] group by job having count(*)=top_count) x;
       if not(next_jobs[2]=any(candidates)) then raise exception '추천 순위에 맞는 두 번째 직업을 선택해 주세요.'; end if;
     end if;
   end if;
   update career_private.students set research=jsonb_build_object('items',items,'submitted',submitted) where id=sid;
 else raise exception '지원하지 않는 요청입니다.';
 end if;
 return jsonb_build_object('ok',true);
end;
$$;
revoke all on function public.career_api(text,jsonb,text) from public,anon,authenticated;
grant execute on function public.career_api(text,jsonb,text) to anon,authenticated;
-- teacher registration is performed separately by the project owner in SQL Editor.

commit;
