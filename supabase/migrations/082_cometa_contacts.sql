-- Un unico registro por empresa/persona, con rol de proveedor, comprador o ambos.
-- Se conserva la tabla existente y todos sus identificadores e historiales.
begin;
alter table cometa_suppliers add column if not exists party_role text not null default 'supplier'
  check (party_role in ('supplier','buyer','both'));

create or replace function save_cometa_contact(
  target_organization_id uuid,
  contact_name text,
  contact_tax_id text default '',
  contact_details text default '',
  contact_role text default 'supplier',
  target_contact_id uuid default null
)
returns cometa_suppliers language plpgsql security definer set search_path=public as $$
declare saved cometa_suppliers; cleaned_name text:=regexp_replace(trim(contact_name),'\s+',' ','g');
begin
  if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para guardar contactos.'; end if;
  if cleaned_name is null or length(cleaned_name) not between 1 and 200 then raise exception 'Ingresa un nombre de contacto de hasta 200 caracteres.'; end if;
  if contact_role is null or contact_role not in ('supplier','buyer','both') then raise exception 'Elegi proveedor, comprador o ambos.'; end if;
  if length(coalesce(contact_tax_id,''))>30 or length(coalesce(contact_details,''))>200 then raise exception 'Revisa el CUIT o los datos de contacto.'; end if;
  if target_contact_id is null then
    insert into cometa_suppliers(organization_id,name,tax_id,contact,party_role,created_by)
    values(target_organization_id,cleaned_name,trim(coalesce(contact_tax_id,'')),trim(coalesce(contact_details,'')),contact_role,auth.uid()) returning * into saved;
  else
    update cometa_suppliers set name=cleaned_name,tax_id=trim(coalesce(contact_tax_id,'')),contact=trim(coalesce(contact_details,'')),party_role=contact_role
    where id=target_contact_id and organization_id=target_organization_id and archived_at is null returning * into saved;
    if not found then raise exception 'El contacto no esta disponible.'; end if;
  end if;
  return saved;
exception when unique_violation then raise exception 'Ya existe un contacto con ese nombre. Edita su tipo para usarlo como proveedor y comprador.';
end;
$$;
revoke all on function save_cometa_contact(uuid,text,text,text,text,uuid) from public,anon;
grant execute on function save_cometa_contact(uuid,text,text,text,text,uuid) to authenticated;
commit;
