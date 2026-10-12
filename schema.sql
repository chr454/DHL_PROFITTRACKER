-- DHL Office Profit Tracker MVP
-- Apply once in Supabase SQL Editor, after reviewing the provider/region with the organization.
-- One organization, individual Supabase Auth users, staff/admin roles.
-- Client-side writes are only through the RPCs below. Never place a Supabase secret key in the browser.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table if not exists public.organizations (
  id uuid primary key,
  name text not null,
  timezone text not null default 'Africa/Lagos',
  created_at timestamptz not null default now()
);

create table if not exists public.org_memberships (
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('admin','staff')),
  active boolean not null default true,
  write_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- App records retain the original tracker document shape, while the database controls
-- identity, organization, report locks, financial calculations, and audit events.
create table if not exists public.tracker_records (
  org_id uuid not null references public.organizations(id) on delete cascade,
  kind text not null check (kind in ('settings','shipments','expenses','reports')),
  record_id text not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (org_id, kind, record_id)
);
create index if not exists tracker_records_kind_date_idx
  on public.tracker_records (org_id, kind, ((payload->>'date')));
create index if not exists tracker_records_tracking_idx
  on public.tracker_records (org_id, upper(payload->>'trackingId'))
  where kind = 'shipments';

create table if not exists public.audit_events (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id) on delete cascade,
  at_ms bigint not null,
  by uuid not null references auth.users(id),
  action text not null,
  detail text not null default '',
  date date,
  created_at timestamptz not null default now()
);
create index if not exists audit_events_org_at_idx on public.audit_events (org_id, at_ms desc);

-- Seed a stable organization ID and the tracker defaults. Change the name/timezone here
-- before first production use if the organization has a different approved name/timezone.
insert into public.organizations (id, name, timezone)
values ('00000000-0000-4000-8000-000000000001', 'DHL Office', 'Africa/Lagos')
on conflict (id) do nothing;

insert into public.tracker_records (org_id, kind, record_id, payload)
values
('00000000-0000-4000-8000-000000000001', 'settings', 'rates',
 '{"businessName":"DHL Office","account1Pct":12.5,"fuelVatPct":7.5,"defaultMarginPct":30,"marginOptions":[20,25,30],"cutoff":"20:00","workDays":[1,2,3,4,5,6]}'::jsonb),
('00000000-0000-4000-8000-000000000001', 'settings', 'categories',
 '{"list":["Transportation","Fuel","Electricity / Power","Internet / Data","Office supplies","Repairs and maintenance","Staff-related expenses","Rent / Office costs","Delivery-related expenses","Partner-related expenses","Bank / Transaction charges","Miscellaneous","Other"]}'::jsonb)
on conflict (org_id, kind, record_id) do nothing;

-- RLS helper functions are SECURITY DEFINER so policies can inspect membership without
-- recursively invoking the membership table's own policies. They expose only booleans/role.
create or replace function private.role_for_org(p_org_id uuid)
returns text
language sql stable security definer
set search_path = pg_catalog
as $$
  select m.role
  from public.org_memberships m
  where m.org_id = p_org_id
    and m.user_id = (select auth.uid())
    and m.active = true
  limit 1
$$;

create or replace function private.is_active_member(p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = pg_catalog
as $$
  select private.role_for_org(p_org_id) in ('admin','staff')
$$;

create or replace function private.is_org_admin(p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = pg_catalog
as $$
  select private.role_for_org(p_org_id) = 'admin'
$$;

revoke all on function private.role_for_org(uuid) from public, anon;
revoke all on function private.is_active_member(uuid) from public, anon;
revoke all on function private.is_org_admin(uuid) from public, anon;
grant execute on function private.role_for_org(uuid) to authenticated;
grant execute on function private.is_active_member(uuid) to authenticated;
grant execute on function private.is_org_admin(uuid) to authenticated;

alter table public.organizations enable row level security;
alter table public.org_memberships enable row level security;
alter table public.tracker_records enable row level security;
alter table public.audit_events enable row level security;

revoke all on public.organizations, public.org_memberships, public.tracker_records, public.audit_events from anon, authenticated;
grant select on public.organizations, public.org_memberships, public.tracker_records to authenticated;
grant select on public.audit_events to authenticated;

 drop policy if exists orgs_member_read on public.organizations;
create policy orgs_member_read on public.organizations
  for select to authenticated using (private.is_active_member(id));

drop policy if exists memberships_member_read on public.org_memberships;
create policy memberships_member_read on public.org_memberships
  for select to authenticated using (private.is_active_member(org_id));

drop policy if exists tracker_member_read on public.tracker_records;
create policy tracker_member_read on public.tracker_records
  for select to authenticated using (private.is_active_member(org_id));

drop policy if exists audit_admin_read on public.audit_events;
create policy audit_admin_read on public.audit_events
  for select to authenticated using (private.is_org_admin(org_id));

-- Central writer. This function runs in a transaction and derives user/org/role values
-- from the verified Supabase Auth session, not from caller-supplied JSON.
create or replace function private.save_tracker_record(
  p_kind text,
  p_id text,
  p_input jsonb,
  p_merge boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_org uuid;
  v_role text;
  v_write boolean;
  v_old jsonb;
  v_payload jsonb;
  v_found boolean := false;
  v_action text;
  v_detail text := '';
  v_date date;
  v_business_today date;
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_status text;
  v_locked boolean := false;
  v_rate jsonb;
  v_rate_pct numeric;
  v_vat_pct numeric;
  v_margin_pct numeric;
  v_amount numeric;
  v_base numeric;
  v_charge numeric;
  v_fuel numeric;
  v_subtotal numeric;
  v_margin numeric;
  v_profit numeric;
  v_due numeric;
  v_paid numeric;
  v_tracking text;
  v_total_count integer;
  v_total_profit numeric;
  v_total_expenses numeric;
  v_old_status text;
  v_reopen_count integer;
begin
  if v_user is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('settings','shipments','expenses','reports') then raise exception 'Unsupported record kind'; end if;
  if p_id is null or length(p_id) < 1 or length(p_id) > 100 then raise exception 'Invalid record ID'; end if;
  if p_input is null or jsonb_typeof(p_input) <> 'object' then raise exception 'Record must be a JSON object'; end if;

  select m.org_id, m.role, m.write_enabled
    into v_org, v_role, v_write
  from public.org_memberships m
  where m.user_id = v_user and m.active = true;
  if not found then raise exception 'No active organization membership' using errcode = '42501'; end if;
  if not v_write then raise exception 'This account is view-only' using errcode = '42501'; end if;

  select r.payload into v_old
  from public.tracker_records r
  where r.org_id = v_org and r.kind = p_kind and r.record_id = p_id
  for update;
  v_found := found;
  if p_merge then
    if not v_found then raise exception 'Record no longer exists'; end if;
    v_payload := v_old || p_input;
  else
    v_payload := p_input;
  end if;

  if p_kind = 'settings' then
    if v_role <> 'admin' then raise exception 'Only an admin can change settings' using errcode = '42501'; end if;
    if p_id = 'rates' then
      if coalesce((v_payload->>'account1Pct')::numeric, -1) not between 0 and 100
        or coalesce((v_payload->>'fuelVatPct')::numeric, -1) not between 0 and 100
        or coalesce((v_payload->>'defaultMarginPct')::numeric, -1) not between 0 and 100
        or coalesce(jsonb_typeof(v_payload->'marginOptions'),'') <> 'array'
        or coalesce(jsonb_array_length(v_payload->'marginOptions'),0) = 0
        or coalesce(v_payload->>'cutoff','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        or coalesce(jsonb_typeof(v_payload->'workDays'),'') <> 'array'
        or coalesce(jsonb_array_length(v_payload->'workDays'),0) = 0 then
        raise exception 'Invalid business rates/settings';
      end if;
      v_rate_pct := coalesce((v_payload->>'defaultMarginPct')::numeric, 0);
      if exists (select 1 from jsonb_array_elements_text(v_payload->'marginOptions') x where x is null or x !~ '^[0-9]+(\.[0-9]+)?$' or x::numeric not between 0 and 100) then
        raise exception 'Margin choices must be from 0 to 100';
      end if;
      if exists (select 1 from jsonb_array_elements_text(v_payload->'workDays') x where x::integer not between 0 and 6) then
        raise exception 'Working days must be 0 to 6';
      end if;
      v_detail := 'Business rates and reporting settings updated';
    elsif p_id = 'categories' then
      if coalesce(jsonb_typeof(v_payload->'list'),'') <> 'array' or coalesce(jsonb_array_length(v_payload->'list'),0) = 0 then
        raise exception 'Keep at least one expense category';
      end if;
      v_detail := 'Expense categories updated';
    else
      raise exception 'Unknown settings record';
    end if;
    v_action := 'Settings changed';

  elsif p_kind in ('shipments','expenses') then
    if not v_payload ? 'date' then raise exception 'Choose a record date'; end if;
    v_date := (v_payload->>'date')::date;
    if v_date > (select (clock_timestamp() at time zone o.timezone)::date from public.organizations o where o.id = v_org) then
      raise exception 'Future-dated records are not allowed';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || v_date::text, 0));
    select coalesce((r.payload->>'status') = 'submitted', false) into v_locked
    from public.tracker_records r
    where r.org_id = v_org and r.kind = 'reports' and r.record_id = to_char(v_date, 'YYYY-MM-DD');
    if coalesce(v_locked, false) then raise exception 'Submitted day is locked; ask an admin to reopen it'; end if;

    if p_kind = 'shipments' then
      v_tracking := upper(regexp_replace(trim(coalesce(v_payload->>'trackingId','')), '\s+', '', 'g'));
      if v_tracking = '' or length(v_tracking) > 100 then raise exception 'Tracking ID is required'; end if;
      perform pg_advisory_xact_lock(hashtextextended(v_org::text || ':tracking:' || v_tracking, 0));
      if coalesce(trim(v_payload->>'sender'),'') = '' or length(v_payload->>'sender') > 200 or coalesce(trim(v_payload->>'location'),'') = '' or length(v_payload->>'location') > 300 then
        raise exception 'Sender and delivery location are required';
      end if;
      if exists (
        select 1 from public.tracker_records x
        where x.org_id = v_org and x.kind = 'shipments' and x.record_id <> p_id
          and coalesce((x.payload->>'deleted')::boolean,false) = false
          and upper(regexp_replace(trim(coalesce(x.payload->>'trackingId','')), '\s+', '', 'g')) = v_tracking
      ) and coalesce(trim(v_payload->>'duplicateReason'),'') = '' then
        raise exception 'Duplicate tracking ID requires a documented reason';
      end if;
      v_payload := jsonb_set(v_payload, '{trackingId}', to_jsonb(v_tracking), true);

      select r.payload into v_rate from public.tracker_records r
      where r.org_id = v_org and r.kind = 'settings' and r.record_id = 'rates';
      if v_rate is null then raise exception 'Business rates are not initialized'; end if;
      v_rate_pct := case when v_found then coalesce((v_old->>'commissionPct')::numeric,(v_rate->>'account1Pct')::numeric,12.5) else coalesce((v_rate->>'account1Pct')::numeric,12.5) end;
      v_vat_pct := case when v_found then coalesce((v_old->>'vatPct')::numeric,(v_rate->>'fuelVatPct')::numeric,7.5) else coalesce((v_rate->>'fuelVatPct')::numeric,7.5) end;
      v_status := coalesce(v_payload->>'paymentStatus','paid');
      if v_status not in ('paid','pending','partial') then raise exception 'Invalid payment status'; end if;

      case v_payload->>'accountType'
      when 'account1' then
        v_amount := round((v_payload->>'transactionAmount')::numeric, 2);
        if v_amount <= 0 then raise exception 'Transaction amount must be above zero'; end if;
        v_profit := round(v_amount * v_rate_pct / 100, 2);
        v_due := v_amount;
        v_payload := jsonb_set(v_payload, '{transactionAmount}', to_jsonb(v_amount), true);
        v_payload := jsonb_set(v_payload, '{commissionPct}', to_jsonb(v_rate_pct), true);
        v_payload := jsonb_set(v_payload, '{commission}', to_jsonb(v_profit), true);
        v_payload := jsonb_set(v_payload, '{customerCharge}', 'null'::jsonb, true);
      when 'independent' then
        v_base := round((v_payload->>'baseRate')::numeric, 2);
        v_charge := round((v_payload->>'customerCharge')::numeric, 2);
        if v_base <= 0 or v_charge <= 0 then raise exception 'Base rate and customer charge must be above zero'; end if;
        v_profit := round(v_charge - v_base, 2);
        v_due := v_charge;
        v_payload := jsonb_set(v_payload, '{baseRate}', to_jsonb(v_base), true);
        v_payload := jsonb_set(v_payload, '{customerCharge}', to_jsonb(v_charge), true);
      when 'economy' then
        v_base := round((v_payload->>'baseRate')::numeric, 2);
        v_margin_pct := round((v_payload->>'marginPct')::numeric, 2);
        if v_base <= 0 or v_margin_pct not between 0 and 100 then raise exception 'Invalid economy rate or margin'; end if;
        v_fuel := round(v_base * v_vat_pct / 100, 2);
        v_subtotal := round(v_base + v_fuel, 2);
        v_margin := round(v_subtotal * v_margin_pct / 100, 2);
        v_charge := round(v_subtotal + v_margin, 2);
        v_profit := v_margin;
        v_due := v_charge;
        v_payload := jsonb_set(v_payload, '{baseRate}', to_jsonb(v_base), true);
        v_payload := jsonb_set(v_payload, '{vatPct}', to_jsonb(v_vat_pct), true);
        v_payload := jsonb_set(v_payload, '{fuelVat}', to_jsonb(v_fuel), true);
        v_payload := jsonb_set(v_payload, '{subtotal}', to_jsonb(v_subtotal), true);
        v_payload := jsonb_set(v_payload, '{marginPct}', to_jsonb(v_margin_pct), true);
        v_payload := jsonb_set(v_payload, '{margin}', to_jsonb(v_margin), true);
        v_payload := jsonb_set(v_payload, '{customerCharge}', to_jsonb(v_charge), true);
      else
        raise exception 'Invalid shipment account type';
      end case;
      if v_status = 'paid' then v_paid := v_due;
      elsif v_status = 'pending' then v_paid := 0;
      else
        v_paid := round((v_payload->>'amountPaid')::numeric, 2);
        if v_paid <= 0 or v_paid >= v_due then raise exception 'Partial payment must be above zero and below amount due'; end if;
      end if;
      v_payload := jsonb_set(v_payload, '{profit}', to_jsonb(v_profit), true);
      v_payload := jsonb_set(v_payload, '{paymentStatus}', to_jsonb(v_status), true);
      v_payload := jsonb_set(v_payload, '{amountDue}', to_jsonb(v_due), true);
      v_payload := jsonb_set(v_payload, '{amountPaid}', to_jsonb(v_paid), true);
      if v_found then
        v_payload := jsonb_set(v_payload, '{createdBy}', coalesce(v_old->'createdBy', to_jsonb(v_user::text)), true);
        v_payload := jsonb_set(v_payload, '{createdAt}', coalesce(v_old->'createdAt', to_jsonb(v_now_ms)), true);
        v_payload := jsonb_set(v_payload, '{updatedBy}', to_jsonb(v_user::text), true);
        v_payload := jsonb_set(v_payload, '{updatedAt}', to_jsonb(v_now_ms), true);
        if coalesce((v_payload->>'deleted')::boolean,false) then
          if coalesce(trim(v_payload->>'deleteReason'),'') = '' then raise exception 'A deletion reason is required'; end if;
          v_payload := jsonb_set(v_payload, '{deletedBy}', to_jsonb(v_user::text), true);
          v_payload := jsonb_set(v_payload, '{deletedAt}', to_jsonb(v_now_ms), true);
          v_action := 'Shipment deleted';
          v_detail := coalesce(v_payload->>'trackingId',p_id) || '. Reason: ' || coalesce(v_payload->>'deleteReason','');
        else
          v_action := 'Shipment edited';
          v_detail := coalesce(v_payload->>'trackingId',p_id) || ', profit ' || v_profit::text;
        end if;
      else
        v_payload := jsonb_set(v_payload, '{createdBy}', to_jsonb(v_user::text), true);
        v_payload := jsonb_set(v_payload, '{createdAt}', to_jsonb(v_now_ms), true);
        v_action := 'Shipment added';
        v_detail := coalesce(v_payload->>'trackingId',p_id) || ', ' || coalesce(v_payload->>'accountType','') || ', profit ' || v_profit::text;
      end if;

    else
      v_amount := round((v_payload->>'amount')::numeric, 2);
      if v_amount <= 0 then raise exception 'Expense amount must be above zero'; end if;
      if coalesce(trim(v_payload->>'category'),'') = '' or length(v_payload->>'category') > 100 or coalesce(trim(v_payload->>'description'),'') = '' or length(v_payload->>'description') > 500 then
        raise exception 'Expense category and description are required';
      end if;
      v_payload := jsonb_set(v_payload, '{amount}', to_jsonb(v_amount), true);
      if v_found then
        v_payload := jsonb_set(v_payload, '{recordedBy}', coalesce(v_old->'recordedBy', to_jsonb(v_user::text)), true);
        v_payload := jsonb_set(v_payload, '{createdAt}', coalesce(v_old->'createdAt', to_jsonb(v_now_ms)), true);
        v_payload := jsonb_set(v_payload, '{updatedBy}', to_jsonb(v_user::text), true);
        v_payload := jsonb_set(v_payload, '{updatedAt}', to_jsonb(v_now_ms), true);
        if coalesce((v_payload->>'deleted')::boolean,false) then
          if coalesce(trim(v_payload->>'deleteReason'),'') = '' then raise exception 'A deletion reason is required'; end if;
          v_payload := jsonb_set(v_payload, '{deletedBy}', to_jsonb(v_user::text), true);
          v_payload := jsonb_set(v_payload, '{deletedAt}', to_jsonb(v_now_ms), true);
          v_action := 'Expense deleted';
          v_detail := coalesce(v_payload->>'category','') || ': ' || coalesce(v_payload->>'description','') || '. Reason: ' || coalesce(v_payload->>'deleteReason','');
        else
          v_action := 'Expense edited';
          v_detail := coalesce(v_payload->>'category','') || ': ' || coalesce(v_payload->>'description','') || ', ' || v_amount::text;
        end if;
      else
        v_payload := jsonb_set(v_payload, '{recordedBy}', to_jsonb(v_user::text), true);
        v_payload := jsonb_set(v_payload, '{createdAt}', to_jsonb(v_now_ms), true);
        v_action := 'Expense added';
        v_detail := coalesce(v_payload->>'category','') || ': ' || coalesce(v_payload->>'description','') || ', ' || v_amount::text;
      end if;
    end if;

  elsif p_kind = 'reports' then
    if p_id !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Invalid report date'; end if;
    v_date := p_id::date;
    perform pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || v_date::text, 0));
    if coalesce(v_payload->>'date','') <> p_id then raise exception 'Report date must match its ID'; end if;
    v_old_status := coalesce(v_old->>'status','');
    v_status := v_payload->>'status';
    select (clock_timestamp() at time zone o.timezone)::date into v_business_today
    from public.organizations o where o.id = v_org;
    if p_id::date > v_business_today then raise exception 'Future reports are not allowed'; end if;
    if v_status = 'submitted' then
      if v_found and v_old_status <> 'reopened' then raise exception 'Report is already submitted or cannot be submitted from this state'; end if;
      select count(*) filter (where r.kind='shipments'),
             coalesce(sum(case when r.kind='shipments' then (r.payload->>'profit')::numeric else 0 end),0),
             coalesce(sum(case when r.kind='expenses' then (r.payload->>'amount')::numeric else 0 end),0)
        into v_total_count, v_total_profit, v_total_expenses
      from public.tracker_records r
      where r.org_id=v_org and r.kind in ('shipments','expenses')
        and r.payload->>'date'=p_id
        and coalesce((r.payload->>'deleted')::boolean,false)=false;
      v_total_profit := round(v_total_profit,2);
      v_total_expenses := round(v_total_expenses,2);
      v_payload := jsonb_build_object(
        'date', p_id, 'status', 'submitted',
        'submittedBy', v_user::text, 'submittedAt', v_now_ms,
        'totals', jsonb_build_object('shipments',coalesce(v_total_count,0),'profit',v_total_profit,
          'expenses',v_total_expenses,'net',round(v_total_profit-v_total_expenses,2)),
        'reopenCount', coalesce((v_old->>'reopenCount')::integer,0)
      );
      v_action := 'Report submitted';
      v_detail := 'Net profit ' || round(v_total_profit-v_total_expenses,2)::text ||
        ' (profit ' || v_total_profit::text || ', expenses ' || v_total_expenses::text || ')';
    elsif v_status = 'reopened' then
      if v_role <> 'admin' then raise exception 'Only an admin can reopen a report' using errcode='42501'; end if;
      if not v_found or v_old_status <> 'submitted' then raise exception 'Only a submitted report can be reopened'; end if;
      if coalesce(trim(v_payload->>'reopenReason'),'') = '' then raise exception 'A reason is required to reopen a report'; end if;
      v_reopen_count := coalesce((v_old->>'reopenCount')::integer,0)+1;
      v_payload := v_old || jsonb_build_object('status','reopened','reopenedBy',v_user::text,
        'reopenedAt',v_now_ms,'reopenReason',trim(v_payload->>'reopenReason'),'reopenCount',v_reopen_count);
      v_action := 'Report reopened';
      v_detail := 'Reason: ' || (v_payload->>'reopenReason');
    else
      raise exception 'Invalid report status transition';
    end if;
  end if;

  insert into public.tracker_records (org_id,kind,record_id,payload,created_at,updated_at)
  values (v_org,p_kind,p_id,v_payload,clock_timestamp(),clock_timestamp())
  on conflict (org_id,kind,record_id) do update set payload=excluded.payload, updated_at=clock_timestamp();

  insert into public.audit_events (org_id,at_ms,by,action,detail,date)
  values (v_org,v_now_ms,v_user,v_action,coalesce(v_detail,''),v_date);
  return v_payload;
end
$$;

revoke all on function private.save_tracker_record(text,text,jsonb,boolean) from public, anon, authenticated;

create or replace function public.tracker_upsert(p_kind text, p_id text, p_payload jsonb)
returns jsonb language sql security definer
set search_path = pg_catalog
as $$ select private.save_tracker_record(p_kind,p_id,p_payload,false) $$;

create or replace function public.tracker_patch(p_kind text, p_id text, p_patch jsonb)
returns jsonb language sql security definer
set search_path = pg_catalog
as $$ select private.save_tracker_record(p_kind,p_id,p_patch,true) $$;

revoke all on function public.tracker_upsert(text,text,jsonb) from public, anon;
revoke all on function public.tracker_patch(text,text,jsonb) from public, anon;
grant execute on function public.tracker_upsert(text,text,jsonb) to authenticated;
grant execute on function public.tracker_patch(text,text,jsonb) to authenticated;

commit;
