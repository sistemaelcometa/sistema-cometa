-- El Cometa agricola: movimientos independientes de Alquileres.
begin;

create table if not exists cometa_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  kind text not null check (kind in ('income','expense')),
  name text not null check (length(trim(name)) between 1 and 100),
  description text,
  unique(organization_id,kind,name)
);
create table if not exists cometa_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  kind text not null check (kind in ('income','expense')),
  movement_date date not null,
  category_id uuid not null references cometa_categories(id),
  concept text not null check (length(trim(concept)) between 1 and 500),
  counterparty text,
  document_number text,
  notes text,
  amount numeric(14,2) not null check (amount>0),
  currency text not null check (currency in ('ARS','USD')),
  receipt_path text,
  receipt_name text,
  status record_status not null default 'valid',
  operation_id uuid not null,
  request_hash text not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  voided_by uuid references profiles(id),
  voided_at timestamptz,
  unique(organization_id,operation_id)
);
create index if not exists cometa_movements_org_date_idx on cometa_movements(organization_id,movement_date desc,id);
alter table cometa_categories enable row level security;
alter table cometa_movements enable row level security;
drop policy if exists cometa_categories_read on cometa_categories;
create policy cometa_categories_read on cometa_categories for select to authenticated using(is_org_member(organization_id));
drop policy if exists cometa_movements_read on cometa_movements;
create policy cometa_movements_read on cometa_movements for select to authenticated using(is_org_member(organization_id));
revoke all on cometa_categories,cometa_movements from anon,authenticated;
grant select on cometa_categories,cometa_movements to authenticated;

create or replace function ensure_cometa_categories(target_organization_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then
    raise exception 'No tenes permisos para configurar El Cometa.';
  end if;
  insert into cometa_categories(organization_id,kind,name,description)
  select target_organization_id,seed.kind,seed.name,seed.description from (values
    ('expense','Combustible','Solo para uso de ciudad. El combustible para labores de campo va en Insumos.'),
    ('expense','Insumos','Todos los insumos agricolas, incluido el combustible para labores de campo.'),
    ('expense','Gastos de comercialización',null),
    ('expense','Reparaciones',null),
    ('expense','Gastos varios',null),
    ('expense','Alquileres',null),
    ('expense','Seguros',null),
    ('income','Ventas de cereal',null),
    ('income','Ventas de bienes de uso',null)
  ) as seed(kind,name,description)
  on conflict(organization_id,kind,name) do nothing;
end;
$$;

-- Inicializa tambien las organizaciones existentes; las nuevas se inicializan
-- al abrir el modulo con un usuario editor.
insert into cometa_categories(organization_id,kind,name,description)
select o.id,seed.kind,seed.name,seed.description from organizations o cross join (values
  ('expense','Combustible','Solo para uso de ciudad. El combustible para labores de campo va en Insumos.'),
  ('expense','Insumos','Todos los insumos agricolas, incluido el combustible para labores de campo.'),
  ('expense','Gastos de comercialización',null),('expense','Reparaciones',null),
  ('expense','Gastos varios',null),('expense','Alquileres',null),('expense','Seguros',null),
  ('income','Ventas de cereal',null),('income','Ventas de bienes de uso',null)
) as seed(kind,name,description) on conflict(organization_id,kind,name) do nothing;

create or replace function register_cometa_movement(
  target_organization_id uuid, movement_kind text, entry_date date, entry_category_id uuid,
  entry_amount numeric, entry_currency text, entry_concept text,
  entry_counterparty text default null, entry_document_number text default null,
  entry_notes text default null, receipt_path text default null, receipt_name text default null,
  operation_id uuid default null
)
returns cometa_movements language plpgsql security definer set search_path=public as $$
declare saved cometa_movements; signature text;
begin
  if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar movimientos.';
  end if;
  if movement_kind not in ('income','expense') or movement_kind is null
    or entry_currency not in ('ARS','USD') or entry_currency is null
    or entry_date is null or operation_id is null then raise exception 'Datos del movimiento incompletos.'; end if;
  if entry_amount is null or entry_amount<=0 or entry_amount>=1000000000000 or entry_amount<>round(entry_amount,2)
    or entry_amount::text in ('NaN','Infinity','-Infinity') then raise exception 'El importe debe ser positivo y tener hasta dos decimales.'; end if;
  if length(trim(coalesce(entry_concept,''))) not between 1 and 500 then raise exception 'El concepto es obligatorio (hasta 500 caracteres).'; end if;
  if length(coalesce(entry_counterparty,''))>200 or length(coalesce(entry_document_number,''))>100 or length(coalesce(entry_notes,''))>4000 then
    raise exception 'El texto ingresado es demasiado largo.';
  end if;
  if not exists(select 1 from cometa_categories c where c.id=entry_category_id and c.organization_id=target_organization_id and c.kind=movement_kind) then
    raise exception 'La categoria no corresponde a este movimiento u organizacion.';
  end if;
  if receipt_path is not null then
    if receipt_path not like 'org/'||target_organization_id::text||'/cometa/'||operation_id::text||'/%'
      or nullif(trim(receipt_name),'') is null
      or not exists(select 1 from storage.objects o where o.bucket_id='receipts' and o.name=receipt_path) then
      raise exception 'El comprobante no existe o no corresponde a esta organizacion.';
    end if;
  elsif receipt_name is not null then raise exception 'Falta el archivo del comprobante.'; end if;
  signature:=md5(jsonb_build_array(movement_kind,entry_date,entry_category_id,entry_amount,entry_currency,trim(entry_concept),
    nullif(trim(entry_counterparty),''),nullif(trim(entry_document_number),''),nullif(trim(entry_notes),''),receipt_path,receipt_name)::text);
  perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text||operation_id::text,0));
  select * into saved from cometa_movements m where m.organization_id=target_organization_id and m.operation_id=register_cometa_movement.operation_id;
  if found then
    if saved.request_hash<>signature then raise exception 'La operacion ya fue usada con otros datos.'; end if;
    return saved;
  end if;
  insert into cometa_movements(organization_id,kind,movement_date,category_id,concept,counterparty,document_number,notes,amount,currency,
    receipt_path,receipt_name,operation_id,request_hash,created_by)
  values(target_organization_id,movement_kind,entry_date,entry_category_id,trim(entry_concept),nullif(trim(entry_counterparty),''),
    nullif(trim(entry_document_number),''),nullif(trim(entry_notes),''),entry_amount,entry_currency,receipt_path,receipt_name,operation_id,signature,auth.uid())
  returning * into saved;
  insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,new_values)
  values(target_organization_id,auth.uid(),'cometa_movement_registered','cometa_movement',saved.id,to_jsonb(saved));
  return saved;
end;
$$;

create or replace function void_cometa_movement(target_organization_id uuid,target_movement_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare previous cometa_movements;
begin
  if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then
    raise exception 'No tenes permisos para anular movimientos.';
  end if;
  select * into previous from cometa_movements where id=target_movement_id and organization_id=target_organization_id for update;
  if not found then raise exception 'El movimiento no existe.'; end if;
  if previous.status='voided' then return; end if;
  update cometa_movements set status='voided',voided_at=now(),voided_by=auth.uid() where id=previous.id;
  insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,old_values)
  values(target_organization_id,auth.uid(),'cometa_movement_voided','cometa_movement',previous.id,to_jsonb(previous));
end;
$$;

create or replace function get_cometa_report(
  target_organization_id uuid,from_date date default null,to_date date default null,
  kind_filter text default null,category_filter uuid default null,currency_filter text default null,
  search_text text default null,page_size integer default 20,page_offset integer default 0
)
returns jsonb language sql stable security definer set search_path=public as $$
with filtered as (
  select m.*,c.name as category_name from cometa_movements m join cometa_categories c on c.id=m.category_id and c.organization_id=m.organization_id
  where m.organization_id=target_organization_id and is_org_member(target_organization_id) and m.status='valid'
    and (from_date is null or m.movement_date>=from_date) and (to_date is null or m.movement_date<=to_date)
    and (kind_filter is null or m.kind=kind_filter) and (category_filter is null or m.category_id=category_filter)
    and (currency_filter is null or m.currency=currency_filter)
    and (nullif(trim(search_text),'') is null or concat_ws(' ',m.concept,m.counterparty,m.document_number,m.notes,c.name) ilike '%'||trim(search_text)||'%')
), grouped as (
  select currency,category_id,category_name,sum(amount) as amount from filtered where kind='expense' group by currency,category_id,category_name
), totals as (
  select currency,coalesce(sum(amount) filter(where kind='income'),0) as income,
    coalesce(sum(amount) filter(where kind='expense'),0) as expense from filtered group by currency
), page as (
  select * from filtered order by movement_date desc,created_at desc,id limit greatest(1,least(coalesce(page_size,20),100)) offset greatest(coalesce(page_offset,0),0)
)
select jsonb_build_object(
  'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.kind,c.name) from cometa_categories c
    where c.organization_id=target_organization_id and is_org_member(target_organization_id)),'[]'::jsonb),
  'rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb),
  'total',(select count(*) from filtered),
  'totals',coalesce((select jsonb_agg(to_jsonb(totals)) from totals),'[]'::jsonb),
  'expensesByCategory',coalesce((select jsonb_agg(to_jsonb(grouped) order by amount desc,category_name) from grouped),'[]'::jsonb)
);
$$;

revoke all on function ensure_cometa_categories(uuid) from public,anon;
revoke all on function register_cometa_movement(uuid,text,date,uuid,numeric,text,text,text,text,text,text,text,uuid) from public,anon;
revoke all on function void_cometa_movement(uuid,uuid) from public,anon;
revoke all on function get_cometa_report(uuid,date,date,text,uuid,text,text,integer,integer) from public,anon;
grant execute on function ensure_cometa_categories(uuid) to authenticated;
grant execute on function register_cometa_movement(uuid,text,date,uuid,numeric,text,text,text,text,text,text,text,uuid) to authenticated;
grant execute on function void_cometa_movement(uuid,uuid) to authenticated;
grant execute on function get_cometa_report(uuid,date,date,text,uuid,text,text,integer,integer) to authenticated;

alter table cometa_movements replica identity full;
do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
    select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cometa_movements') then
    alter publication supabase_realtime add table cometa_movements;
  end if;
end $$;
commit;
