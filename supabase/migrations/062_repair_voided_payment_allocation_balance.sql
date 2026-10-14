-- Repair payment allocation validation after voiding payments.
-- Voided payments keep their historical allocations, but those allocations must
-- never consume balance when registering a new payment.

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

  select coalesce(sum(a.allocated_amount), 0)
    into allocated_to_item
  from urban_payment_allocations a
  join urban_payments p on p.id = a.payment_id
  where a.charge_item_id = new.charge_item_id
    and a.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
    and p.status = 'valid'
    and p.voided_at is null;

  if allocated_to_item + new.allocated_amount > item_due then
    raise exception 'La imputacion supera el saldo del concepto.';
  end if;

  select coalesce(sum(a.allocated_amount), 0)
    into allocated_from_payment
  from urban_payment_allocations a
  join urban_payments p on p.id = a.payment_id
  where a.payment_id = new.payment_id
    and a.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
    and p.status = 'valid'
    and p.voided_at is null;

  if allocated_from_payment + new.allocated_amount > payment_amount then
    raise exception 'La imputacion supera el importe recibido.';
  end if;

  return new;
end;
$$;

-- Defensive repair for any payment that was voided but kept an old valid status.
update urban_payments
set status = 'voided'
where status = 'valid'
  and voided_at is not null;

with charge_amounts as (
  select
    ch.id as charge_id,
    coalesce(sum(ci.amount_due), 0)::numeric(14, 2) as total_due
  from urban_charges ch
  left join urban_charge_items ci on ci.charge_id = ch.id
  group by ch.id
),
payment_amounts as (
  select
    ch.id as charge_id,
    coalesce(sum(pa.allocated_amount) filter (
      where pay.status = 'valid'
        and pay.voided_at is null
    ), 0)::numeric(14, 2) as total_paid
  from urban_charges ch
  left join urban_charge_items ci on ci.charge_id = ch.id
  left join urban_payment_allocations pa on pa.charge_item_id = ci.id
  left join urban_payments pay on pay.id = pa.payment_id
  group by ch.id
),
charge_totals as (
  select
    charge_amounts.charge_id,
    charge_amounts.total_due,
    coalesce(payment_amounts.total_paid, 0)::numeric(14, 2) as total_paid
  from charge_amounts
  left join payment_amounts on payment_amounts.charge_id = charge_amounts.charge_id
)
update urban_charges ch
set status = case
  when charge_totals.total_due > 0 and charge_totals.total_paid >= charge_totals.total_due then 'paid'::charge_status
  when charge_totals.total_paid > 0 then 'partial'::charge_status
  else 'pending'::charge_status
end
from charge_totals
where charge_totals.charge_id = ch.id
  and ch.status <> 'cancelled'::charge_status;
