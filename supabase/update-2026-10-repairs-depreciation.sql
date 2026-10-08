-- =====================================================================
--  設備資產管理系統：功能更新（2026-10）
--  新增：採購資訊、使用紀錄、維修紀錄、折舊與殘值
--
--  使用方式：在 Supabase「SQL Editor」貼上整份檔案並按 Run。
--  只會新增欄位、資料表與函式，不會刪除或修改任何既有資料。
--  重複執行也安全。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 資產：採購資訊與折舊欄位
-- ---------------------------------------------------------------------
alter table public.assets add column if not exists assigned_date date;
alter table public.assets add column if not exists vendor     text not null default '';  -- 供應商／購買通路
alter table public.assets add column if not exists purchaser  text not null default '';  -- 採購人
alter table public.assets add column if not exists invoice_no text not null default '';  -- 發票或採購單號
alter table public.assets add column if not exists life_years numeric(4,1)
  check (life_years is null or (life_years > 0 and life_years <= 50));                  -- 耐用年數；空白＝依類別預設
alter table public.assets add column if not exists salvage    numeric(12,0)
  check (salvage is null or salvage >= 0);                                               -- 預估殘值；空白＝依設定自動計算

-- ---------------------------------------------------------------------
-- 2. 設定：折舊規則
-- ---------------------------------------------------------------------
alter table public.settings add column if not exists dep_default_life numeric(4,1) not null default 3;
alter table public.settings add column if not exists dep_life jsonb not null
  default '{"筆記型電腦":3,"桌上型電腦":3,"螢幕":3,"手機":3,"平板":3,"測試機":3,"周邊配件":3,"網路設備":3,"辦公家具":5}'::jsonb;
alter table public.settings add column if not exists dep_salvage_mode text not null default 'tax';
alter table public.settings add column if not exists dep_salvage_pct numeric(5,2) not null default 10;
do $$ begin
  alter table public.settings add constraint settings_salvage_mode_chk check (dep_salvage_mode in ('tax','percent','zero'));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- 3. 維修紀錄
-- ---------------------------------------------------------------------
create table if not exists public.repairs (
  id             uuid primary key default gen_random_uuid(),
  asset_id       uuid not null references public.assets(id) on delete cascade,
  reported_at    date not null default (now() at time zone 'Asia/Taipei')::date,
  reporter_id    uuid references public.employees(id) on delete set null,
  reporter_name  text not null default '',
  issue          text not null check (length(trim(issue)) > 0),
  vendor         text not null default '',
  under_warranty boolean not null default false,
  sent_at        date,
  cost           numeric(12,0) check (cost is null or cost >= 0),
  done_at        date,
  result         text not null default 'pending'
                 check (result in ('pending','fixed','parts','replaced','scrapped','no_fault')),
  note           text not null default '',
  prev_status    text,          -- 送修前的設備狀態，完成後自動恢復
  prev_due       date,
  created_at     timestamptz not null default now(),
  created_by     text not null default '',
  updated_at     timestamptz not null default now(),
  constraint repair_done_needs_date check (result = 'pending' or done_at is not null)
);
create index if not exists repairs_asset_idx   on public.repairs (asset_id, reported_at desc);
create index if not exists repairs_open_idx    on public.repairs (reported_at desc) where result = 'pending';
create index if not exists repairs_created_idx on public.repairs (created_at desc);

-- ---------------------------------------------------------------------
-- 4. 使用紀錄（每位保管人一筆，含起訖日與簽收單號）
-- ---------------------------------------------------------------------
create table if not exists public.asset_assignments (
  id            bigint generated always as identity primary key,
  asset_id      uuid not null references public.assets(id) on delete cascade,
  employee_id   uuid references public.employees(id) on delete set null,
  employee_name text not null default '',
  kind          text not null default 'use' check (kind in ('use','borrow')),
  start_date    date not null,
  end_date      date,
  signoff_no    text not null default '',
  return_no     text not null default '',
  created_at    timestamptz not null default now()
);
create index if not exists assign_asset_idx on public.asset_assignments (asset_id, start_date desc);
create index if not exists assign_emp_idx   on public.asset_assignments (employee_id, start_date desc);
create unique index if not exists assign_open_uq on public.asset_assignments (asset_id) where end_date is null;

-- ---------------------------------------------------------------------
-- 5. 觸發器
-- ---------------------------------------------------------------------

-- 保管人變動時，自動結束上一段使用紀錄並開始新的一段
create or replace function public.tg_assets_assign() returns trigger
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if tg_op = 'UPDATE' and new.holder_id is not distinct from old.holder_id then
    if new.holder_id is not null and new.status is distinct from old.status
       and (new.status = 'borrowed') <> (old.status = 'borrowed') and new.status <> 'repair' and old.status <> 'repair' then
      update public.asset_assignments set kind = case when new.status = 'borrowed' then 'borrow' else 'use' end
       where asset_id = new.id and end_date is null;
    end if;
    return null;
  end if;
  if tg_op = 'UPDATE' and old.holder_id is not null then
    update public.asset_assignments set end_date = greatest(start_date, today)
     where asset_id = new.id and end_date is null;
  end if;
  if new.holder_id is not null then
    insert into public.asset_assignments (asset_id, employee_id, employee_name, kind, start_date)
    values (new.id, new.holder_id, new.holder_name,
            case when new.status = 'borrowed' then 'borrow' else 'use' end,
            coalesce(new.assigned_date, today));
  end if;
  return null;
end $$;
drop trigger if exists assets_assign on public.assets;
create trigger assets_assign after insert or update of holder_id, status on public.assets
  for each row execute function public.tg_assets_assign();

-- 簽收單簽回時，把單號記到對應的使用紀錄上
create or replace function public.tg_signoffs_assign() returns trigger
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  if (old.signed_at is null and old.paper_signed_at is null)
     and (new.signed_at is not null or new.paper_signed_at is not null) and not new.voided then
    select coalesce(array_agg((it ->> 'id')::uuid), '{}') into ids from jsonb_array_elements(new.items) it;
    if new.type in ('issue','borrow') then
      update public.asset_assignments set signoff_no = new.no
       where asset_id = any(ids) and employee_id = new.employee_id and end_date is null and signoff_no = '';
    elsif new.type = 'return' then
      update public.asset_assignments a set return_no = new.no
       where a.id in (select distinct on (asset_id) id from public.asset_assignments
                      where asset_id = any(ids) and employee_id = new.employee_id
                      order by asset_id, start_date desc, id desc);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists signoffs_assign on public.signoffs;
create trigger signoffs_assign after update of signed_at, paper_signed_at on public.signoffs
  for each row execute function public.tg_signoffs_assign();

-- 維修：送修時設備改為「維修中」，完成後恢復原狀態（報廢則改為已報廢）
create or replace function public.tg_repairs() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.assets; label text;
begin
  if tg_op = 'DELETE' then
    if old.result = 'pending' then
      update public.assets x
         set status = case when old.prev_status in ('in_use','borrowed') and x.holder_id is null then 'available'
                           when old.prev_status = 'borrowed' and old.prev_due is null then 'in_use'
                           else coalesce(old.prev_status, 'available') end,
             due_date = old.prev_due
       where x.id = old.asset_id and x.status = 'repair';
    end if;
    return old;
  end if;

  new.updated_at := now();
  if new.reporter_id is not null then
    new.reporter_name := coalesce((select name from public.employees where id = new.reporter_id), new.reporter_name);
  end if;
  if new.result <> 'pending' and new.done_at is null then
    new.done_at := (now() at time zone 'Asia/Taipei')::date;
  end if;

  select * into a from public.assets where id = new.asset_id for update;

  if tg_op = 'INSERT' then
    new.created_by := public.my_email();
    if new.result = 'pending' then
      if a.status = 'repair' then
        raise exception '這台設備已經在維修中，請先完成目前的維修紀錄';
      end if;
      new.prev_status := a.status; new.prev_due := a.due_date;
      update public.assets set status = 'repair' where id = a.id;
    end if;
    insert into public.asset_events (asset_id, by_email, action)
    values (a.id, public.my_email(), '報修：' || left(new.issue, 60));
  else
    if new.asset_id <> old.asset_id then raise exception '維修紀錄不可改到其他設備'; end if;
    new.prev_status := old.prev_status; new.prev_due := old.prev_due;
    new.created_by := old.created_by; new.created_at := old.created_at;
    if old.result = 'pending' and new.result <> 'pending' and a.status = 'repair' then
      if new.result = 'scrapped' then
        update public.assets set status = 'retired' where id = a.id;
      else
        update public.assets
           set status = case when old.prev_status in ('in_use','borrowed') and a.holder_id is null then 'available'
                             when old.prev_status = 'borrowed' and old.prev_due is null then 'in_use'
                             else coalesce(old.prev_status, 'available') end,
               due_date = old.prev_due
         where id = a.id;
      end if;
    end if;
    if old.result = 'pending' and new.result <> 'pending' then
      label := case new.result when 'fixed' then '已修復' when 'parts' then '更換零件' when 'replaced' then '原廠換新'
                               when 'scrapped' then '無法修復，報廢' when 'no_fault' then '檢測無異常' end;
      insert into public.asset_events (asset_id, by_email, action)
      values (a.id, public.my_email(), '維修完成：' || label ||
              case when new.cost is not null and new.cost > 0 then '，費用 ' || to_char(new.cost, 'FM999,999,999') || ' 元' else '' end ||
              case when new.under_warranty then '（保固內）' else '' end);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists repairs_tg on public.repairs;
create trigger repairs_tg before insert or update or delete on public.repairs
  for each row execute function public.tg_repairs();

-- ---------------------------------------------------------------------
-- 6. 折舊與帳面價值（直線法，按月計算，每天自動更新）
--    預估殘值：tax＝成本 ÷（耐用年數＋1）；percent＝成本 × 百分比；zero＝不留殘值
-- ---------------------------------------------------------------------
create or replace view public.asset_values with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
base as (
  select a.id, a.tag, a.name, a.cat, a.status, a.holder_name, a.cost, a.purchase_date,
         coalesce(a.life_years, (s.dep_life ->> a.cat)::numeric, s.dep_default_life) as life,
         a.salvage as salvage_set, s.dep_salvage_mode, s.dep_salvage_pct,
         (select coalesce(sum(r.cost), 0) from public.repairs r where r.asset_id = a.id) as repair_total,
         (select count(*) from public.repairs r where r.asset_id = a.id) as repair_count
  from public.assets a cross join s
  where (select public.is_staff())
),
calc as (
  select b.*,
    least(b.cost, coalesce(b.salvage_set, case b.dep_salvage_mode
      when 'tax'     then round(b.cost / (b.life + 1))
      when 'percent' then round(b.cost * b.dep_salvage_pct / 100)
      else 0 end)) as salvage_value,
    case when b.purchase_date is null then null else greatest(0,
      (extract(year  from age((now() at time zone 'Asia/Taipei')::date, b.purchase_date)) * 12 +
       extract(month from age((now() at time zone 'Asia/Taipei')::date, b.purchase_date)))::int) end as months_used
  from base b
)
select id, tag, name, cat, status, holder_name, cost, purchase_date,
       life as life_years, salvage_value, months_used,
       case when cost is null then null else round((cost - salvage_value) / (life * 12)) end as monthly_dep,
       case when cost is null or months_used is null then null
            else least(cost - salvage_value, round((cost - salvage_value) * months_used / (life * 12))) end as accumulated_dep,
       case when cost is null or months_used is null then null
            else cost - least(cost - salvage_value, round((cost - salvage_value) * months_used / (life * 12))) end as book_value,
       case when purchase_date is null then null
            else (purchase_date + make_interval(months => (life * 12)::int))::date end as fully_depreciated_on,
       repair_total, repair_count
from calc;

-- 價值總覽（資產總覽頁上方的數字）
create or replace function public.asset_value_summary() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'cost',       coalesce(sum(cost) filter (where status not in ('retired','lost')), 0),
    'book',       coalesce(sum(book_value) filter (where status not in ('retired','lost')), 0),
    'repair',     coalesce(sum(repair_total), 0),
    'no_cost',    count(*) filter (where cost is null and status not in ('retired','lost')),
    'no_date',    count(*) filter (where cost is not null and purchase_date is null and status not in ('retired','lost')),
    'fully',      count(*) filter (where book_value is not null and book_value <= salvage_value and status not in ('retired','lost')))
  from public.asset_values
$$;

-- 維修統計
create or replace function public.repair_stats() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'all', count(*),
    'pending', count(*) filter (where result = 'pending'),
    'done', count(*) filter (where result <> 'pending'),
    'cost_year', coalesce(sum(cost) filter (where done_at >= date_trunc('year', now() at time zone 'Asia/Taipei')::date), 0))
  from public.repairs
$$;

-- ---------------------------------------------------------------------
-- 7. 權限（RLS）
-- ---------------------------------------------------------------------
alter table public.repairs           enable row level security;
alter table public.asset_assignments enable row level security;

revoke all on public.repairs, public.asset_assignments, public.asset_values from anon;
grant select, insert, update, delete on public.repairs to authenticated;
grant select, update, delete on public.asset_assignments to authenticated;
grant select on public.asset_values to authenticated;
revoke execute on function public.asset_value_summary(), public.repair_stats(),
  public.tg_assets_assign(), public.tg_signoffs_assign(), public.tg_repairs() from anon, public;
grant execute on function public.asset_value_summary(), public.repair_stats() to authenticated;

drop policy if exists repairs_read   on public.repairs;
drop policy if exists repairs_write  on public.repairs;
drop policy if exists assign_read    on public.asset_assignments;
drop policy if exists assign_update  on public.asset_assignments;
drop policy if exists assign_delete  on public.asset_assignments;

-- 維修：管理員與唯讀可看，只有管理員可新增修改
create policy repairs_read  on public.repairs for select to authenticated using ((select public.is_staff()));
create policy repairs_write on public.repairs for all    to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- 使用紀錄：管理員與唯讀可看全部；員工只看得到自己的；由系統自動寫入，管理員可更正
create policy assign_read   on public.asset_assignments for select to authenticated
  using ((select public.is_staff()) or employee_id = (select public.my_employee_id()));
create policy assign_update on public.asset_assignments for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy assign_delete on public.asset_assignments for delete to authenticated using ((select public.is_admin()));

-- ---------------------------------------------------------------------
-- 8. 既有資料：替目前有保管人的設備建立第一筆使用紀錄
--    （更早的歷史仍可在每台設備的「異動紀錄」查到）
-- ---------------------------------------------------------------------
insert into public.asset_assignments (asset_id, employee_id, employee_name, kind, start_date)
select a.id, a.holder_id, a.holder_name,
       case when a.status = 'borrowed' then 'borrow' else 'use' end,
       coalesce(a.assigned_date, (a.updated_at at time zone 'Asia/Taipei')::date)
from public.assets a
where a.holder_id is not null
  and not exists (select 1 from public.asset_assignments x where x.asset_id = a.id and x.end_date is null);

notify pgrst, 'reload schema';
