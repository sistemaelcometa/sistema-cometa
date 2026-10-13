-- ANULAR COBROS VIEJOS REALES POR ID
--
-- Uso unico: estos son los cobros antiguos detectados en la vista previa.
-- No borra contratos, inquilinos, edificios ni departamentos.
-- Solo marca estos cobros como cancelled si siguen pendientes y sin pagos validos.

-- 1) VISTA PREVIA
with ids(charge_id) as (
  values
    ('9c6b94f4-835e-4f12-9afe-cbe7057c02c0'::uuid),
    ('fe7b415d-878b-40c8-88ab-af768f1dd51e'::uuid),
    ('c6d54f7f-4883-420c-900c-add5a139132f'::uuid),
    ('4800cf87-aac3-472b-acbe-3cb483d05132'::uuid),
    ('ebad1042-3c46-42e8-b10b-e65f42cdbbc3'::uuid),
    ('e6560112-37de-4356-a905-0372268a5f04'::uuid),
    ('66134f75-9629-486e-a85f-eb67b5571b2d'::uuid)
),
totales as (
  select
    ci.charge_id,
    coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total
  from urban_charge_items ci
  join ids on ids.charge_id = ci.charge_id
  group by ci.charge_id
)
select
  ch.id as charge_id,
  ch.period_month,
  ch.due_date,
  ch.status,
  ub.name as edificio,
  uu.name as departamento,
  nullif(trim(coalesce(c.business_name, '') || ' ' || coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as inquilino,
  coalesce(t.total, 0) as total,
  exists (
    select 1
    from urban_charge_items ci
    join urban_payment_allocations pa on pa.charge_item_id = ci.id
    join urban_payments p on p.id = pa.payment_id
    where ci.charge_id = ch.id
      and p.status = 'valid'
  ) as tiene_pago_valido
from ids
join urban_charges ch on ch.id = ids.charge_id
join urban_leases ul on ul.id = ch.lease_id
join urban_units uu on uu.id = ch.unit_id
join urban_buildings ub on ub.id = uu.building_id
join contacts c on c.id = ul.primary_tenant_contact_id
left join totales t on t.charge_id = ch.id
order by ch.due_date, ub.name, uu.name;

-- 2) EJECUCION: cambia false por true y corre SOLO este bloque si la vista previa esta bien.
with confirmar as (
  select false as ejecutar_limpieza
),
ids(charge_id) as (
  values
    ('9c6b94f4-835e-4f12-9afe-cbe7057c02c0'::uuid),
    ('fe7b415d-878b-40c8-88ab-af768f1dd51e'::uuid),
    ('c6d54f7f-4883-420c-900c-add5a139132f'::uuid),
    ('4800cf87-aac3-472b-acbe-3cb483d05132'::uuid),
    ('ebad1042-3c46-42e8-b10b-e65f42cdbbc3'::uuid),
    ('e6560112-37de-4356-a905-0372268a5f04'::uuid),
    ('66134f75-9629-486e-a85f-eb67b5571b2d'::uuid)
),
cobros_a_anular as (
  select ch.id
  from ids
  join urban_charges ch on ch.id = ids.charge_id
  where ch.status = 'pending'
    and not exists (
      select 1
      from urban_charge_items ci
      join urban_payment_allocations pa on pa.charge_item_id = ci.id
      join urban_payments p on p.id = pa.payment_id
      where ci.charge_id = ch.id
        and p.status = 'valid'
    )
)
update urban_charges ch
set
  status = 'cancelled',
  updated_at = now(),
  version = ch.version + 1
from cobros_a_anular target
where ch.id = target.id
  and (select ejecutar_limpieza from confirmar)
returning
  ch.id as charge_id,
  ch.period_month,
  ch.due_date,
  ch.status;
