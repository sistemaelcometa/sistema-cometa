-- El Cometa - Supabase schema
-- Base limpia para operar con PostgreSQL como fuente de verdad.

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists btree_gist;
create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;

create or replace function immutable_unaccent(value text)
returns text
language sql
immutable
parallel safe
as $$
  select extensions.unaccent(value);
$$;

create type app_role as enum ('owner', 'admin', 'editor', 'viewer');
create type member_status as enum ('pending', 'active', 'disabled');
create type contact_type as enum ('person', 'company');
create type lifecycle_status as enum ('active', 'archived');
create type urban_unit_status as enum ('available', 'rented', 'maintenance', 'archived');
create type urban_lease_status as enum ('draft', 'upcoming', 'active', 'finalized', 'rescinded', 'archived');
create type charge_status as enum ('pending', 'partial', 'paid', 'cancelled');
create type charge_item_type as enum ('rent', 'rent_surcharge', 'building_expense', 'expense_surcharge', 'unit_expense', 'rescission', 'other');
create type record_status as enum ('valid', 'voided');
create type payment_method as enum ('transfer', 'cash', 'deposit', 'card', 'other');
create type expense_period_status as enum ('draft', 'calculated', 'closed', 'cancelled');
create type expense_scope as enum ('urban', 'pde', 'both');
create type settlement_status as enum ('draft', 'closed', 'corrected', 'cancelled');
create type maintenance_status as enum ('open', 'finished', 'cancelled');
create type pde_reservation_status as enum ('reserved', 'deposit_received', 'paid', 'cancelled', 'finished');
create type pde_payment_type as enum ('deposit', 'balance', 'other');
create type pde_expense_target as enum ('unit', 'general_50_50');
create type calendar_scope as enum ('general', 'urban', 'pde');
create type file_status as enum ('pending_link', 'active', 'archived', 'orphaned');
create type operation_status as enum ('in_progress', 'succeeded', 'failed');

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  status lifecycle_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role app_role not null default 'viewer',
  status member_status not null default 'pending',
  enabled_at timestamptz,
  enabled_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_type contact_type not null default 'person',
  first_name text,
  last_name text,
  business_name text,
  document_number text,
  phone text,
  email text,
  address text,
  notes text,
  is_tenant boolean not null default false,
  is_guest boolean not null default false,
  is_provider boolean not null default false,
  is_worker boolean not null default false,
  is_family_beneficiary boolean not null default false,
  status lifecycle_status not null default 'active',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint contact_person_has_name
    check (contact_type <> 'person' or first_name is not null or last_name is not null),
  constraint contact_company_has_name
    check (contact_type <> 'company' or business_name is not null)
);

create table urban_buildings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  address text,
  has_expenses boolean not null default true,
  status lifecycle_status not null default 'active',
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create unique index urban_buildings_active_name_idx
  on urban_buildings(organization_id, lower(name))
  where status = 'active';

create table urban_units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  building_id uuid not null references urban_buildings(id) on delete restrict,
  name text not null,
  floor text,
  surface_m2 numeric(10, 2) not null check (surface_m2 > 0),
  status urban_unit_status not null default 'available',
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create unique index urban_units_active_name_idx
  on urban_units(building_id, lower(name))
  where status <> 'archived';

create table urban_leases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references urban_units(id) on delete restrict,
  primary_tenant_contact_id uuid not null references contacts(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  current_amount numeric(14, 2) not null check (current_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  monthly_due_day integer not null check (monthly_due_day between 1 and 28),
  adjustment_frequency_months integer check (adjustment_frequency_months > 0),
  last_adjustment_date date,
  next_adjustment_date date,
  status urban_lease_status not null default 'draft',
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (end_date > start_date)
);

alter table urban_leases
  add constraint urban_leases_no_effective_overlap
  exclude using gist (
    unit_id with =,
    daterange(start_date, end_date, '[]') with &&
  )
  where (status in ('upcoming', 'active'));

create table urban_lease_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references urban_leases(id) on delete restrict,
  effective_date date not null,
  previous_amount numeric(14, 2) not null check (previous_amount >= 0),
  new_amount numeric(14, 2) not null check (new_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  next_adjustment_date date,
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table urban_charges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references urban_leases(id) on delete restrict,
  unit_id uuid not null references urban_units(id) on delete restrict,
  period_month date not null,
  due_date date not null,
  status charge_status not null default 'pending',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  unique (lease_id, period_month),
  constraint urban_charges_period_is_month_start
    check (period_month = date_trunc('month', period_month)::date)
);

create table urban_charge_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  charge_id uuid not null references urban_charges(id) on delete cascade,
  item_type charge_item_type not null,
  description text not null,
  amount_due numeric(14, 2) not null check (amount_due >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  source_entity_type text,
  source_entity_id uuid,
  created_at timestamptz not null default now()
);

create table urban_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  lease_id uuid not null references urban_leases(id) on delete restrict,
  unit_id uuid not null references urban_units(id) on delete restrict,
  payment_date date not null,
  received_amount numeric(14, 2) not null check (received_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  payment_method payment_method not null,
  notes text,
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  operation_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table urban_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  payment_id uuid not null references urban_payments(id) on delete restrict,
  charge_item_id uuid not null references urban_charge_items(id) on delete restrict,
  allocated_amount numeric(14, 2) not null check (allocated_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  created_at timestamptz not null default now()
);

create table expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  name text not null,
  scope expense_scope not null default 'both',
  status lifecycle_status not null default 'active',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table urban_expense_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  building_id uuid not null references urban_buildings(id) on delete restrict,
  period_month date not null,
  status expense_period_status not null default 'draft',
  notes text,
  closed_at timestamptz,
  closed_by uuid references profiles(id),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  unique (building_id, period_month),
  constraint urban_expense_periods_month_start
    check (period_month = date_trunc('month', period_month)::date)
);

create table urban_expense_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  period_id uuid not null references urban_expense_periods(id) on delete restrict,
  category_id uuid references expense_categories(id) on delete set null,
  expense_date date not null,
  provider_contact_id uuid references contacts(id) on delete set null,
  description text not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  transfer_to_tenant boolean not null default false,
  notes text,
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table urban_expense_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  expense_item_id uuid not null references urban_expense_items(id) on delete restrict,
  period_id uuid not null references urban_expense_periods(id) on delete restrict,
  unit_id uuid not null references urban_units(id) on delete restrict,
  unit_surface_m2_snapshot numeric(10, 2) not null check (unit_surface_m2_snapshot > 0),
  building_total_surface_m2_snapshot numeric(10, 2) not null check (building_total_surface_m2_snapshot > 0),
  percentage_snapshot numeric(9, 6) not null check (percentage_snapshot >= 0),
  allocated_amount numeric(14, 2) not null check (allocated_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  transfer_to_tenant boolean not null,
  tenant_amount numeric(14, 2) not null default 0 check (tenant_amount >= 0),
  charge_item_id uuid references urban_charge_items(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (expense_item_id, unit_id),
  check (tenant_amount <= allocated_amount)
);

create table family_distribution_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references urban_units(id) on delete restrict,
  valid_from date not null,
  valid_to date,
  status lifecycle_status not null default 'active',
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (valid_to is null or valid_to >= valid_from)
);

alter table family_distribution_groups
  add constraint family_distribution_groups_no_overlap
  exclude using gist (
    unit_id with =,
    daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[]') with &&
  )
  where (status = 'active');

create table family_distribution_shares (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  distribution_group_id uuid not null references family_distribution_groups(id) on delete cascade,
  beneficiary_contact_id uuid not null references contacts(id) on delete restrict,
  percentage numeric(7, 4) not null check (percentage > 0 and percentage <= 100),
  created_at timestamptz not null default now(),
  unique (distribution_group_id, beneficiary_contact_id)
);

create table family_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  version integer not null default 1,
  corrects_settlement_id uuid references family_settlements(id) on delete restrict,
  is_current boolean not null default true,
  status settlement_status not null default 'draft',
  total_ars numeric(14, 2) not null default 0 check (total_ars >= 0),
  total_usd numeric(14, 2) not null default 0 check (total_usd >= 0),
  notes text,
  closed_at timestamptz,
  closed_by uuid references profiles(id),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_end >= period_start)
);

create table family_settlement_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  settlement_id uuid not null references family_settlements(id) on delete cascade,
  unit_id uuid not null references urban_units(id) on delete restrict,
  beneficiary_contact_id uuid not null references contacts(id) on delete restrict,
  source_payment_allocation_id uuid references urban_payment_allocations(id) on delete restrict,
  distribution_group_id uuid references family_distribution_groups(id) on delete restrict,
  distribution_share_id uuid references family_distribution_shares(id) on delete restrict,
  base_amount numeric(14, 2) not null check (base_amount >= 0),
  percentage_snapshot numeric(7, 4) not null check (percentage_snapshot > 0),
  settled_amount numeric(14, 2) not null check (settled_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  description text,
  created_at timestamptz not null default now()
);

create table family_settlement_corrections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  previous_settlement_id uuid not null references family_settlements(id) on delete restrict,
  new_settlement_id uuid not null references family_settlements(id) on delete restrict,
  reason text not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table maintenance_tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references urban_units(id) on delete restrict,
  title text not null,
  detail text,
  worker_contact_id uuid references contacts(id) on delete set null,
  status maintenance_status not null default 'open',
  opened_at date not null default current_date,
  finished_at date,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table maintenance_expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  task_id uuid not null references maintenance_tasks(id) on delete restrict,
  category_id uuid references expense_categories(id) on delete set null,
  expense_date date not null,
  description text not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table pde_units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  description text,
  status lifecycle_status not null default 'active',
  display_color text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create unique index pde_units_active_name_idx
  on pde_units(organization_id, lower(name))
  where status = 'active';

create table pde_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_id uuid not null references pde_units(id) on delete restrict,
  guest_contact_id uuid references contacts(id) on delete set null,
  guest_name_snapshot text not null,
  guest_phone_snapshot text,
  guest_email_snapshot text,
  start_date date not null,
  end_date date not null,
  total_amount numeric(14, 2) not null check (total_amount >= 0),
  currency char(3) not null default 'USD' check (currency in ('ARS', 'USD')),
  status pde_reservation_status not null default 'reserved',
  notes text,
  cancelled_at timestamptz,
  cancelled_by uuid references profiles(id),
  cancel_reason text,
  operation_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (end_date > start_date)
);

alter table pde_reservations
  add constraint pde_reservations_no_active_overlap
  exclude using gist (
    unit_id with =,
    daterange(start_date, end_date, '[)') with &&
  )
  where (status in ('reserved', 'deposit_received', 'paid'));

create table pde_reservation_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  reservation_id uuid not null references pde_reservations(id) on delete restrict,
  payment_type pde_payment_type not null,
  payment_date date not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null default 'USD' check (currency in ('ARS', 'USD')),
  payment_method payment_method not null,
  notes text,
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  operation_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table pde_expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  target_type pde_expense_target not null default 'unit',
  unit_id uuid references pde_units(id) on delete restrict,
  category_id uuid references expense_categories(id) on delete set null,
  expense_date date not null,
  description text not null,
  amount numeric(14, 2) not null check (amount >= 0),
  currency char(3) not null default 'USD' check (currency in ('ARS', 'USD')),
  payment_method payment_method,
  notes text,
  status record_status not null default 'valid',
  voided_at timestamptz,
  voided_by uuid references profiles(id),
  void_reason text,
  operation_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint pde_expenses_target_unit_required
    check (
      (target_type = 'unit' and unit_id is not null)
      or (target_type = 'general_50_50' and unit_id is null)
    )
);

create table pde_expense_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  expense_id uuid not null references pde_expenses(id) on delete restrict,
  unit_id uuid not null references pde_units(id) on delete restrict,
  percentage_snapshot numeric(7, 4) not null check (percentage_snapshot > 0 and percentage_snapshot <= 100),
  allocated_amount numeric(14, 2) not null check (allocated_amount >= 0),
  currency char(3) not null check (currency in ('ARS', 'USD')),
  created_at timestamptz not null default now(),
  unique (expense_id, unit_id)
);

create table calendar_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  scope calendar_scope not null default 'general',
  event_date date not null,
  title text not null,
  body text,
  status lifecycle_status not null default 'active',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  bucket text not null,
  storage_path text not null,
  original_filename text not null,
  mime_type text,
  size_bytes bigint check (size_bytes is null or size_bytes >= 0),
  status file_status not null default 'pending_link',
  uploaded_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bucket, storage_path)
);

create table file_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  file_id uuid not null references files(id) on delete restrict,
  entity_type text not null,
  entity_id uuid not null,
  label text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (file_id, entity_type, entity_id)
);

create table operation_results (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  operation_id uuid not null,
  operation_type text not null,
  request_hash text not null,
  status operation_status not null default 'in_progress',
  result_entity_type text,
  result_entity_id uuid,
  result_payload jsonb,
  error_code text,
  error_message text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (organization_id, operation_id)
);

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  actor_user_id uuid references profiles(id),
  operation_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_values jsonb,
  new_values jsonb,
  metadata jsonb,
  occurred_at timestamptz not null default now()
);

create index organization_members_user_idx on organization_members(user_id, organization_id);
create index contacts_org_status_idx on contacts(organization_id, status);
create index contacts_search_idx on contacts using gin (
  (
    immutable_unaccent(
      coalesce(first_name, '') || ' ' ||
      coalesce(last_name, '') || ' ' ||
      coalesce(business_name, '') || ' ' ||
      coalesce(document_number, '') || ' ' ||
      coalesce(phone, '') || ' ' ||
      coalesce(email, '')
    )
  ) gin_trgm_ops
);
create index urban_buildings_org_status_idx on urban_buildings(organization_id, status);
create index urban_units_org_building_status_idx on urban_units(organization_id, building_id, status);
create index urban_leases_unit_status_dates_idx on urban_leases(unit_id, status, start_date, end_date);
create index urban_leases_org_next_adjustment_idx on urban_leases(organization_id, next_adjustment_date);
create index urban_charges_org_unit_period_status_idx on urban_charges(organization_id, unit_id, period_month, status);
create index urban_payments_org_date_status_idx on urban_payments(organization_id, payment_date, status);
create index urban_expense_periods_building_month_idx on urban_expense_periods(building_id, period_month);
create index family_settlements_org_period_status_idx on family_settlements(organization_id, period_start, period_end, status);
create index maintenance_tasks_org_unit_status_idx on maintenance_tasks(organization_id, unit_id, status);
create index pde_reservations_unit_dates_status_idx on pde_reservations(unit_id, start_date, end_date, status);
create index pde_reservation_payments_reservation_date_idx on pde_reservation_payments(reservation_id, payment_date, status);
create index pde_expenses_org_date_status_idx on pde_expenses(organization_id, expense_date, status);
create index files_org_bucket_path_idx on files(organization_id, bucket, storage_path);
create index audit_logs_org_time_idx on audit_logs(organization_id, occurred_at desc);
create index audit_logs_org_operation_idx on audit_logs(organization_id, operation_id);

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
      and om.status = 'active'
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
      and om.status = 'active'
      and om.role = any(allowed_roles)
  );
$$;

create or replace function current_user_profile()
returns profiles
language sql
stable
security definer
set search_path = public
as $$
  select p.*
  from profiles p
  where p.id = auth.uid();
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

create or replace function assert_urban_payment_allocation_balance()
returns trigger
language plpgsql
as $$
declare
  item_due numeric(14, 2);
  item_currency char(3);
  payment_amount numeric(14, 2);
  payment_currency char(3);
  allocated_to_item numeric(14, 2);
  allocated_from_payment numeric(14, 2);
begin
  select amount_due, currency
    into item_due, item_currency
  from urban_charge_items
  where id = new.charge_item_id;

  select received_amount, currency
    into payment_amount, payment_currency
  from urban_payments
  where id = new.payment_id
    and status = 'valid';

  if item_due is null or payment_amount is null then
    raise exception 'El pago o concepto no existe o no esta vigente.';
  end if;

  if new.currency <> item_currency or new.currency <> payment_currency then
    raise exception 'La moneda de la imputacion no coincide.';
  end if;

  select coalesce(sum(allocated_amount), 0)
    into allocated_to_item
  from urban_payment_allocations
  where charge_item_id = new.charge_item_id
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if allocated_to_item + new.allocated_amount > item_due then
    raise exception 'La imputacion supera el saldo del concepto.';
  end if;

  select coalesce(sum(allocated_amount), 0)
    into allocated_from_payment
  from urban_payment_allocations
  where payment_id = new.payment_id
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if allocated_from_payment + new.allocated_amount > payment_amount then
    raise exception 'La imputacion supera el importe recibido.';
  end if;

  return new;
end;
$$;

create or replace function assert_pde_payment_does_not_exceed_total()
returns trigger
language plpgsql
as $$
declare
  reservation_total numeric(14, 2);
  reservation_currency char(3);
  already_paid numeric(14, 2);
begin
  select total_amount, currency
    into reservation_total, reservation_currency
  from pde_reservations
  where id = new.reservation_id
    and status in ('reserved', 'deposit_received', 'paid');

  if reservation_total is null then
    raise exception 'La reserva no existe o no esta vigente.';
  end if;

  if new.currency <> reservation_currency then
    raise exception 'La moneda del cobro no coincide con la reserva.';
  end if;

  select coalesce(sum(amount), 0)
    into already_paid
  from pde_reservation_payments
  where reservation_id = new.reservation_id
    and status = 'valid'
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if already_paid + new.amount > reservation_total then
    raise exception 'El cobro supera el total de la reserva.';
  end if;

  return new;
end;
$$;

create or replace function assert_family_distribution_total(target_distribution_group_id uuid)
returns void
language plpgsql
as $$
declare
  total numeric(7, 4);
begin
  select coalesce(sum(percentage), 0)
    into total
  from family_distribution_shares
  where distribution_group_id = target_distribution_group_id;

  if total <> 100.0000 then
    raise exception 'La distribucion familiar debe sumar exactamente 100%%. Suma actual: %', total;
  end if;
end;
$$;

create trigger touch_organizations before update on organizations for each row execute function touch_updated_at();
create trigger touch_profiles before update on profiles for each row execute function touch_updated_at();
create trigger touch_organization_members before update on organization_members for each row execute function touch_updated_at();
create trigger touch_contacts before update on contacts for each row execute function touch_updated_at();
create trigger touch_urban_buildings before update on urban_buildings for each row execute function touch_updated_at();
create trigger touch_urban_units before update on urban_units for each row execute function touch_updated_at();
create trigger touch_urban_leases before update on urban_leases for each row execute function touch_updated_at();
create trigger touch_urban_charges before update on urban_charges for each row execute function touch_updated_at();
create trigger touch_urban_payments before update on urban_payments for each row execute function touch_updated_at();
create trigger touch_expense_categories before update on expense_categories for each row execute function touch_updated_at();
create trigger touch_urban_expense_periods before update on urban_expense_periods for each row execute function touch_updated_at();
create trigger touch_urban_expense_items before update on urban_expense_items for each row execute function touch_updated_at();
create trigger touch_family_distribution_groups before update on family_distribution_groups for each row execute function touch_updated_at();
create trigger touch_family_settlements before update on family_settlements for each row execute function touch_updated_at();
create trigger touch_maintenance_tasks before update on maintenance_tasks for each row execute function touch_updated_at();
create trigger touch_maintenance_expenses before update on maintenance_expenses for each row execute function touch_updated_at();
create trigger touch_pde_units before update on pde_units for each row execute function touch_updated_at();
create trigger touch_pde_reservations before update on pde_reservations for each row execute function touch_updated_at();
create trigger touch_pde_reservation_payments before update on pde_reservation_payments for each row execute function touch_updated_at();
create trigger touch_pde_expenses before update on pde_expenses for each row execute function touch_updated_at();
create trigger touch_calendar_notes before update on calendar_notes for each row execute function touch_updated_at();
create trigger touch_files before update on files for each row execute function touch_updated_at();

create trigger urban_payment_allocations_balance_guard
  before insert or update on urban_payment_allocations
  for each row execute function assert_urban_payment_allocation_balance();

create trigger pde_payments_total_guard
  before insert or update on pde_reservation_payments
  for each row execute function assert_pde_payment_does_not_exceed_total();

create or replace view urban_account_statement
with (security_invoker = true) as
select
  uc.organization_id,
  uc.unit_id,
  uc.lease_id,
  uc.id as charge_id,
  uci.id as charge_item_id,
  uc.due_date,
  null::date as payment_date,
  uci.description,
  uci.item_type::text as movement_type,
  uci.amount_due as debit,
  0::numeric(14, 2) as credit,
  uci.currency,
  uc.status::text as status
from urban_charges uc
join urban_charge_items uci on uci.charge_id = uc.id
union all
select
  up.organization_id,
  up.unit_id,
  up.lease_id,
  uc.id as charge_id,
  uci.id as charge_item_id,
  uc.due_date,
  up.payment_date,
  'Pago registrado' as description,
  'payment' as movement_type,
  0::numeric(14, 2) as debit,
  upa.allocated_amount as credit,
  upa.currency,
  up.status::text as status
from urban_payment_allocations upa
join urban_payments up on up.id = upa.payment_id
join urban_charge_items uci on uci.id = upa.charge_item_id
join urban_charges uc on uc.id = uci.charge_id
where up.status = 'valid';

create or replace view pde_reservation_balances
with (security_invoker = true) as
select
  r.organization_id,
  r.id as reservation_id,
  r.unit_id,
  r.total_amount,
  r.currency,
  coalesce(sum(p.amount) filter (where p.status = 'valid'), 0)::numeric(14, 2) as paid_amount,
  (r.total_amount - coalesce(sum(p.amount) filter (where p.status = 'valid'), 0))::numeric(14, 2) as balance_amount,
  (r.end_date - r.start_date) as nights_count,
  case
    when (r.end_date - r.start_date) > 0 then round(r.total_amount / (r.end_date - r.start_date), 2)
    else 0
  end as nightly_amount
from pde_reservations r
left join pde_reservation_payments p on p.reservation_id = r.id
group by r.id;

alter table organizations enable row level security;
alter table profiles enable row level security;
alter table organization_members enable row level security;
alter table contacts enable row level security;
alter table urban_buildings enable row level security;
alter table urban_units enable row level security;
alter table urban_leases enable row level security;
alter table urban_lease_adjustments enable row level security;
alter table urban_charges enable row level security;
alter table urban_charge_items enable row level security;
alter table urban_payments enable row level security;
alter table urban_payment_allocations enable row level security;
alter table expense_categories enable row level security;
alter table urban_expense_periods enable row level security;
alter table urban_expense_items enable row level security;
alter table urban_expense_allocations enable row level security;
alter table family_distribution_groups enable row level security;
alter table family_distribution_shares enable row level security;
alter table family_settlements enable row level security;
alter table family_settlement_items enable row level security;
alter table family_settlement_corrections enable row level security;
alter table maintenance_tasks enable row level security;
alter table maintenance_expenses enable row level security;
alter table pde_units enable row level security;
alter table pde_reservations enable row level security;
alter table pde_reservation_payments enable row level security;
alter table pde_expenses enable row level security;
alter table pde_expense_allocations enable row level security;
alter table calendar_notes enable row level security;
alter table files enable row level security;
alter table file_links enable row level security;
alter table operation_results enable row level security;
alter table audit_logs enable row level security;

create policy profiles_select_own on profiles
  for select using (id = auth.uid());

create policy profiles_insert_own on profiles
  for insert with check (id = auth.uid());

create policy profiles_update_own on profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

create policy organizations_select_member on organizations
  for select using (is_org_member(id));

create policy organizations_update_admin on organizations
  for update using (has_org_role(id, array['owner', 'admin']::app_role[]))
  with check (has_org_role(id, array['owner', 'admin']::app_role[]));

create policy organization_members_select_member on organization_members
  for select using (is_org_member(organization_id));

create policy organization_members_insert_admin on organization_members
  for insert with check (has_org_role(organization_id, array['owner', 'admin']::app_role[]));

create policy organization_members_update_admin on organization_members
  for update using (has_org_role(organization_id, array['owner', 'admin']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin']::app_role[]));

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'contacts',
    'urban_buildings',
    'urban_units',
    'urban_leases',
    'urban_lease_adjustments',
    'urban_charges',
    'urban_charge_items',
    'urban_payments',
    'urban_payment_allocations',
    'expense_categories',
    'urban_expense_periods',
    'urban_expense_items',
    'urban_expense_allocations',
    'family_distribution_groups',
    'family_distribution_shares',
    'family_settlements',
    'family_settlement_items',
    'family_settlement_corrections',
    'maintenance_tasks',
    'maintenance_expenses',
    'pde_units',
    'pde_reservations',
    'pde_reservation_payments',
    'pde_expenses',
    'pde_expense_allocations',
    'calendar_notes',
    'files',
    'file_links',
    'operation_results',
    'audit_logs'
  ]
  loop
    execute format(
      'create policy %I on %I for select using (is_org_member(organization_id))',
      table_name || '_select_member',
      table_name
    );
  end loop;
end $$;

create policy contacts_insert_editor on contacts
  for insert with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy contacts_update_editor on contacts
  for update using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy expense_categories_insert_editor on expense_categories
  for insert with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy expense_categories_update_editor on expense_categories
  for update using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy calendar_notes_insert_editor on calendar_notes
  for insert with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy calendar_notes_update_editor on calendar_notes
  for update using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy files_insert_editor on files
  for insert with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

create policy files_update_editor on files
  for update using (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]))
  with check (has_org_role(organization_id, array['owner', 'admin', 'editor']::app_role[]));

insert into organizations (name, slug)
values ('El Cometa', 'el-cometa')
on conflict (slug) do nothing;
