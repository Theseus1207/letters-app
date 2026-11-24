-- =========================================================
-- 指定第一位管理者（只要做一次）
-- 1. 先在 App 註冊並設定好暱稱
-- 2. 把下面的「你的暱稱」換掉，在 Supabase 的 SQL Editor 執行
-- 3. 重新整理 App，上方就會出現「管理」頁
-- 之後要新增其他管理者，直接在 App 的「管理」頁輸入對方暱稱即可
-- =========================================================
insert into public.admins (user_id)
select id from public.profiles where nickname = '你的暱稱'
on conflict do nothing;

-- 確認目前的管理者
select p.nickname from public.admins a join public.profiles p on p.id = a.user_id;
