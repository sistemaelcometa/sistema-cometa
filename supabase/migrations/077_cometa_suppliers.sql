-- Proveedores del modulo agricola. Los movimientos conservan su nombre historico.
begin;
create table if not exists cometa_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 200),
  tax_id text not null default '' check(length(tax_id)<=30),
  contact text not null default '' check(length(contact)<=200),
  archived_at timestamptz,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create unique index if not exists cometa_suppliers_name_key on cometa_suppliers(organization_id,lower(regexp_replace(trim(name),'\s+',' ','g'))) where archived_at is null;
alter table cometa_suppliers enable row level security;
drop policy if exists cometa_suppliers_read on cometa_suppliers;
create policy cometa_suppliers_read on cometa_suppliers for select to authenticated using(is_org_member(organization_id));
revoke all on cometa_suppliers from anon,authenticated;
grant select on cometa_suppliers to authenticated;

create or replace function save_cometa_supplier(target_organization_id uuid,supplier_name text,supplier_tax_id text default '',supplier_contact text default '',target_supplier_id uuid default null)
returns cometa_suppliers language plpgsql security definer set search_path=public as $$
declare saved cometa_suppliers; cleaned_name text:=regexp_replace(trim(supplier_name),'\s+',' ','g');
begin
  if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para guardar proveedores.'; end if;
  if cleaned_name is null or length(cleaned_name) not between 1 and 200 then raise exception 'Ingresa un nombre de proveedor de hasta 200 caracteres.'; end if;
  if length(coalesce(supplier_tax_id,''))>30 or length(coalesce(supplier_contact,''))>200 then raise exception 'Revisa el CUIT o contacto del proveedor.'; end if;
  if target_supplier_id is null then
    insert into cometa_suppliers(organization_id,name,tax_id,contact,created_by)
    values(target_organization_id,cleaned_name,trim(coalesce(supplier_tax_id,'')),trim(coalesce(supplier_contact,'')),auth.uid()) returning * into saved;
  else
    update cometa_suppliers set name=cleaned_name,tax_id=trim(coalesce(supplier_tax_id,'')),contact=trim(coalesce(supplier_contact,''))
    where id=target_supplier_id and organization_id=target_organization_id and archived_at is null returning * into saved;
    if not found then raise exception 'El proveedor no esta disponible.'; end if;
  end if;
  return saved;
exception when unique_violation then raise exception 'Ya existe un proveedor con ese nombre.';
end;
$$;
create or replace function archive_cometa_supplier(target_organization_id uuid,target_supplier_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para archivar proveedores.'; end if;
  update cometa_suppliers set archived_at=coalesce(archived_at,now()) where id=target_supplier_id and organization_id=target_organization_id;
  if not found then raise exception 'El proveedor no esta disponible.'; end if;
end;
$$;
revoke all on function save_cometa_supplier(uuid,text,text,text,uuid),archive_cometa_supplier(uuid,uuid) from public,anon;
grant execute on function save_cometa_supplier(uuid,text,text,text,uuid),archive_cometa_supplier(uuid,uuid) to authenticated;
commit;
