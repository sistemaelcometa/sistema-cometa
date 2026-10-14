-- Solo lectura. Compara el cargo de octubre con la liquidacion de septiembre
-- y con las imputaciones de los pagos. Conserva todos los importes exactos.
with target_charges as (
  select ch.*, b.name as edificio, u.name as departamento,
    trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as inquilino,
    l.current_amount as alquiler_contrato, b.id as building_id
  from public.urban_charges ch
  join public.urban_units u on u.id = ch.unit_id
  join public.urban_buildings b on b.id = u.building_id
  join public.urban_leases l on l.id = ch.lease_id
  join public.contacts c on c.id = l.primary_tenant_contact_id
  where upper(trim(b.name)) = 'PELLEGRINI'
    and upper(trim(u.name)) = 'DPTO 3'
    and ch.period_month = date '2026-10-01'
)
select ch.id as charge_id, ch.organization_id, ch.edificio, ch.departamento,
  ch.inquilino, ch.period_month, ch.status, ch.alquiler_contrato,
  coalesce(expenses.amount, 0) as expensas_liquidacion,
  ch.alquiler_contrato + coalesce(expenses.amount, 0) as total_base_pantalla,
  coalesce(items.total_due, 0) as total_conceptos,
  coalesce(paid.amount, 0) as pagos_imputados_validos,
  ch.alquiler_contrato + coalesce(expenses.amount, 0) - coalesce(paid.amount, 0) as saldo_base_exacto,
  coalesce(items.total_due, 0) - coalesce(paid.amount, 0) as saldo_conceptos_exacto,
  coalesce(items.detail, '[]'::jsonb) as conceptos,
  coalesce(paid.detail, '[]'::jsonb) as imputaciones
from target_charges ch
left join lateral (
  select sum(a.tenant_amount) as amount
  from public.urban_expense_allocations a
  join public.urban_expense_periods ep on ep.id = a.period_id
  join public.urban_expense_items ei on ei.id = a.expense_item_id
  where a.organization_id = ch.organization_id
    and a.unit_id = ch.unit_id
    and ep.building_id = ch.building_id
    and ep.period_month = (ch.period_month - interval '1 month')::date
    and ep.status in ('calculated', 'closed')
    and ei.status = 'valid'
    and a.transfer_to_tenant
) expenses on true
left join lateral (
  select sum(ci.amount_due) as total_due,
    jsonb_agg(jsonb_build_object('item_id', ci.id, 'tipo', ci.item_type,
      'origen', ci.source_entity_type, 'importe', ci.amount_due) order by ci.created_at, ci.id) as detail
  from public.urban_charge_items ci
  where ci.charge_id = ch.id
) items on true
left join lateral (
  select sum(pa.allocated_amount) filter (where pay.status = 'valid') as amount,
    jsonb_agg(jsonb_build_object('payment_id', pay.id, 'estado_pago', pay.status,
      'fecha_pago', pay.payment_date, 'importe_recibido', pay.received_amount,
      'tipo_concepto', ci.item_type, 'imputado', pa.allocated_amount)
      order by pay.created_at, ci.id) as detail
  from public.urban_charge_items ci
  join public.urban_payment_allocations pa on pa.charge_item_id = ci.id
  join public.urban_payments pay on pay.id = pa.payment_id
  where ci.charge_id = ch.id
) paid on true
order by ch.created_at desc;
