-- 먼저 Supabase Authentication > Users에서 교사 계정을 만드세요.
-- 아래 예시를 실제 User UID로 바꾼 뒤 SQL Editor에서 실행하세요.
insert into career_private.teachers(user_id)
values ('여기에-교사-User-UID를-입력')
on conflict do nothing;
