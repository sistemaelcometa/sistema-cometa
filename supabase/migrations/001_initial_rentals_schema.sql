-- Fase 1: Alquileres
-- Migracion inicial propuesta. Revisar antes de aplicar en Supabase.

create extension if not exists pgcrypto;
create extension if not exists unaccent;
create extension if not exists pg_trgm;
create extension if not exists btree_gist;

create or replace function immutable_unaccent(value text)
returns text
language sql
immutable
parallel safe
as $$
  select unaccent(value);
$$;

create type app_role as enum ('owner', 'admin', 'editor', 'viewer');
create type building_status as enum ('active', 'inactive', 'archived');
create type unit_status as enum ('rented', 'available', 'no_contract', 'maintenance', 'reserved', 'archived');
create type rental_mode as enum ('fixed', 'temporary');
create type contact_type as enum ('person', 'company');
create type lease_status as enum ('upcoming', 'active', 'near_expiration', 'expired', 'rescinded', 'finalized');
create type payment_method as enum ('transfer', 'cash', 'deposit', 'other');
create type charge_status as enum ('pending', 'partial', 'paid', 'cancelled');
create type charge_item_type as enum ('rent', 'expense_transfer', 'unit_expense_transfer', 'rescission', 'other');
create type record_status as enum ('valid', 'voided');
create type expense_period_status as enum ('draft', 'incomplete', 'complete', 'calculated', 'closed', 'cancelled');
create type expense_scope as enum ('building_expense', 'unit_expense', 'both');
create type transfer_mode as enum ('none', 'next_rent', 'specific_due_date');
create type distribution_status as enum ('active', 'closed', 'cancelled');
create type settlement_status as enum ('open', 'closed', 'corrected', 'cancelled');
create type reservation_status as enum ('inquiry', 'reserved', 'deposit_received', 'paid', 'cancelled', 'finished');
create type reservation_payment_type as enum ('deposit', 'final_balance', 'other');
create type calendar_scope as enum ('main', 'punta_del_este');

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  email text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role app_role not null,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table buildings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  address text,
  status building_status not null default 'active',
  observations text,
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  building_id uuid not null references buildings(id) on delete restrict,
  name text not null,
  number text,
  floor text,
  surface_m2 numeric(10, 2) not null check (surface_m2 > 0),
  status unit_status not null default 'no_contract',
  rental_mode rental_mode not null default 'fixed',
  observations text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint unit_reserved_only_temporary
    check (status <> 'reserved' or rental_mode = 'temporary')
);

create unique index units_active_name_idx
  on units(building_id, name)
  where status <> 'archived';

create table contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_type contact_type not null default 'person',
  first_name text,
  last_name text,
  business_name text,
  dni text,
  phone text,
  email text,
  address text,
  observations text,
  is_tenant boolean not null default false,
  is_provider boolean not null default false,
  is_worker boolean not null default false,
  is_family_beneficiary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint contact_person_has_name
    check (contact_type <> 'person' or first_name is not null or last_name is not null),
  constraint contact_company_has_name
    check (contact_type <> 'company' or business_name is not null)
);

create table leases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references units(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  duration_months integer not null check (duration_months > 0),
  current_amount numeric(14, 2) not null check (current_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  last_adjustment_date date,
  adjustment_frequency_months integer check (adjustment_frequency_months > 0),
  next_adjustment_date date,
  monthly_due_day integer not null check (monthly_due_day between 1 and 28),
  status lease_status not null default 'upcoming',
  observations text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (end_date > start_date)
);

alter table leases
  add constraint leases_no_active_overlap
  exclude using gist (
    unit_id with =,
    daterange(start_date, end_date, '[]') with &&
  )
  where (status in ('upcoming', 'active', 'near_expiration'));

create table lease_parties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references leases(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete restrict,
  role text not null check (role in ('holder', 'tenant', 'guarantor')),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  unique (lease_id, contact_id, role)
);

create unique index lease_parties_one_primary_idx
  on lease_parties(lease_id)
  where is_primary;

create table lease_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references leases(id) on delete cascade,
  effective_date date not null,
  previous_amount numeric(14, 2) not null check (previous_amount >= 0),
  new_amount numeric(14, 2) not null check (new_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  next_adjustment_date date,
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table lease_charges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references leases(id) on delete restrict,
  unit_id uuid not null references units(id) on delete restrict,
  period_month date not null,
  due_date date not null,
  status charge_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  unique (lease_id, period_month)
);

create table lease_charge_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  charge_id uuid not null references lease_charges(id) on delete cascade,
  item_type charge_item_type not null,
  description text not null,
  amount_due numeric(14, 2) not null check (amount_due >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  created_at timestamptz not null default now()
);

create table lease_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references leases(id) on delete restrict,
  unit_id uuid not null references units(id) on delete restrict,
  payment_date date not null,
  received_amount numeric(14, 2) not null check (received_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  payment_method payment_method not null,
  observations text,
  status record_status not null default 'valid',
  voided_at timestamptz,
  void_reason text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table lease_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  payment_id uuid not null references lease_payments(id) on delete cascade,
  charge_item_id uuid not null references lease_charge_items(id) on delete restrict,
  allocated_amount numeric(14, 2) not null check (allocated_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  created_at timestamptz not null default now()
);

create table expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  parent_id uuid references expense_categories(id) on delete restrict,
  name text not null,
  scope expense_scope not null default 'both',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table building_expense_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  building_id uuid not null references buildings(id) on delete restrict,
  period_month date not null,
  status expense_period_status not null default 'draft',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  unique (building_id, period_month)
);

create table building_expense_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  period_id uuid not null references building_expense_periods(id) on delete restrict,
  category_id uuid not null references expense_categories(id) on delete restrict,
  expense_date date not null,
  provider_contact_id uuid references contacts(id) on delete set null,
  description text not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  transfer_to_tenant boolean not null default false,
  observations text,
  status record_status not null default 'valid',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table expense_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  period_id uuid not null references building_expense_periods(id) on delete restrict,
  expense_item_id uuid not null references building_expense_items(id) on delete restrict,
  building_id uuid not null references buildings(id) on delete restrict,
  unit_id uuid not null references units(id) on delete restrict,
  unit_surface_m2_snapshot numeric(10, 2) not null check (unit_surface_m2_snapshot > 0),
  building_total_surface_m2_snapshot numeric(10, 2) not null check (building_total_surface_m2_snapshot > 0),
  percentage_snapshot numeric(9, 6) not null check (percentage_snapshot >= 0),
  allocated_amount numeric(14, 2) not null check (allocated_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  transfer_to_tenant boolean not null,
  tenant_amount numeric(14, 2) not null default 0 check (tenant_amount >= 0),
  charge_item_id uuid references lease_charge_items(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (expense_item_id, unit_id),
  check (tenant_amount <= allocated_amount)
);

alter table lease_charge_items
  add column source_expense_allocation_id uuid references expense_allocations(id) on delete set null;

create table unit_expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references units(id) on delete restrict,
  category_id uuid references expense_categories(id) on delete set null,
  expense_date date not null,
  description text not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  provider_contact_id uuid references contacts(id) on delete set null,
  worker_contact_id uuid references contacts(id) on delete set null,
  transfer_to_tenant boolean not null default false,
  tenant_amount numeric(14, 2) not null default 0 check (tenant_amount >= 0),
  transfer_mode transfer_mode not null default 'none',
  target_charge_id uuid references lease_charges(id) on delete set null,
  charge_item_id uuid references lease_charge_items(id) on delete set null,
  observations text,
  status record_status not null default 'valid',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table lease_charge_items
  add column source_unit_expense_id uuid references unit_expenses(id) on delete set null;

create table lease_terminations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null unique references leases(id) on delete restrict,
  termination_date date not null,
  termination_type text not null check (termination_type in ('early_rescission', 'normal_end')),
  reason text,
  notes text,
  charged_amount numeric(14, 2) not null default 0 check (charged_amount >= 0),
  currency char(3) check (currency in ('ARS', 'USD')),
  charge_item_id uuid references lease_charge_items(id) on delete set null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table distribution_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references units(id) on delete restrict,
  valid_from date not null,
  valid_to date,
  status distribution_status not null default 'active',
  notes text,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);

alter table distribution_groups
  add constraint distribution_groups_no_overlap
  exclude using gist (
    unit_id with =,
    daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[]') with &&
  )
  where (status = 'active');

create table distribution_shares (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  distribution_group_id uuid not null references distribution_groups(id) on delete cascade,
  beneficiary_contact_id uuid not null references contacts(id) on delete restrict,
  percentage numeric(7, 4) not null check (percentage > 0 and percentage <= 100),
  created_at timestamptz not null default now(),
  unique (distribution_group_id, beneficiary_contact_id)
);

create table family_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  beneficiary_contact_id uuid not null references contacts(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  status settlement_status not null default 'open',
  generated_at timestamptz,
  closed_at timestamptz,
  total_ars numeric(14, 2) not null default 0,
  total_usd numeric(14, 2) not null default 0,
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_end >= period_start)
);

create table family_settlement_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  settlement_id uuid not null references family_settlements(id) on delete cascade,
  unit_id uuid not null references units(id) on delete restrict,
  lease_payment_allocation_id uuid not null references lease_payment_allocations(id) on delete restrict,
  distribution_group_id uuid not null references distribution_groups(id) on delete restrict,
  distribution_share_id uuid not null references distribution_shares(id) on delete restrict,
  base_rent_amount numeric(14, 2) not null check (base_rent_amount >= 0),
  percentage_snapshot numeric(7, 4) not null check (percentage_snapshot > 0),
  settled_amount numeric(14, 2) not null check (settled_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  description text,
  created_at timestamptz not null default now()
);

create table temporary_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references units(id) on delete restrict,
  guest_contact_id uuid references contacts(id) on delete set null,
  guest_name_snapshot text not null,
  guest_phone_snapshot text,
  guest_email_snapshot text,
  start_date date not null,
  end_date date not null,
  days_count integer not null check (days_count > 0),
  total_amount numeric(14, 2) not null check (total_amount >= 0),
  currency char(3) not null check (currency in ('USD', 'ARS')),
  status reservation_status not null default 'inquiry',
  observations text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (end_date > start_date)
);

alter table temporary_reservations
  add constraint temporary_reservations_no_overlap
  exclude using gist (
    unit_id with =,
    daterange(start_date, end_date, '[)') with &&
  )
  where (status in ('reserved', 'deposit_received', 'paid'));

create table reservation_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  reservation_id uuid not null references temporary_reservations(id) on delete restrict,
  payment_type reservation_payment_type not null,
  payment_date date not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null check (currency in ('USD', 'ARS')),
  payment_method payment_method not null,
  observations text,
  status record_status not null default 'valid',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table reservation_cancellations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  reservation_id uuid not null unique references temporary_reservations(id) on delete restrict,
  cancelled_at date not null,
  reason text,
  requested_by text,
  deposit_returned boolean not null default false,
  returned_amount numeric(14, 2) not null default 0 check (returned_amount >= 0),
  returned_date date,
  return_method text,
  observations text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table calendar_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  calendar_scope calendar_scope not null,
  event_date date not null,
  title text not null,
  body text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  bucket text not null,
  storage_path text not null,
  original_filename text not null,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (bucket, storage_path)
);

create table file_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  file_id uuid not null references files(id) on delete cascade,
  entity_type text not null check (
    entity_type in (
      'lease',
      'lease_payment',
      'building_expense_item',
      'unit_expense',
      'temporary_reservation',
      'reservation_payment',
      'reservation_cancellation',
      'family_settlement'
    )
  ),
  entity_id uuid not null,
  label text,
  created_at timestamptz not null default now()
);

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  actor_user_id uuid references profiles(id),
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  old_values jsonb,
  new_values jsonb,
  occurred_at timestamptz not null default now(),
  request_id uuid
);

create index organization_members_user_idx on organization_members(user_id);
create index buildings_org_name_idx on buildings(organization_id, name);
create index units_org_building_idx on units(organization_id, building_id);
create index units_org_status_idx on units(organization_id, status);
create index units_org_mode_idx on units(organization_id, rental_mode);
create index contacts_org_idx on contacts(organization_id);
create index contacts_search_idx on contacts using gin (
  (
    immutable_unaccent(
      coalesce(first_name, '') || ' ' ||
      coalesce(last_name, '') || ' ' ||
      coalesce(business_name, '') || ' ' ||
      coalesce(dni, '') || ' ' ||
      coalesce(phone, '') || ' ' ||
      coalesce(email, '')
    )
  ) gin_trgm_ops
);
create index leases_org_unit_idx on leases(organization_id, unit_id);
create index leases_org_status_end_idx on leases(organization_id, status, end_date);
create index leases_org_next_adjustment_idx on leases(organization_id, next_adjustment_date);
create index lease_charges_org_status_due_idx on lease_charges(organization_id, status, due_date);
create index lease_charges_org_unit_period_idx on lease_charges(organization_id, unit_id, period_month);
create index lease_charge_items_charge_type_idx on lease_charge_items(charge_id, item_type);
create index lease_payments_org_date_idx on lease_payments(organization_id, payment_date);
create index building_expense_periods_building_month_idx on building_expense_periods(building_id, period_month);
create index expense_allocations_period_unit_idx on expense_allocations(period_id, unit_id);
create index distribution_groups_org_unit_dates_idx on distribution_groups(organization_id, unit_id, valid_from, valid_to);
create index family_settlements_org_beneficiary_period_idx on family_settlements(organization_id, beneficiary_contact_id, period_start, period_end);
create index temporary_reservations_org_unit_dates_idx on temporary_reservations(organization_id, unit_id, start_date, end_date);
create index reservation_payments_org_reservation_idx on reservation_payments(organization_id, reservation_id);
create index audit_logs_org_entity_idx on audit_logs(organization_id, entity_type, entity_id);
create index audit_logs_org_time_idx on audit_logs(organization_id, occurred_at desc);

create or replace function is_org_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from organization_members om
    where om.organization_id = target_organization_id
      and om.user_id = auth.uid()
  );
$$;

create or replace function has_org_role(target_organization_id uuid, allowed_roles app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from organization_members om
    where om.organization_id = target_organization_id
      and om.user_id = auth.uid()
      and om.role = any(allowed_roles)
  );
$$;

create or replace function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  if to_jsonb(new) ? 'version' then
    new.version = old.version + 1;
  end if;
  return new;
end;
$$;

create trigger touch_organizations before update on organizations
  for each row execute function touch_updated_at();
create trigger touch_profiles before update on profiles
  for each row execute function touch_updated_at();
create trigger touch_buildings before update on buildings
  for each row execute function touch_updated_at();
create trigger touch_units before update on units
  for each row execute function touch_updated_at();
create trigger touch_contacts before update on contacts
  for each row execute function touch_updated_at();
create trigger touch_leases before update on leases
  for each row execute function touch_updated_at();
create trigger touch_lease_charges before update on lease_charges
  for each row execute function touch_updated_at();
create trigger touch_lease_payments before update on lease_payments
  for each row execute function touch_updated_at();
create trigger touch_building_expense_periods before update on building_expense_periods
  for each row execute function touch_updated_at();
create trigger touch_building_expense_items before update on building_expense_items
  for each row execute function touch_updated_at();
create trigger touch_unit_expenses before update on unit_expenses
  for each row execute function touch_updated_at();
create trigger touch_family_settlements before update on family_settlements
  for each row execute function touch_updated_at();
create trigger touch_temporary_reservations before update on temporary_reservations
  for each row execute function touch_updated_at();
create trigger touch_calendar_notes before update on calendar_notes
  for each row execute function touch_updated_at();

create or replace function assert_distribution_total(target_distribution_group_id uuid)
returns void
language plpgsql
as $$
declare
  total numeric(7, 4);
begin
  select coalesce(sum(percentage), 0)
    into total
  from distribution_shares
  where distribution_group_id = target_distribution_group_id;

  if total <> 100.0000 then
    raise exception 'La distribucion familiar debe sumar exactamente 100%%. Suma actual: %%', total;
  end if;
end;
$$;

create or replace function assert_payment_does_not_exceed_balance()
returns trigger
language plpgsql
as $$
declare
  item_due numeric(14, 2);
  already_allocated numeric(14, 2);
  payment_amount numeric(14, 2);
  payment_allocated numeric(14, 2);
begin
  select amount_due, currency
    into item_due, new.currency
  from lease_charge_items
  where id = new.charge_item_id;

  select received_amount
    into payment_amount
  from lease_payments
  where id = new.payment_id;

  select coalesce(sum(allocated_amount), 0)
    into already_allocated
  from lease_payment_allocations
  where charge_item_id = new.charge_item_id
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if already_allocated + new.allocated_amount > item_due then
    raise exception 'El pago supera el saldo pendiente del concepto.';
  end if;

  select coalesce(sum(allocated_amount), 0)
    into payment_allocated
  from lease_payment_allocations
  where payment_id = new.payment_id
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if payment_allocated + new.allocated_amount > payment_amount then
    raise exception 'La imputacion supera el importe recibido.';
  end if;

  return new;
end;
$$;

create trigger lease_payment_allocations_balance_guard
  before insert or update on lease_payment_allocations
  for each row execute function assert_payment_does_not_exceed_balance();

create or replace view fixed_rent_account_statement as
select
  lc.organization_id,
  lc.unit_id,
  lc.lease_id,
  lc.id as charge_id,
  lci.id as charge_item_id,
  lc.due_date,
  null::date as payment_date,
  lci.description,
  lci.item_type::text as concept_type,
  lci.amount_due as debit,
  0::numeric(14, 2) as credit,
  lci.currency,
  lc.status::text as status
from lease_charges lc
join lease_charge_items lci on lci.charge_id = lc.id
union all
select
  lp.organization_id,
  lp.unit_id,
  lp.lease_id,
  lc.id as charge_id,
  lci.id as charge_item_id,
  lc.due_date,
  lp.payment_date,
  'Pago registrado' as description,
  'payment' as concept_type,
  0::numeric(14, 2) as debit,
  lpa.allocated_amount as credit,
  lpa.currency,
  lp.status::text as status
from lease_payment_allocations lpa
join lease_payments lp on lp.id = lpa.payment_id
join lease_charge_items lci on lci.id = lpa.charge_item_id
join lease_charges lc on lc.id = lci.charge_id
where lp.status = 'valid';

alter table organizations enable row level security;
alter table profiles enable row level security;
alter table organization_members enable row level security;
alter table buildings enable row level security;
alter table units enable row level security;
alter table contacts enable row level security;
alter table leases enable row level security;
alter table lease_parties enable row level security;
alter table lease_adjustments enable row level security;
alter table lease_charges enable row level security;
alter table lease_charge_items enable row level security;
alter table lease_payments enable row level security;
alter table lease_payment_allocations enable row level security;
alter table expense_categories enable row level security;
alter table building_expense_periods enable row level security;
alter table building_expense_items enable row level security;
alter table expense_allocations enable row level security;
alter table unit_expenses enable row level security;
alter table lease_terminations enable row level security;
alter table distribution_groups enable row level security;
alter table distribution_shares enable row level security;
alter table family_settlements enable row level security;
alter table family_settlement_items enable row level security;
alter table temporary_reservations enable row level security;
alter table reservation_payments enable row level security;
alter table reservation_cancellations enable row level security;
alter table calendar_notes enable row level security;
alter table files enable row level security;
alter table file_links enable row level security;
alter table audit_logs enable row level security;

create policy "profiles read own" on profiles
  for select using (id = auth.uid());

create policy "organization members can read organizations" on organizations
  for select using (is_org_member(id));

create policy "organization admins manage organizations" on organizations
  for update using (has_org_role(id, array['owner', 'admin']::app_role[]));

create policy "members read memberships" on organization_members
  for select using (is_org_member(organization_id));

create policy "admins manage memberships" on organization_members
  for all using (has_org_role(organization_id, array['owner', 'admin']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin']::app_role[]));

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'buildings',
    'units',
    'contacts',
    'leases',
    'lease_parties',
    'lease_adjustments',
    'lease_charges',
    'lease_charge_items',
    'lease_payments',
    'lease_payment_allocations',
    'expense_categories',
    'building_expense_periods',
    'building_expense_items',
    'expense_allocations',
    'unit_expenses',
    'lease_terminations',
    'distribution_groups',
    'distribution_shares',
    'family_settlements',
    'family_settlement_items',
    'temporary_reservations',
    'reservation_payments',
    'reservation_cancellations',
    'calendar_notes',
    'files',
    'file_links',
    'audit_logs'
  ]
  loop
    execute format('create policy %I on %I for select using (is_org_member(organization_id))', table_name || '_select', table_name);
    execute format(
      'create policy %I on %I for insert with check (has_org_role(organization_id, array[''owner'', ''admin'', ''editor'']::app_role[]))',
      table_name || '_insert',
      table_name
    );
    execute format(
      'create policy %I on %I for update using (has_org_role(organization_id, array[''owner'', ''admin'', ''editor'']::app_role[])) with check (has_org_role(organization_id, array[''owner'', ''admin'', ''editor'']::app_role[]))',
      table_name || '_update',
      table_name
    );
  end loop;
end $$;
